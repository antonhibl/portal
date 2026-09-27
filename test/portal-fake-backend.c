/* SPDX-License-Identifier: GPL-3.0-or-later */
/* An in-memory backend for the module and core tests.  It implements the
   operations of native/Core/include/portal.h, so the real C core runs without
   AppKit, WebKit or Ghostty.  A view describes what its operations received:
   its options, the "handle" that tells views apart, the "frame" title and
   "size" it was last attached with, whether it is "attached", and the
   global settings, as "fake".  Views never move: attaching records where.

   A view created with the option :description describes itself with exactly
   that text instead, for tests of how the core reads descriptions.

   Failures on demand: creating a view with the option :fail fails, with that
   option's string as the message; attaching to a frame whose title starts
   with "deleted" fails, as the frame is gone; and while a test says so,
   every view primitive refuses to run, as on the wrong thread.  Timers fire only when a test
   fires them.  A destroyed view's memory is kept, marked destroyed, so a
   later call that names it is counted instead of reading freed memory
   (portal-fake-backend.h).

   Keys: all views share one window, where one attached view at a time can
   have the keyboard, and Emacs has it otherwise.  Tests press keys, click
   and press Command-Escape as a user would, and the fake routes each press
   as the macOS platform does: holding what the core says to hold, and
   replaying it when a test runs the event loop.  It logs where each press
   went. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "portal-fake-backend.h"
#include "portal.h"

enum { MAX_PROPERTIES = 32, MAX_TIMERS = 64, MAX_VIEWS = 4096, MAX_KEYS = 64 };

/* A key press, as the platform keeps it. */
struct press {
    portal_chord chord;
    bool repeat;
};

/* One property that portal--inspect reports. */
struct property {
    portal_text name;
    enum { FLAG, INTEGER, INTEGERS, STRING } kind;
    bool flag;
    int64_t integer;
    int64_t *integers; /* COUNT of them. */
    size_t count;
    portal_text string;
};

struct portal_view {
    portal_kind kind;
    char *target; /* For records. */
    bool destroyed;
    struct property properties[MAX_PROPERTIES];
    size_t count;
    bool focused;          /* It has the keyboard. */
    bool triggered;        /* It holds TRIGGER. */
    struct press trigger;
    bool holding;          /* It holds the presses in HELD, after TRIGGER. */
    struct press held[MAX_KEYS];
    size_t held_count;
};

static struct portal_view settings;
static struct portal_fake_calls calls;
static bool refusing; /* See portal_fake_refuse. */
static uint64_t timers[MAX_TIMERS]; /* Tokens of the timers not yet fired, oldest first. */
static size_t timer_count;
static struct portal_view *all[MAX_VIEWS]; /* Every view created, destroyed or not. */
static size_t view_count;
static struct press posted[MAX_KEYS]; /* Replayed presses the event loop has not run. */
static size_t posted_count;
static char key_log[4096];            /* Where presses went, since the last portal_fake_keys. */

static portal_text copy(const char *data, size_t length)
{
    char *bytes = malloc(length + 1);
    if (length)
        memcpy(bytes, data, length);
    bytes[length] = '\0';
    return (portal_text) {bytes, length};
}

static bool is(portal_string string, const char *literal)
{
    return string.length == strlen(literal) && !memcmp(string.data, literal, string.length);
}

static bool fail(portal_text *error, const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    char message[256];
    int length = vsnprintf(message, sizeof message, format, arguments);
    va_end(arguments);
    *error = copy(message, length < (int) sizeof message ? (size_t) length : sizeof message - 1);
    return false;
}

static void clear(struct property *property)
{
    free(property->integers);
    free(property->string.data);
    property->integers = NULL;
    property->string = (portal_text) {0};
}

/* VIEW's property NAME, cleared for a new value. */
static struct property *property(struct portal_view *view, const char *name, size_t length)
{
    for (size_t i = 0; i < view->count; i++) {
        struct property *property = &view->properties[i];
        if (property->name.length == length && !memcmp(property->name.data, name, length)) {
            clear(property);
            return property;
        }
    }
    if (view->count == MAX_PROPERTIES)
        abort();
    struct property *property = &view->properties[view->count++];
    property->name = copy(name, length);
    return property;
}

static const struct property *get(const struct portal_view *view, const char *name)
{
    for (size_t i = 0; i < view->count; i++)
        if (view->properties[i].name.length == strlen(name)
            && !memcmp(view->properties[i].name.data, name, strlen(name)))
            return &view->properties[i];
    return NULL;
}

static void set_flag(struct portal_view *view, const char *name, bool flag)
{
    struct property *entry = property(view, name, strlen(name));
    entry->kind = FLAG;
    entry->flag = flag;
}

static void set_integer(struct portal_view *view, const char *name, int64_t integer)
{
    struct property *entry = property(view, name, strlen(name));
    entry->kind = INTEGER;
    entry->integer = integer;
}

static void set_string(struct portal_view *view, const char *name, const char *data, size_t length)
{
    struct property *entry = property(view, name, strlen(name));
    entry->kind = STRING;
    entry->string = copy(data, length);
}

/* Append DATA to VIEW's string property NAME, after SEPARATOR if it is not empty. */
static void append(struct portal_view *view, const char *name, const char *separator, const char *data,
                   size_t length)
{
    const struct property *old = get(view, name);
    portal_text previous = old ? copy(old->string.data, old->string.length) : copy("", 0);
    size_t gap = previous.length ? strlen(separator) : 0;
    char *bytes = malloc(previous.length + gap + length + 1);
    memcpy(bytes, previous.data, previous.length);
    memcpy(bytes + previous.length, separator, gap);
    if (length)
        memcpy(bytes + previous.length + gap, data, length);
    set_string(view, name, bytes, previous.length + gap + length);
    free(bytes);
    free(previous.data);
}

/* A growing JSON text. */
struct json {
    char *data;
    size_t length;
};

static void put(struct json *json, const char *data, size_t length)
{
    json->data = realloc(json->data, json->length + length + 1);
    memcpy(json->data + json->length, data, length);
    json->length += length;
    json->data[json->length] = '\0';
}

static void put_format(struct json *json, const char *format, long long value)
{
    char number[32];
    put(json, number, (size_t) snprintf(number, sizeof number, format, value));
}

static void put_string(struct json *json, portal_text text)
{
    put(json, "\"", 1);
    for (size_t i = 0; i < text.length; i++) {
        unsigned char c = (unsigned char) text.data[i];
        if (c == '"' || c == '\\')
            put(json, "\\", 1), put(json, (char *) &c, 1);
        else if (c < 0x20)
            put_format(json, "\\u%04llx", c);
        else
            put(json, (char *) &c, 1);
    }
    put(json, "\"", 1);
}

/* Whether a view primitive refuses to run, setting *ERROR. */
static bool refused(portal_text *error)
{
    return refusing && !fail(error, "The fake refuses to run view primitives");
}

void portal_fake_refuse(bool refuse)
{
    refusing = refuse;
}

/* Whether the core may use VIEW, of KIND unless KIND is -1: it must not
   have been destroyed.  Anything else is counted for the tests to find. */
static bool usable(struct portal_view *view, int kind, portal_text *error)
{
    if (view && !view->destroyed && (kind < 0 || (int) view->kind == kind))
        return true;
    calls.misused++;
    return fail(error, "The core passed a view it may not use");
}

static void set_integers(struct portal_view *view, const char *name, const int64_t *integers,
                         size_t count)
{
    struct property *entry = property(view, name, strlen(name));
    entry->kind = INTEGERS;
    entry->count = count;
    entry->integers = malloc((count ? count : 1) * sizeof *entry->integers);
    memcpy(entry->integers, integers, count * sizeof *entry->integers);
}

bool portal_view_create(portal_kind kind, portal_string target, const portal_option *options,
                        size_t count, portal_view **result, portal_text *error)
{
    if (refused(error))
        return false;
    for (size_t i = 0; i < count; i++)
        if (is(options[i].name, "fail") && (options[i].is_string || options[i].flag))
            return options[i].is_string
                ? fail(error, "%.*s", (int) options[i].string.length, options[i].string.data)
                : fail(error, "The fake could not create the view");
    struct portal_view *view = calloc(1, sizeof *view);
    view->kind = kind;
    view->target = copy(target.data, target.length).data;
    set_integer(view, "handle", (int64_t) ++calls.created);
    if (view_count == MAX_VIEWS)
        abort();
    all[view_count++] = view;
    set_flag(view, "attached", false);
    for (size_t i = 0; i < count; i++) {
        struct property *entry = property(view, options[i].name.data, options[i].name.length);
        entry->kind = options[i].is_string ? STRING : FLAG;
        if (options[i].is_string)
            entry->string = copy(options[i].string.data, options[i].string.length);
        else
            entry->flag = options[i].flag;
    }
    *result = view;
    return true;
}

static void set_focus(struct portal_view *view);

bool portal_view_destroy(portal_view *view, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    calls.destroyed++;
    if (view->focused)
        set_focus(NULL);
    for (size_t i = 0; i < view->count; i++) {
        clear(&view->properties[i]);
        free(view->properties[i].name.data);
    }
    free(view->target);
    *view = (struct portal_view) {.destroyed = true};
    return true;
}

bool portal_view_attach(portal_view *view, portal_string frame, portal_rect rect,
                        portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    calls.attached++;
    if (frame.length >= 7 && !memcmp(frame.data, "deleted", 7))
        return fail(error, "Cannot find the requested native Emacs frame");
    set_string(view, "frame", frame.data, frame.length);
    set_integers(view, "size", (int64_t[]) {rect.width, rect.height}, 2);
    set_flag(view, "attached", true);
    return true;
}

bool portal_view_detach(portal_view *view, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    calls.detached++;
    if (view->focused)
        set_focus(NULL);
    set_flag(view, "frame", false);
    set_flag(view, "attached", false);
    return true;
}

static void put_properties(struct json *json, const struct portal_view *view)
{
    for (size_t i = 0; i < view->count; i++) {
        const struct property *property = &view->properties[i];
        if (i)
            put(json, ",", 1);
        put_string(json, property->name);
        put(json, ":", 1);
        if (property->kind == FLAG)
            put(json, property->flag ? "true" : "false", property->flag ? 4 : 5);
        else if (property->kind == INTEGER)
            put_format(json, "%lld", property->integer);
        else if (property->kind == STRING)
            put_string(json, property->string);
        else
            for (size_t k = 0; k < property->count; k++)
                put_format(json, k ? ",%lld" : "[%lld", property->integers[k]);
        if (property->kind == INTEGERS)
            put(json, property->count ? "]" : "[]", property->count ? 1 : 2);
    }
}

bool portal_view_describe(portal_view *view, portal_text *state, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    calls.described++;
    const struct property *description = get(view, "description");
    if (description && description->kind == STRING) {
        *state = copy(description->string.data, description->string.length);
        return true;
    }
    struct json json = {0};
    put(&json, "{", 1);
    put_properties(&json, view);
    put(&json, ",\"fake\":{", 9);
    put_properties(&json, &settings);
    put(&json, "}}", 2);
    *state = (portal_text) {json.data, json.length};
    return true;
}

struct portal_fake_calls portal_fake_calls(void)
{
    return calls;
}

void portal_timer_start(uint64_t token, uint64_t milliseconds)
{
    (void) milliseconds;
    if (timer_count == MAX_TIMERS)
        abort();
    timers[timer_count++] = token;
}

size_t portal_fake_timers(void)
{
    return timer_count;
}

void portal_fake_fire_timers(void)
{
    uint64_t fired[MAX_TIMERS];
    size_t count = timer_count;
    memcpy(fired, timers, count * sizeof *timers);
    timer_count = 0;
    for (size_t i = 0; i < count; i++)
        portal_timer_fired(fired[i]);
}

bool portal_web_load(portal_view *web, portal_string url, portal_text *error)
{
    if (!usable(web, PORTAL_WEB, error))
        return false;
    set_string(web, "url", url.data, url.length);
    return true;
}

/* Whether WEB is a hosted web view. */
static bool hosted(struct portal_view *web, portal_text *error)
{
    if (!usable(web, PORTAL_WEB, error))
        return false;
    const struct property *option = get(web, "hosted");
    if (option && (option->kind == STRING || option->flag))
        return true;
    return fail(error, "Web view %s is not a hosted app, so it has no bridge", web->target);
}

/* The fake app echoes what Emacs sends it.  Like the real bridge, one record
   announces its messages until Emacs receives them. */
bool portal_web_send(portal_view *web, portal_string json, portal_text *error)
{
    if (!hosted(web, error))
        return false;
    const struct property *messages = get(web, "messages");
    bool announced = messages && messages->string.length;
    portal_string target = {web->target, strlen(web->target)};
    if (!announced && !portal_notify((portal_string) {"bridge", 6}, target, NULL, 0))
        return fail(error, "The bridge record was refused");
    append(web, "messages", ",", json.data, json.length);
    return true;
}

bool portal_web_receive(portal_view *web, portal_text *json, portal_text *error)
{
    if (!hosted(web, error))
        return false;
    const struct property *messages = get(web, "messages");
    portal_text sent = messages ? messages->string : (portal_text) {"", 0};
    char *bytes = malloc(sent.length + 3);
    bytes[0] = '[';
    memcpy(bytes + 1, sent.data, sent.length);
    memcpy(bytes + 1 + sent.length, "]", 2);
    *json = (portal_text) {bytes, sent.length + 2};
    set_string(web, "messages", "", 0);
    return true;
}

static const char *const themes[] = {"Alpha", "Beta", "Ωmega"};

/* Like the real one, resolve the theme before touching any terminal. */
bool portal_terminal_theme(const portal_string *name, portal_view *const *terminals,
                           size_t count, portal_text *error)
{
    bool known = !name;
    for (size_t i = 0; name && i < sizeof themes / sizeof *themes; i++)
        known = known || is(*name, themes[i]);
    if (!known)
        return fail(error, "Unknown terminal theme: %.*s", (int) name->length, name->data);
    for (size_t i = 0; i < count; i++)
        if (!usable(terminals[i], PORTAL_TERMINAL, error))
            return false;
    for (size_t i = 0; i <= count; i++) {
        struct portal_view *view = i < count ? terminals[i] : &settings;
        if (name)
            set_string(view, "theme", name->data, name->length);
        else
            set_flag(view, "theme", false);
    }
    return true;
}

bool portal_terminal_themes(portal_text *names, portal_text *error)
{
    (void) error;
    struct json json = {0};
    put(&json, "[", 1);
    for (size_t i = 0; i < sizeof themes / sizeof *themes; i++) {
        if (i)
            put(&json, ",", 1);
        put_string(&json, (portal_text) {(char *) themes[i], strlen(themes[i])});
    }
    put(&json, "]", 1);
    *names = (portal_text) {json.data, json.length};
    return true;
}

/* The fake terminal's scrollback is everything pasted into it. */
bool portal_terminal_paste(portal_view *terminal, portal_string text, bool enter,
                           portal_text *error)
{
    if (!usable(terminal, PORTAL_TERMINAL, error))
        return false;
    append(terminal, "text", "", text.data, text.length);
    if (enter)
        append(terminal, "text", "", "\n", 1);
    return true;
}

bool portal_terminal_text(portal_view *terminal, portal_text *text, portal_text *error)
{
    if (!usable(terminal, PORTAL_TERMINAL, error))
        return false;
    const struct property *scrollback = get(terminal, "text");
    *text = scrollback ? copy(scrollback->string.data, scrollback->string.length) : copy("", 0);
    return true;
}

bool portal_toolbar(bool enabled, portal_text *error)
{
    (void) error;
    set_flag(&settings, "toolbar", enabled);
    return true;
}

bool portal_toolbar_theme(portal_string json, portal_text *error)
{
    if (!json.length || json.data[0] != '{')
        return fail(error, "Toolbar theme must be a JSON object");
    set_string(&settings, "toolbar-theme", json.data, json.length);
    return true;
}

bool portal_toolbar_action(portal_view *view, portal_string action, portal_text *state,
                           portal_text *error)
{
    if (!usable(view, -1, error))
        return false;
    if (view->kind != PORTAL_WEB)
        return fail(error, "No toolbar controls for this native view");
    char json[256];
    int length = snprintf(json, sizeof json, "{\"action\":\"%.*s\"}", (int) action.length,
                          action.data);
    *state = copy(json, length < (int) sizeof json ? (size_t) length : sizeof json - 1);
    return true;
}

/* Input.  Reports of the focus changes the fake makes reach the core at
   once, as the contract in portal.h asks. */

static portal_string target_of(const struct portal_view *view)
{
    return (portal_string) {view->target, strlen(view->target)};
}

/* Give VIEW the keyboard, or Emacs for NULL, reporting each change. */
static void set_focus(struct portal_view *view)
{
    for (size_t i = 0; i < view_count; i++) {
        struct portal_view *other = all[i];
        if (other->destroyed || other->focused == (other == view))
            continue;
        other->focused = other == view;
        portal_input_focus(target_of(other), other->focused);
    }
}

static bool attached(const struct portal_view *view)
{
    const struct property *flag = get(view, "attached");
    return flag && flag->flag;
}

bool portal_view_focus(portal_view *view, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    calls.focused++;
    if (attached(view))
        set_focus(view);
    return true;
}

bool portal_view_unfocus(portal_view *view, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    calls.unfocused++;
    if (view->focused)
        set_focus(NULL);
    return true;
}

static void log_key(const char *where, struct press press)
{
    char name[32];
    size_t length = 0;
    const char *prefixes[] = {"C-", "M-", "s-", "S-"};
    const uint32_t bits[] = {PORTAL_CONTROL, PORTAL_META, PORTAL_SUPER, PORTAL_SHIFT};
    for (size_t i = 0; i < 4; i++)
        if (press.chord.modifiers & bits[i])
            length += (size_t) snprintf(name + length, sizeof name - length, "%s", prefixes[i]);
    snprintf(name + length, sizeof name - length, "%c%s", (char) press.chord.character,
             press.repeat ? " repeat" : "");
    size_t used = strlen(key_log);
    snprintf(key_log + used, sizeof key_log - used, "%s%s %s", used ? ", " : "", where, name);
}

bool portal_view_replay(portal_view *view, bool replay, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    if (replay) {
        calls.replayed++;
        /* Ahead of presses posted before, as NSApp.postEvent(atStart:). */
        if (posted_count + view->held_count > MAX_KEYS)
            abort();
        memmove(posted + view->held_count, posted, posted_count * sizeof *posted);
        memcpy(posted, view->held, view->held_count * sizeof *posted);
        posted_count += view->held_count;
    } else {
        calls.discarded++;
        view->triggered = false;
    }
    view->holding = false;
    view->held_count = 0;
    return true;
}

bool portal_view_literal(portal_view *view, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    if (!view->triggered)
        return fail(error, "The fake holds no trigger to deliver");
    if (!view->focused)
        return fail(error, "The fake cannot deliver to a view without the keyboard");
    log_key("literal", view->trigger);
    return true;
}

/* The view whose window's keys are its own: the one holding a trigger. */
static struct portal_view *capturing(void)
{
    for (size_t i = 0; i < view_count; i++)
        if (!all[i]->destroyed && all[i]->triggered)
            return all[i];
    return NULL;
}

static struct portal_view *focused(void)
{
    for (size_t i = 0; i < view_count; i++)
        if (!all[i]->destroyed && all[i]->focused)
            return all[i];
    return NULL;
}

void portal_fake_press(portal_chord chord, bool repeat)
{
    struct press press = {chord, repeat};
    struct portal_view *view = capturing();
    if (view && view->holding) {
        if (view->held_count == MAX_KEYS)
            abort();
        view->held[view->held_count++] = press;
        log_key("held", press);
        return;
    }
    if (!view)
        view = focused();
    if (!view) {
        log_key("emacs", press);
        return;
    }
    switch (portal_input_key(target_of(view), chord, repeat)) {
    case PORTAL_KEY_PASS:
        /* Where it would go without Portal: the keyboard may have moved. */
        view = focused();
        log_key(view ? view->target : "emacs", press);
        break;
    case PORTAL_KEY_TAKE:
        log_key("taken", press);
        break;
    case PORTAL_KEY_HOLD:
        if (view->triggered) {
            view->held[view->held_count++] = press;
        } else {
            view->triggered = view->holding = true;
            view->trigger = press;
        }
        log_key("held", press);
        break;
    }
}

void portal_fake_run(void)
{
    while (posted_count) {
        struct press press = posted[0];
        memmove(posted, posted + 1, --posted_count * sizeof *posted);
        portal_fake_press(press.chord, press.repeat);
    }
}

void portal_fake_escape(void)
{
    struct portal_view *view = capturing();
    if (!view)
        view = focused();
    if (!view)
        return;
    if (view->focused)
        set_focus(NULL);
    portal_input_focus(target_of(view), false);
}

bool portal_fake_click(const char *target)
{
    for (size_t i = 0; i < view_count; i++) {
        struct portal_view *view = all[i];
        if (view->destroyed || strcmp(view->target, target) || !attached(view))
            continue;
        if (!view->focused) {
            portal_input_focus(target_of(view), true);
            portal_notify((portal_string) {"select", 6}, target_of(view), NULL, 0);
        }
        set_focus(view);
        return true;
    }
    return false;
}

const char *portal_fake_keys(void)
{
    static char keys[sizeof key_log];
    memcpy(keys, key_log, sizeof keys);
    key_log[0] = '\0';
    return keys;
}
