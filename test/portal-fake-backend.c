/* SPDX-License-Identifier: GPL-3.0-or-later */
/* An in-memory backend for the module tests.  It implements the operations of
   native/Core/include/portal.h, so the real C bindings run without AppKit,
   WebKit or Ghostty.  portal--inspect reports what each view's operations
   received, and the target "fake" reports the global settings. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "portal.h"

enum { MAX_VIEWS = 64, MAX_PROPERTIES = 32 };

struct view {
    char *target; /* NULL once closed. */
    char *kind;
    portal_property properties[MAX_PROPERTIES];
    size_t count;
};

static struct view views[MAX_VIEWS], settings = {.target = "fake"};
static int64_t next_id;
static int channel = -1;

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

static void clear(portal_property *property)
{
    free(property->integers);
    free(property->string.data);
    property->integers = NULL;
    property->string = (portal_text) {0};
}

/* VIEW's property NAME, cleared for a new value. */
static portal_property *property(struct view *view, const char *name, size_t length)
{
    for (size_t i = 0; i < view->count; i++) {
        portal_property *property = &view->properties[i];
        if (property->name.length == length && !memcmp(property->name.data, name, length)) {
            clear(property);
            return property;
        }
    }
    if (view->count == MAX_PROPERTIES)
        abort();
    portal_property *property = &view->properties[view->count++];
    property->name = copy(name, length);
    return property;
}

static const portal_property *get(const struct view *view, const char *name)
{
    for (size_t i = 0; i < view->count; i++)
        if (view->properties[i].name.length == strlen(name)
            && !memcmp(view->properties[i].name.data, name, strlen(name)))
            return &view->properties[i];
    return NULL;
}

static void set_flag(struct view *view, const char *name, bool flag)
{
    portal_property *entry = property(view, name, strlen(name));
    entry->kind = PORTAL_FLAG;
    entry->flag = flag;
}

static void set_integer(struct view *view, const char *name, int64_t integer)
{
    portal_property *entry = property(view, name, strlen(name));
    entry->kind = PORTAL_INTEGER;
    entry->integer = integer;
}

static void set_string(struct view *view, const char *name, const char *data, size_t length)
{
    portal_property *entry = property(view, name, strlen(name));
    entry->kind = PORTAL_STRING;
    entry->string = copy(data, length);
}

/* Append DATA to VIEW's string property NAME, after SEPARATOR if it is not empty. */
static void append(struct view *view, const char *name, const char *separator, const char *data,
                   size_t length)
{
    const portal_property *old = get(view, name);
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

static struct view *find(portal_string target)
{
    if (is(target, settings.target))
        return &settings;
    for (size_t i = 0; i < MAX_VIEWS; i++)
        if (views[i].target && is(target, views[i].target))
            return &views[i];
    return NULL;
}

/* TARGET's view, which must be of KIND unless KIND is NULL. */
static struct view *lookup(portal_string target, const char *kind, portal_text *error)
{
    struct view *view = find(target);
    if (!view || view == &settings || (kind && strcmp(view->kind, kind))) {
        fail(error, "No Portal view %.*s", (int) target.length, target.data);
        return NULL;
    }
    return view;
}

bool portal_open(portal_string kind, const portal_option *options, size_t count,
                 portal_text *target, portal_text *error)
{
    if (!is(kind, "web") && !is(kind, "terminal"))
        return fail(error, "Unknown Portal view kind: %.*s", (int) kind.length, kind.data);
    struct view *view = NULL;
    for (size_t i = 0; i < MAX_VIEWS && !view; i++)
        if (!views[i].target)
            view = &views[i];
    if (!view)
        return fail(error, "Too many fake views");
    char name[64];
    snprintf(name, sizeof name, "%.*s:%lld", (int) kind.length, kind.data,
             (long long) ++next_id);
    view->target = copy(name, strlen(name)).data;
    view->kind = copy(kind.data, kind.length).data;
    set_string(view, "kind", kind.data, kind.length);
    set_integer(view, "id", next_id);
    set_flag(view, "visible", false);
    for (size_t i = 0; i < count; i++) {
        portal_property *entry = property(view, options[i].name.data, options[i].name.length);
        entry->kind = options[i].is_string ? PORTAL_STRING : PORTAL_FLAG;
        if (options[i].is_string)
            entry->string = copy(options[i].string.data, options[i].string.length);
        else
            entry->flag = options[i].flag;
    }
    *target = copy(name, strlen(name));
    return true;
}

bool portal_place(portal_string target, portal_edges edges, portal_string title,
                  portal_text *error)
{
    struct view *view = lookup(target, NULL, error);
    if (!view)
        return false;
    if (edges.right <= edges.left || edges.bottom <= edges.top)
        return fail(error, "Expected [LEFT TOP RIGHT BOTTOM] with positive dimensions");
    portal_property *entry = property(view, "edges", strlen("edges"));
    entry->kind = PORTAL_INTEGERS;
    entry->count = 4;
    entry->integers = malloc(4 * sizeof *entry->integers);
    memcpy(entry->integers, (int64_t[]) {edges.left, edges.top, edges.right, edges.bottom},
           4 * sizeof *entry->integers);
    set_string(view, "title", title.data, title.length);
    set_flag(view, "visible", true);
    return true;
}

bool portal_hide(portal_string target, portal_text *error)
{
    struct view *view = lookup(target, NULL, error);
    if (view)
        set_flag(view, "visible", false);
    return view != NULL;
}

bool portal_close(portal_string target, portal_text *error)
{
    struct view *view = lookup(target, NULL, error);
    if (!view)
        return false;
    for (size_t i = 0; i < view->count; i++) {
        clear(&view->properties[i]);
        free(view->properties[i].name.data);
    }
    free(view->target);
    free(view->kind);
    *view = (struct view) {0};
    return true;
}

bool portal_inspect(portal_string target, portal_state *state, portal_text *error)
{
    (void) error;
    const struct view *view = find(target);
    *state = (portal_state) {.found = view != NULL};
    if (!view)
        return true;
    state->count = view->count;
    state->properties = calloc(view->count + 1, sizeof *state->properties);
    for (size_t i = 0; i < view->count; i++) {
        const portal_property *from = &view->properties[i];
        portal_property *to = &state->properties[i];
        *to = *from;
        to->name = copy(from->name.data, from->name.length);
        if (from->kind == PORTAL_STRING)
            to->string = copy(from->string.data, from->string.length);
        if (from->kind == PORTAL_INTEGERS) {
            to->integers = malloc(from->count * sizeof *to->integers + 1);
            memcpy(to->integers, from->integers, from->count * sizeof *to->integers);
        }
    }
    return true;
}

/* Announce each connection on the pipe, so tests see the descriptor works. */
bool portal_channel(int fd, portal_text *error)
{
    (void) error;
    if (channel >= 0)
        close(channel);
    channel = fd;
    set_flag(&settings, "channel", fd >= 0);
    if (fd >= 0 && write(fd, "fake connected\n", 15) != 15)
        return fail(error, "Could not write to the pipe");
    return true;
}

bool portal_web_load(portal_string target, portal_string url, portal_text *error)
{
    struct view *web = lookup(target, "web", error);
    if (web)
        set_string(web, "url", url.data, url.length);
    return web != NULL;
}

/* TARGET's view, which must be a hosted web view. */
static struct view *hosted(portal_string target, portal_text *error)
{
    struct view *web = lookup(target, "web", error);
    const portal_property *option = web ? get(web, "hosted") : NULL;
    if (web && !(option && (option->kind == PORTAL_STRING || option->flag))) {
        fail(error, "Web view %.*s is not a hosted app, so it has no bridge", (int) target.length,
             target.data);
        return NULL;
    }
    return web;
}

/* The fake app echoes what Emacs sends it. */
bool portal_web_send(portal_string target, portal_string json, portal_text *error)
{
    struct view *web = hosted(target, error);
    if (web)
        append(web, "messages", ",", json.data, json.length);
    return web != NULL;
}

bool portal_web_receive(portal_string target, portal_text *json, portal_text *error)
{
    struct view *web = hosted(target, error);
    if (!web)
        return false;
    const portal_property *messages = get(web, "messages");
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

bool portal_terminal_theme(const portal_string *name, portal_text *error)
{
    if (!name) {
        set_flag(&settings, "theme", false);
        return true;
    }
    for (size_t i = 0; i < sizeof themes / sizeof *themes; i++)
        if (is(*name, themes[i])) {
            set_string(&settings, "theme", name->data, name->length);
            return true;
        }
    return fail(error, "Unknown terminal theme: %.*s", (int) name->length, name->data);
}

bool portal_terminal_themes(portal_texts *names, portal_text *error)
{
    (void) error;
    size_t count = sizeof themes / sizeof *themes;
    *names = (portal_texts) {calloc(count, sizeof *names->items), count};
    for (size_t i = 0; i < count; i++)
        names->items[i] = copy(themes[i], strlen(themes[i]));
    return true;
}

/* The fake terminal's scrollback is everything pasted into it. */
bool portal_terminal_paste(portal_string target, portal_string text, bool enter,
                           portal_text *error)
{
    struct view *terminal = lookup(target, "terminal", error);
    if (!terminal)
        return false;
    append(terminal, "text", "", text.data, text.length);
    if (enter)
        append(terminal, "text", "", "\n", 1);
    return true;
}

bool portal_terminal_text(portal_string target, portal_text *text, portal_text *error)
{
    struct view *terminal = lookup(target, "terminal", error);
    if (!terminal)
        return false;
    const portal_property *scrollback = get(terminal, "text");
    *text = scrollback ? copy(scrollback->string.data, scrollback->string.length) : copy("", 0);
    return true;
}

bool portal_terminal_bindings(portal_string json, portal_text *error)
{
    if (!json.length || json.data[0] != '{')
        return fail(error, "Invalid native terminal binding");
    set_string(&settings, "bindings", json.data, json.length);
    return true;
}

bool portal_input_prefix(portal_string character, int64_t flags, portal_text *error)
{
    if (character.length != 1 || flags <= 0)
        return fail(error, "Expected one modified ASCII prefix");
    set_string(&settings, "prefix", character.data, character.length);
    set_integer(&settings, "flags", flags);
    return true;
}

/* Like the native module, report false for an unknown target, and for
   "pending" while no handoff is pending. */
bool portal_input(portal_string target, portal_string action, int64_t serial, bool *result,
                  portal_text *error)
{
    struct view *view = find(target);
    if (is(action, "unknown"))
        return fail(error, "Unknown Portal input action: unknown");
    *result = view && view != &settings && !is(action, "pending");
    if (*result) {
        set_string(view, "action", action.data, action.length);
        set_integer(view, "serial", serial);
    }
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

bool portal_toolbar_action(portal_string target, portal_string action, portal_text *state,
                           portal_text *error)
{
    struct view *web = find(target);
    if (!web || web == &settings || strcmp(web->kind, "web"))
        return fail(error, "No toolbar controls for this native view");
    char json[256];
    int length = snprintf(json, sizeof json, "{\"action\":\"%.*s\"}", (int) action.length,
                          action.data);
    *state = copy(json, length < (int) sizeof json ? (size_t) length : sizeof json - 1);
    return true;
}
