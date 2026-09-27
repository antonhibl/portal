/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Portal's Emacs module: registers the Lisp interface of docs/adr/0002,
   converts arguments and results, and signals errors.  Each Lisp function
   copies its arguments, calls one operation from portal.h, and converts and
   frees what the operation returns.  No Emacs environment or value outlives
   the module call that received it. */
#include <emacs-module.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "portal.h"

int plugin_is_GPL_compatible;

/* A Lisp function.  Emacs checks the arity; only optional arguments use NARGS. */
#define UNUSED __attribute__((unused))
#define LISP_FUNCTION(name)                                                               \
    static emacs_value name(emacs_env *env, UNUSED ptrdiff_t nargs, UNUSED emacs_value *args, \
                            UNUSED void *data)

static bool returning(emacs_env *env)
{
    return env->non_local_exit_check(env) == emacs_funcall_exit_return;
}

static emacs_value symbol(emacs_env *env, const char *name)
{
    return env->intern(env, name);
}

static emacs_value list(emacs_env *env, emacs_value *items, size_t count)
{
    return env->funcall(env, symbol(env, "list"), (ptrdiff_t) count, items);
}

/* Signal `error' with (format FORMAT ARGUMENT), or FORMAT if ARGUMENT is null.
   An earlier pending signal or throw is kept. */
static void signal_error(emacs_env *env, const char *format, emacs_value argument)
{
    emacs_value arguments[] = {env->make_string(env, format, (ptrdiff_t) strlen(format)),
                               argument};
    if (returning(env))
        env->funcall(env, symbol(env, "error"), argument ? 2 : 1, arguments);
}

static void out_of_memory(emacs_env *env)
{
    signal_error(env, "Portal is out of memory", NULL);
}

static portal_string borrow(portal_text text)
{
    return (portal_string) {text.data, text.length};
}

/* Whether BYTES is well-formed UTF-8.  Emacs copies a unibyte string's raw
   bytes, and a surrogate character's bytes, without checking them. */
static bool valid_utf8(const unsigned char *bytes, size_t length)
{
    for (size_t i = 0; i < length;) {
        size_t extra;
        uint32_t code, minimum;
        if (bytes[i] < 0x80) {
            i++;
            continue;
        } else if ((bytes[i] & 0xe0) == 0xc0) {
            extra = 1, code = bytes[i] & 0x1f, minimum = 0x80;
        } else if ((bytes[i] & 0xf0) == 0xe0) {
            extra = 2, code = bytes[i] & 0x0f, minimum = 0x800;
        } else if ((bytes[i] & 0xf8) == 0xf0) {
            extra = 3, code = bytes[i] & 0x07, minimum = 0x10000;
        } else {
            return false;
        }
        if (length - i <= extra)
            return false;
        for (size_t k = 1; k <= extra; k++) {
            if ((bytes[i + k] & 0xc0) != 0x80)
                return false;
            code = code << 6 | (bytes[i + k] & 0x3f);
        }
        if (code < minimum || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff))
            return false;
        i += extra + 1;
    }
    return true;
}

/* Copy the Lisp string VALUE into *TEXT, which the caller frees. */
static bool read_text(emacs_env *env, emacs_value value, portal_text *text)
{
    ptrdiff_t size = 0;
    if (!env->copy_string_contents(env, value, NULL, &size))
        return false;
    char *bytes = malloc((size_t) size);
    if (!bytes) {
        out_of_memory(env);
        return false;
    }
    if (!env->copy_string_contents(env, value, bytes, &size)) {
        free(bytes);
        return false;
    }
    if (!valid_utf8((const unsigned char *) bytes, (size_t) size - 1)) {
        free(bytes);
        emacs_value data[] = {symbol(env, "unicode-string-p"), value};
        env->non_local_exit_signal(env, symbol(env, "wrong-type-argument"), list(env, data, 2));
        return false;
    }
    *text = (portal_text) {bytes, (size_t) size - 1};
    return true;
}

/* Copy the vector [LEFT TOP RIGHT BOTTOM] of integers into *EDGES. */
static bool read_edges(emacs_env *env, emacs_value vector, portal_edges *edges)
{
    ptrdiff_t size = env->vec_size(env, vector);
    if (!returning(env))
        return false;
    if (size != 4) {
        signal_error(env, "Expected [LEFT TOP RIGHT BOTTOM]", NULL);
        return false;
    }
    int64_t values[4];
    for (ptrdiff_t i = 0; i < 4; i++) {
        values[i] = env->extract_integer(env, env->vec_get(env, vector, i));
        if (!returning(env))
            return false;
    }
    *edges = (portal_edges) {values[0], values[1], values[2], values[3]};
    return true;
}

/* Copies of portal--open's options: a name and a string value for each. */
struct options {
    portal_option *items;
    portal_text *texts;
    size_t count;
};

static void free_options(struct options *options)
{
    for (size_t i = 0; options->texts && i < 2 * options->count; i++)
        free(options->texts[i].data);
    free(options->texts);
    free(options->items);
}

/* Read a plist of keywords to strings, t or nil, such as (:directory "~/" :quick t). */
static bool read_options(emacs_env *env, emacs_value plist, struct options *options)
{
    emacs_value length = env->funcall(env, symbol(env, "proper-list-p"), 1, &plist);
    if (!returning(env))
        return false;
    intmax_t size = env->is_not_nil(env, length) ? env->extract_integer(env, length) : -1;
    if (size < 0 || size % 2 != 0) {
        signal_error(env, "Options must be a plist", NULL);
        return false;
    }
    emacs_value vector = env->funcall(env, symbol(env, "vconcat"), 1, &plist);
    if (!returning(env))
        return false;
    options->count = (size_t) size / 2;
    options->items = calloc(options->count + 1, sizeof *options->items);
    options->texts = calloc(2 * options->count + 1, sizeof *options->texts);
    if (!options->items || !options->texts) {
        out_of_memory(env);
        return false;
    }
    for (size_t i = 0; i < options->count; i++) {
        emacs_value key = env->vec_get(env, vector, (ptrdiff_t) (2 * i));
        emacs_value value = env->vec_get(env, vector, (ptrdiff_t) (2 * i + 1));
        emacs_value keyword = env->funcall(env, symbol(env, "keywordp"), 1, &key);
        if (!returning(env))
            return false;
        if (!env->is_not_nil(env, keyword)) {
            signal_error(env, "Option names must be keywords", NULL);
            return false;
        }
        portal_option *option = &options->items[i];
        portal_text *name = &options->texts[2 * i], *string = name + 1;
        if (!read_text(env, env->funcall(env, symbol(env, "symbol-name"), 1, &key), name))
            return false;
        option->name = (portal_string) {name->data + 1, name->length - 1};
        if (!env->is_not_nil(env, value)) {
            option->flag = false;
        } else if (env->eq(env, value, symbol(env, "t"))) {
            option->flag = true;
        } else if (env->eq(env, env->type_of(env, value), symbol(env, "string"))) {
            if (!read_text(env, value, string))
                return false;
            option->is_string = true;
            option->string = borrow(*string);
        } else {
            signal_error(env, "Option %s must be a string, t or nil", key);
            return false;
        }
    }
    return true;
}

static emacs_value boolean(emacs_env *env, bool value)
{
    return symbol(env, value ? "t" : "nil");
}

static emacs_value string(emacs_env *env, portal_text text)
{
    return env->make_string(env, text.data ? text.data : "", (ptrdiff_t) text.length);
}

/* Convert TEXT to a Lisp string and free it. */
static emacs_value take_string(emacs_env *env, portal_text *text)
{
    emacs_value value = string(env, *text);
    free(text->data);
    *text = (portal_text) {0};
    return value;
}

/* Convert TEXTS to a list of Lisp strings and free them. */
static emacs_value take_strings(emacs_env *env, portal_texts *texts)
{
    emacs_value result = NULL;
    emacs_value *items = calloc(texts->count + 1, sizeof *items);
    if (items) {
        for (size_t i = 0; i < texts->count; i++)
            items[i] = string(env, texts->items[i]);
        result = list(env, items, texts->count);
    } else {
        out_of_memory(env);
    }
    free(items);
    for (size_t i = 0; i < texts->count; i++)
        free(texts->items[i].data);
    free(texts->items);
    *texts = (portal_texts) {0};
    return result;
}

static emacs_value property_value(emacs_env *env, const portal_property *property)
{
    switch (property->kind) {
    case PORTAL_FLAG:
        return boolean(env, property->flag);
    case PORTAL_INTEGER:
        return env->make_integer(env, property->integer);
    case PORTAL_INTEGERS: {
        emacs_value result = NULL;
        emacs_value *items = calloc(property->count + 1, sizeof *items);
        if (!items) {
            out_of_memory(env);
            return NULL;
        }
        for (size_t i = 0; i < property->count; i++)
            items[i] = env->make_integer(env, property->integers[i]);
        result = list(env, items, property->count);
        free(items);
        return result;
    }
    case PORTAL_STRING:
        return string(env, property->string);
    }
    signal_error(env, "Unknown Portal property kind", NULL);
    return NULL;
}

/* The keyword :NAME. */
static emacs_value keyword(emacs_env *env, portal_text name)
{
    char *bytes = malloc(name.length + 1);
    if (!bytes) {
        out_of_memory(env);
        return NULL;
    }
    bytes[0] = ':';
    if (name.length)
        memcpy(bytes + 1, name.data, name.length);
    emacs_value text = env->make_string(env, bytes, (ptrdiff_t) name.length + 1);
    free(bytes);
    return env->funcall(env, symbol(env, "intern"), 1, &text);
}

/* Convert STATE to a plist, or nil if it was not found, and free it. */
static emacs_value take_state(emacs_env *env, portal_state *state)
{
    emacs_value result = symbol(env, "nil");
    if (state->found) {
        emacs_value *items = calloc(2 * state->count + 1, sizeof *items);
        if (items) {
            for (size_t i = 0; i < state->count; i++) {
                items[2 * i] = keyword(env, state->properties[i].name);
                items[2 * i + 1] = property_value(env, &state->properties[i]);
            }
            result = list(env, items, 2 * state->count);
        } else {
            out_of_memory(env);
        }
        free(items);
    }
    for (size_t i = 0; i < state->count; i++) {
        portal_property *property = &state->properties[i];
        free(property->name.data);
        if (property->kind == PORTAL_INTEGERS)
            free(property->integers);
        else if (property->kind == PORTAL_STRING)
            free(property->string.data);
    }
    free(state->properties);
    *state = (portal_state) {0};
    return result;
}

/* Signal a backend's ERROR and free it. */
static void fail(emacs_env *env, portal_text *error)
{
    if (error->data)
        signal_error(env, "%s", take_string(env, error));
    else
        signal_error(env, "Portal native call failed", NULL);
}

/* Return t if the operation SUCCEEDED; otherwise signal ERROR. */
static emacs_value done(emacs_env *env, bool succeeded, portal_text *error)
{
    if (succeeded)
        return symbol(env, "t");
    fail(env, error);
    return NULL;
}

LISP_FUNCTION(Fopen)
{
    portal_text kind = {0}, target = {0}, error = {0};
    struct options options = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &kind) && read_options(env, args[1], &options)) {
        if (portal_open(borrow(kind), options.items, options.count, &target, &error))
            result = take_string(env, &target);
        else
            fail(env, &error);
    }
    free(kind.data);
    free_options(&options);
    return result;
}

LISP_FUNCTION(Fplace)
{
    portal_text target = {0}, title = {0}, error = {0};
    portal_edges edges;
    emacs_value result = NULL;
    if (read_text(env, args[0], &target) && read_edges(env, args[1], &edges)
        && read_text(env, args[2], &title))
        result = done(env, portal_place(borrow(target), edges, borrow(title), &error), &error);
    free(target.data);
    free(title.data);
    return result;
}

LISP_FUNCTION(Fhide)
{
    portal_text target = {0}, error = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &target))
        result = done(env, portal_hide(borrow(target), &error), &error);
    free(target.data);
    return result;
}

LISP_FUNCTION(Fclose)
{
    portal_text target = {0}, error = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &target))
        result = done(env, portal_close(borrow(target), &error), &error);
    free(target.data);
    return result;
}

LISP_FUNCTION(Finspect)
{
    portal_text target = {0}, error = {0};
    portal_state state = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &target)) {
        if (portal_inspect(borrow(target), &state, &error))
            result = take_state(env, &state);
        else
            fail(env, &error);
    }
    free(target.data);
    return result;
}

LISP_FUNCTION(Fchannel)
{
    portal_text error = {0};
    int fd = env->is_not_nil(env, args[0]) ? env->open_channel(env, args[0]) : -1;
    if (!returning(env))
        return NULL;
    bool succeeded = portal_channel(fd, &error);
    if (!succeeded && fd >= 0)
        close(fd);
    return done(env, succeeded, &error);
}

LISP_FUNCTION(Fweb_load)
{
    portal_text target = {0}, url = {0}, error = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &target) && read_text(env, args[1], &url))
        result = done(env, portal_web_load(borrow(target), borrow(url), &error), &error);
    free(target.data);
    free(url.data);
    return result;
}

LISP_FUNCTION(Fweb_send)
{
    portal_text target = {0}, json = {0}, error = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &target) && read_text(env, args[1], &json))
        result = done(env, portal_web_send(borrow(target), borrow(json), &error), &error);
    free(target.data);
    free(json.data);
    return result;
}

LISP_FUNCTION(Fweb_receive)
{
    portal_text target = {0}, json = {0}, error = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &target)) {
        if (portal_web_receive(borrow(target), &json, &error))
            result = take_string(env, &json);
        else
            fail(env, &error);
    }
    free(target.data);
    return result;
}

LISP_FUNCTION(Fterminal_theme)
{
    portal_text name = {0}, error = {0};
    emacs_value result = NULL;
    bool named = env->is_not_nil(env, args[0]);
    if (!named || read_text(env, args[0], &name)) {
        portal_string borrowed = borrow(name);
        result = done(env, portal_terminal_theme(named ? &borrowed : NULL, &error), &error);
    }
    free(name.data);
    return result;
}

LISP_FUNCTION(Fterminal_themes)
{
    portal_texts names = {0};
    portal_text error = {0};
    if (portal_terminal_themes(&names, &error))
        return take_strings(env, &names);
    fail(env, &error);
    return NULL;
}

LISP_FUNCTION(Fterminal_paste)
{
    portal_text target = {0}, text = {0}, error = {0};
    emacs_value result = NULL;
    bool enter = nargs > 2 && env->is_not_nil(env, args[2]);
    if (read_text(env, args[0], &target) && read_text(env, args[1], &text))
        result = done(env, portal_terminal_paste(borrow(target), borrow(text), enter, &error),
                      &error);
    free(target.data);
    free(text.data);
    return result;
}

LISP_FUNCTION(Fterminal_text)
{
    portal_text target = {0}, text = {0}, error = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &target)) {
        if (portal_terminal_text(borrow(target), &text, &error))
            result = take_string(env, &text);
        else
            fail(env, &error);
    }
    free(target.data);
    return result;
}

LISP_FUNCTION(Fterminal_bindings)
{
    portal_text json = {0}, error = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &json))
        result = done(env, portal_terminal_bindings(borrow(json), &error), &error);
    free(json.data);
    return result;
}

LISP_FUNCTION(Finput_prefix)
{
    portal_text character = {0}, error = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &character)) {
        int64_t flags = env->extract_integer(env, args[1]);
        if (returning(env))
            result = done(env, portal_input_prefix(borrow(character), flags, &error), &error);
    }
    free(character.data);
    return result;
}

LISP_FUNCTION(Finput)
{
    portal_text target = {0}, action = {0}, error = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &target) && read_text(env, args[1], &action)) {
        int64_t serial =
            nargs > 2 && env->is_not_nil(env, args[2]) ? env->extract_integer(env, args[2]) : 0;
        bool performed = false;
        if (returning(env)) {
            if (portal_input(borrow(target), borrow(action), serial, &performed, &error))
                result = boolean(env, performed);
            else
                fail(env, &error);
        }
    }
    free(target.data);
    free(action.data);
    return result;
}

LISP_FUNCTION(Ftoolbar)
{
    portal_text error = {0};
    bool enabled = env->is_not_nil(env, args[0]);
    if (portal_toolbar(enabled, &error))
        return boolean(env, enabled);
    fail(env, &error);
    return NULL;
}

LISP_FUNCTION(Ftoolbar_theme)
{
    portal_text json = {0}, error = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &json))
        result = done(env, portal_toolbar_theme(borrow(json), &error), &error);
    free(json.data);
    return result;
}

LISP_FUNCTION(Ftoolbar_action)
{
    portal_text target = {0}, action = {0}, state = {0}, error = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &target) && read_text(env, args[1], &action)) {
        if (portal_toolbar_action(borrow(target), borrow(action), &state, &error))
            result = take_string(env, &state);
        else
            fail(env, &error);
    }
    free(target.data);
    free(action.data);
    return result;
}

static const struct {
    const char *name;
    ptrdiff_t minimum, maximum;
    emacs_function function;
    const char *documentation;
} exports[] = {
    {"portal--open", 2, 2, Fopen,
     "Open a view of KIND (\"terminal\" or \"web\") with an OPTIONS plist; return its target, "
     "such as \"web:1\"."},
    {"portal--place", 3, 3, Fplace,
     "Show TARGET at EDGES [LEFT TOP RIGHT BOTTOM] in the frame titled TITLE."},
    {"portal--hide", 1, 1, Fhide, "Hide TARGET, keeping its session alive."},
    {"portal--close", 1, 1, Fclose, "End TARGET and release its view."},
    {"portal--inspect", 1, 1, Finspect,
     "Return TARGET's native state as a plist, or nil for an unknown target."},
    {"portal--channel", 1, 1, Fchannel,
     "Send every view's records, lines of \"TYPE TARGET FIELD...\", to pipe PROCESS; nil "
     "disconnects."},
    {"portal--web-load", 2, 2, Fweb_load,
     "Load URL, an absolute http, https, file, data or about URL, in web view TARGET."},
    {"portal--web-send", 2, 2, Fweb_send,
     "Send the JSON object JSON to hosted web view TARGET's app over its bridge."},
    {"portal--web-receive", 1, 1, Fweb_receive,
     "Return the messages hosted web view TARGET's app sent over its bridge, as a JSON array."},
    {"portal--terminal-theme", 1, 1, Fterminal_theme,
     "Apply named THEME to all terminals; nil restores system appearance defaults."},
    {"portal--terminal-themes", 0, 0, Fterminal_themes,
     "Return the available terminal theme names."},
    {"portal--terminal-paste", 2, 3, Fterminal_paste,
     "Paste TEXT into terminal TARGET; press Enter if ENTER is non-nil."},
    {"portal--terminal-text", 1, 1, Fterminal_text,
     "Select all of TARGET's scrollback and return its text. Leaves the native selection "
     "active."},
    {"portal--terminal-bindings", 1, 1, Fterminal_bindings,
     "Atomically replace runtime binding profiles from JSON."},
    {"portal--input-prefix", 2, 2, Finput_prefix,
     "Set the native prefix CHARACTER and AppKit modifier FLAGS."},
    {"portal--input", 2, 3, Finput,
     "Perform ACTION on native TARGET, optionally validating its handoff SERIAL."},
    {"portal--toolbar", 1, 1, Ftoolbar, "Show or hide native toolbars live."},
    {"portal--toolbar-theme", 1, 1, Ftoolbar_theme,
     "Apply toolbar face colors from JSON RGB arrays."},
    {"portal--toolbar-action", 2, 2, Ftoolbar_action,
     "Perform ACTION on TARGET and return its native state as JSON."},
};

int emacs_module_init(struct emacs_runtime *runtime)
{
    if (runtime->size < (ptrdiff_t) sizeof *runtime)
        return 1;
    emacs_env *env = runtime->get_environment(runtime);
    if (env->size < (ptrdiff_t) sizeof *env)
        return 2;
    for (size_t i = 0; i < sizeof exports / sizeof *exports; i++) {
        emacs_value arguments[] = {
            symbol(env, exports[i].name),
            env->make_function(env, exports[i].minimum, exports[i].maximum, exports[i].function,
                               exports[i].documentation, NULL)};
        env->funcall(env, symbol(env, "fset"), 2, arguments);
        if (!returning(env))
            return 1;
    }
    emacs_value feature = symbol(env, "portal-native-module");
    env->funcall(env, symbol(env, "provide"), 1, &feature);
    return returning(env) ? 0 : 1;
}
