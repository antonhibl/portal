/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Input handoff: which key presses a view's app gets, which start a handoff
   to Emacs, and each handoff from its trigger to the end of its command.
   Records tell Emacs what happened, and Emacs answers with portal--input
   actions.  The platform keeps the native events: this file sees only
   chords, and asks the platform to replay, discard or deliver what it holds.

   A focus change the platform reports while Emacs or the core is calling it
   is their own doing.  Any other is the user's: it abandons the view's
   handoff, and losing the keyboard also ends passthrough. */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "channel.h"
#include "input.h"
#include "views.h"

enum { MODIFIERS = PORTAL_SHIFT | PORTAL_CONTROL | PORTAL_META | PORTAL_SUPER };

/* A binding profile: normalized chords, none of them the prefix. */
struct profile {
    portal_binding *bindings;
    size_t count;
};

static struct {
    portal_chord prefix; /* Normalized, and no binding's chord. */
    struct profile regular, quick;
    int64_t serials;   /* The last serial given out. */
    unsigned requests; /* How many calls for Emacs or the core are running. */
} input = {.prefix = {'b', PORTAL_CONTROL}};

/* C-g, which cancels the key sequence Emacs is reading. */
static const portal_chord cancel = {'g', PORTAL_CONTROL};

static bool is(portal_string string, const char *literal)
{
    return string.length == strlen(literal) && !memcmp(string.data, literal, string.length);
}

/* Set *ERROR to MESSAGE followed by DETAIL, which may hold any bytes. */
static bool fail(portal_text *error, const char *message, portal_string detail)
{
    size_t length = strlen(message);
    char *text = malloc(length + detail.length + 1);
    if (text) {
        memcpy(text, message, length);
        if (detail.length)
            memcpy(text + length, detail.data, detail.length);
        text[length + detail.length] = '\0';
        *error = (portal_text) {text, length + detail.length};
    }
    return false;
}

static bool fail_with(portal_text *error, const char *message)
{
    return fail(error, message, (portal_string) {"", 0});
}

/* CHORD as the core compares chords: only the known modifiers, a letter in
   lower case, and no Shift on another printable ASCII character, which
   Shift already made.  Shift stays on letters and space, as Emacs's S-a and
   S-SPC. */
static portal_chord normalize(portal_chord chord)
{
    uint32_t character = chord.character, modifiers = chord.modifiers & MODIFIERS;
    if (character >= 'A' && character <= 'Z')
        character += 'a' - 'A';
    else if (character > ' ' && character < 0x80 && !(character >= 'a' && character <= 'z'))
        modifiers &= ~(uint32_t) PORTAL_SHIFT;
    return (portal_chord) {character, modifiers};
}

static bool same(portal_chord a, portal_chord b)
{
    return a.character == b.character && a.modifiers == b.modifiers;
}

/* Whether CHORD can be a first chord: one printable ASCII character and
   modifiers the core knows, other than Shift alone on punctuation. */
static bool first_chord(portal_chord chord)
{
    return chord.character >= ' ' && chord.character <= '~' && chord.modifiers
        && !(chord.modifiers & ~(uint32_t) MODIFIERS) && normalize(chord).modifiers;
}

/* The event PROFILE binds normalized KEY to, or 0. */
static int64_t lookup(const struct profile *profile, portal_chord key)
{
    for (size_t i = 0; profile && i < profile->count; i++)
        if (same(profile->bindings[i].chord, key))
            return profile->bindings[i].event;
    return 0;
}

static const struct profile *profile(const struct portal_input *view)
{
    return view->bindings == PORTAL_QUICK_BINDINGS     ? &input.quick
         : view->bindings == PORTAL_REGULAR_BINDINGS ? &input.regular
                                                     : NULL;
}

/* Send Emacs the record "TYPE TARGET SERIAL KEY". */
static bool send(const char *type, const struct portal_input *view, int64_t serial, int64_t key)
{
    char numbers[2][24];
    portal_string fields[2];
    int64_t values[] = {serial, key};
    for (size_t i = 0; i < 2; i++) {
        int length = snprintf(numbers[i], sizeof numbers[i], "%" PRId64, values[i]);
        fields[i] = (portal_string) {numbers[i], (size_t) length};
    }
    return portal_channel_send((portal_string) {type, strlen(type)}, view->target, fields, 2);
}

/* Free the error of a primitive the platform asked for, which has no one to
   report it to.  Called on the thread the platform must use, a primitive
   fails only when that is broken. */
static void ignore(bool done, portal_text *error)
{
    if (!done)
        free(error->data);
}

/* End VIEW's handoff, if any: the platform drops the events it holds. */
static bool end(struct portal_input *view, portal_text *error)
{
    enum portal_handoff was = view->handoff;
    view->handoff = PORTAL_IDLE;
    return was == PORTAL_IDLE || portal_view_replay(view->view, false, error);
}

/* The user took the keyboard during VIEW's handoff: end it, and tell Emacs,
   which may be reading its key sequence. */
static void abandon(struct portal_input *view)
{
    if (view->handoff == PORTAL_IDLE)
        return;
    portal_text error = {0};
    ignore(end(view, &error), &error);
    send("escape", view, view->serial, 0);
}

void portal_input_open(struct portal_input *view, portal_view *native, portal_string target,
                       portal_kind kind, const portal_option *options, size_t count)
{
    bool quick = false;
    for (size_t i = 0; i < count; i++)
        if (is(options[i].name, "quick"))
            quick = options[i].is_string || options[i].flag;
    *view = (struct portal_input) {
        .view = native,
        .target = target,
        .bindings = kind == PORTAL_WEB ? PORTAL_NO_BINDINGS
                  : quick              ? PORTAL_QUICK_BINDINGS
                                       : PORTAL_REGULAR_BINDINGS,
    };
}

bool portal_input_close(struct portal_input *view, portal_text *error)
{
    view->passthrough = false;
    input.requests++;
    bool done = end(view, error);
    input.requests--;
    return done;
}

portal_key portal_input_key(portal_string target, portal_chord chord, bool repeat)
{
    struct portal_input *view = portal_views_input(target);
    if (!view)
        return PORTAL_KEY_PASS;
    portal_chord key = normalize(chord);
    switch (view->handoff) {
    case PORTAL_AWAITING:
        return PORTAL_KEY_HOLD; /* The platform holds these without asking. */
    case PORTAL_READING: {
        const char *type = view->first && same(key, view->trigger) ? "literal"
                         : same(key, cancel)                       ? "cancel"
                                                                   : NULL;
        if (!type) {
            view->first = false;
            return PORTAL_KEY_PASS;
        }
        if (!repeat)
            send(type, view, view->serial, 0);
        return PORTAL_KEY_TAKE;
    }
    case PORTAL_EXECUTING:
        return PORTAL_KEY_PASS;
    case PORTAL_IDLE:
        break;
    }
    int64_t event = 0;
    if (view->passthrough
        || (!same(key, input.prefix) && !(event = lookup(profile(view), key))))
        return PORTAL_KEY_PASS;
    /* A held key repeats until its release, which may come after Emacs has
       finished the handoff; only the press starts one. */
    if (repeat)
        return PORTAL_KEY_TAKE;
    view->serial = ++input.serials;
    if (!send(event ? "binding" : "prefix", view, view->serial, event))
        return PORTAL_KEY_TAKE;
    view->handoff = PORTAL_AWAITING;
    view->trigger = key;
    /* Emacs reads the rest; the platform holds it meanwhile. */
    portal_text error = {0};
    input.requests++;
    ignore(portal_view_unfocus(view->view, &error), &error);
    input.requests--;
    return PORTAL_KEY_HOLD;
}

void portal_input_focus(portal_string target, bool focused)
{
    struct portal_input *view = portal_views_input(target);
    if (!view)
        return;
    view->focused = focused;
    if (!focused)
        view->passthrough = false;
    if (!input.requests)
        abandon(view);
}

portal_owner portal_input_owner(portal_string target)
{
    const struct portal_input *view = portal_views_input(target);
    return !view                             ? PORTAL_OWNER_EMACS
         : view->handoff != PORTAL_IDLE      ? PORTAL_OWNER_PENDING
         : !view->focused                    ? PORTAL_OWNER_EMACS
         : view->passthrough                 ? PORTAL_OWNER_PASSTHROUGH
                                             : PORTAL_OWNER_VIEW;
}

void portal_input_request(bool requesting)
{
    if (requesting)
        input.requests++;
    else
        input.requests--;
}

/* Perform ACTION on VIEW, for Emacs. */
static bool act(struct portal_input *view, portal_string action, int64_t serial, bool *result,
                portal_text *error)
{
    if (serial && (serial != view->serial || view->handoff == PORTAL_IDLE))
        return true;
    if (is(action, "pending")) {
        *result = view->handoff != PORTAL_IDLE;
    } else if (is(action, "focused")) {
        *result = view->focused;
    } else if (is(action, "passthrough-p")) {
        *result = view->passthrough;
    } else if (is(action, "focus")) {
        view->passthrough = false;
        if (!portal_view_focus(view->view, error))
            return false;
        *result = view->focused;
    } else if (is(action, "passthrough")) {
        if (!portal_view_focus(view->view, error))
            return false;
        *result = view->passthrough = view->focused;
    } else if (is(action, "unfocus")) {
        view->passthrough = false;
        if (!end(view, error) || !portal_view_unfocus(view->view, error))
            return false;
        *result = true;
    } else if (is(action, "ack")) {
        if (view->handoff != PORTAL_AWAITING)
            return true;
        view->handoff = PORTAL_READING;
        view->first = true;
        if (!portal_view_replay(view->view, true, error))
            return false;
        *result = true;
    } else if (is(action, "command")) {
        if (view->handoff == PORTAL_READING)
            view->handoff = PORTAL_EXECUTING;
        *result = true;
    } else if (is(action, "finish")) {
        if (!end(view, error))
            return false;
        *result = true;
    } else if (is(action, "literal")) {
        if (view->handoff == PORTAL_IDLE)
            return fail_with(error, "No captured prefix key to send");
        if (!portal_view_focus(view->view, error))
            return false;
        if (!view->focused)
            return fail_with(error, "No captured prefix key to send");
        if (!portal_view_literal(view->view, error))
            return false;
        *result = true;
    } else {
        return fail(error, "Unknown Portal input action: ", action);
    }
    return true;
}

bool portal_input_perform(portal_string target, portal_string action, int64_t serial,
                          bool *result, portal_text *error)
{
    struct portal_input *view = portal_views_input(target);
    *result = false;
    if (!view)
        return true;
    input.requests++;
    bool done = act(view, action, serial, result, error);
    input.requests--;
    return done;
}

bool portal_input_prefix(portal_chord chord, portal_text *error)
{
    if (!first_chord(chord))
        return fail_with(error, "Expected one modified ASCII prefix");
    portal_chord key = normalize(chord);
    if (lookup(&input.regular, key) || lookup(&input.quick, key))
        return fail_with(error, "Portal prefix conflicts with a native binding");
    input.prefix = key;
    return true;
}

/* Normalize COUNT BINDINGS into *PROFILE, which the caller frees, or say
   why they cannot be a profile. */
static bool compile(const portal_binding *bindings, size_t count, struct profile *profile,
                    portal_text *error)
{
    profile->bindings = malloc((count ? count : 1) * sizeof *profile->bindings);
    if (!profile->bindings)
        return fail_with(error, "Portal is out of memory");
    for (size_t i = 0; i < count; i++) {
        if (!first_chord(bindings[i].chord) || bindings[i].event <= 0)
            return fail_with(error, "Invalid native terminal binding");
        portal_chord key = normalize(bindings[i].chord);
        if (same(key, input.prefix) || lookup(profile, key))
            return fail_with(error, "Conflicting native terminal binding");
        profile->bindings[profile->count++] = (portal_binding) {key, bindings[i].event};
    }
    return true;
}

bool portal_input_bindings(const portal_binding *regular, size_t regular_count,
                           const portal_binding *quick, size_t quick_count, portal_text *error)
{
    struct profile profiles[2] = {{0}};
    if (!compile(regular, regular_count, &profiles[0], error)
        || !compile(quick, quick_count, &profiles[1], error)) {
        free(profiles[0].bindings);
        free(profiles[1].bindings);
        return false;
    }
    free(input.regular.bindings);
    free(input.quick.bindings);
    input.regular = profiles[0];
    input.quick = profiles[1];
    return true;
}
