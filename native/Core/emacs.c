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

/* A Lisp function.  Emacs checks the arity. */
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

/* Convert TEXT to a Lisp string and free it. */
static emacs_value take_string(emacs_env *env, portal_text *text)
{
    emacs_value value =
        env->make_string(env, text->data ? text->data : "", (ptrdiff_t) text->length);
    free(text->data);
    *text = (portal_text) {0};
    return value;
}

/* Parse the JSON TEXT, with objects as plists, arrays as lists, and null and
   false as nil; free it. */
static emacs_value take_json(emacs_env *env, portal_text *text)
{
    emacs_value nil = symbol(env, "nil");
    emacs_value arguments[] = {take_string(env, text),
                               symbol(env, ":object-type"), symbol(env, "plist"),
                               symbol(env, ":array-type"), symbol(env, "list"),
                               symbol(env, ":null-object"), nil,
                               symbol(env, ":false-object"), nil};
    return env->funcall(env, symbol(env, "json-parse-string"),
                        sizeof arguments / sizeof *arguments, arguments);
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

/* A Lisp function whose arguments, at most two, are all strings.  OPERATION
   receives their copies, and RESULT says what reaches Lisp. */
struct strings_function {
    bool (*operation)(const portal_string *arguments, portal_text *result, portal_text *error);
    enum { RESULT_T, RESULT_STRING, RESULT_JSON } result;
};

LISP_FUNCTION(Fstrings)
{
    const struct strings_function *function = data;
    portal_text copies[2] = {{0}}, result = {0}, error = {0};
    portal_string arguments[2];
    emacs_value value = NULL;
    ptrdiff_t count = 0;
    while (count < nargs && read_text(env, args[count], &copies[count])) {
        arguments[count] = borrow(copies[count]);
        count++;
    }
    if (count == nargs) {
        if (!function->operation(arguments, &result, &error))
            fail(env, &error);
        else if (function->result == RESULT_T)
            value = symbol(env, "t");
        else if (function->result == RESULT_STRING)
            value = take_string(env, &result);
        else
            value = take_json(env, &result);
    }
    while (count > 0)
        free(copies[--count].data);
    return value;
}

/* How each strings function calls its operation, with arguments A. */
#define STRINGS(name, call)                                                        \
    static bool name(UNUSED const portal_string *a, UNUSED portal_text *result, \
                     portal_text *error)                                          \
    {                                                                             \
        return call;                                                              \
    }
STRINGS(hide, portal_hide(a[0], error))
STRINGS(close_view, portal_close(a[0], error))
STRINGS(inspect, portal_inspect(a[0], result, error))
STRINGS(web_load, portal_web_load(a[0], a[1], error))
STRINGS(web_send, portal_web_send(a[0], a[1], error))
STRINGS(web_receive, portal_web_receive(a[0], result, error))
STRINGS(terminal_themes, portal_terminal_themes(result, error))
STRINGS(terminal_text, portal_terminal_text(a[0], result, error))
STRINGS(terminal_bindings, portal_terminal_bindings(a[0], error))
STRINGS(toolbar_theme, portal_toolbar_theme(a[0], error))
STRINGS(toolbar_action, portal_toolbar_action(a[0], a[1], result, error))

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

#define STRINGS_FUNCTION(name, result) \
    Fstrings, &(const struct strings_function) {name, result}

static const struct {
    const char *name;
    ptrdiff_t minimum, maximum;
    emacs_function function;
    const void *data;
    const char *documentation;
} exports[] = {
    {"portal--open", 2, 2, Fopen, NULL,
     "Open a view of KIND (\"terminal\" or \"web\") with an OPTIONS plist; return its target, "
     "such as \"web:1\"."},
    {"portal--place", 3, 3, Fplace, NULL,
     "Show TARGET at EDGES [LEFT TOP RIGHT BOTTOM] in the frame titled TITLE."},
    {"portal--hide", 1, 1, STRINGS_FUNCTION(hide, RESULT_T),
     "Hide TARGET, keeping its session alive."},
    {"portal--close", 1, 1, STRINGS_FUNCTION(close_view, RESULT_T),
     "End TARGET and release its view."},
    {"portal--inspect", 1, 1, STRINGS_FUNCTION(inspect, RESULT_JSON),
     "Return TARGET's native state as a plist, or nil for an unknown target."},
    {"portal--channel", 1, 1, Fchannel, NULL,
     "Send every view's records, lines of \"TYPE TARGET FIELD...\", to pipe PROCESS; nil "
     "disconnects."},
    {"portal--web-load", 2, 2, STRINGS_FUNCTION(web_load, RESULT_T),
     "Load URL, an absolute http, https, file, data or about URL, in web view TARGET."},
    {"portal--web-send", 2, 2, STRINGS_FUNCTION(web_send, RESULT_T),
     "Send the JSON object JSON to hosted web view TARGET's app over its bridge."},
    {"portal--web-receive", 1, 1, STRINGS_FUNCTION(web_receive, RESULT_STRING),
     "Return the messages hosted web view TARGET's app sent over its bridge, as a JSON array."},
    {"portal--terminal-theme", 1, 1, Fterminal_theme, NULL,
     "Apply named THEME to all terminals; nil restores system appearance defaults."},
    {"portal--terminal-themes", 0, 0, STRINGS_FUNCTION(terminal_themes, RESULT_JSON),
     "Return the available terminal theme names."},
    {"portal--terminal-paste", 2, 3, Fterminal_paste, NULL,
     "Paste TEXT into terminal TARGET; press Enter if ENTER is non-nil."},
    {"portal--terminal-text", 1, 1, STRINGS_FUNCTION(terminal_text, RESULT_STRING),
     "Select all of TARGET's scrollback and return its text. Leaves the native selection "
     "active."},
    {"portal--terminal-bindings", 1, 1, STRINGS_FUNCTION(terminal_bindings, RESULT_T),
     "Atomically replace runtime binding profiles from JSON."},
    {"portal--input-prefix", 2, 2, Finput_prefix, NULL,
     "Set the native prefix CHARACTER and AppKit modifier FLAGS."},
    {"portal--input", 2, 3, Finput, NULL,
     "Perform ACTION on native TARGET, optionally validating its handoff SERIAL."},
    {"portal--toolbar", 1, 1, Ftoolbar, NULL, "Show or hide native toolbars live."},
    {"portal--toolbar-theme", 1, 1, STRINGS_FUNCTION(toolbar_theme, RESULT_T),
     "Apply toolbar face colors from JSON RGB arrays."},
    {"portal--toolbar-action", 2, 2, STRINGS_FUNCTION(toolbar_action, RESULT_STRING),
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
                               exports[i].documentation, (void *) exports[i].data)};
        env->funcall(env, symbol(env, "fset"), 2, arguments);
        if (!returning(env))
            return 1;
    }
    emacs_value feature = symbol(env, "portal-native-module");
    env->funcall(env, symbol(env, "provide"), 1, &feature);
    return returning(env) ? 0 : 1;
}
