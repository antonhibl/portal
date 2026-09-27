/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The native operations behind Portal's Emacs module.

   native/Core/emacs.c registers the Lisp interface (docs/adr/0002), converts
   arguments and results, and signals errors.  It calls one operation below
   per Lisp function.  The production module links the macOS backend,
   native/Backend.swift; the module tests link test/portal-fake-backend.c.
   Nothing here knows about Emacs values or a UI toolkit.

   Threads: the bindings call each operation synchronously, on the thread that
   runs the Emacs module call.  A backend may require a particular thread and
   fail otherwise; the macOS backend requires the main thread.

   Borrowed data: a portal_string, and any array argument, belongs to the
   bindings and is valid only until the operation returns.  A portal_string is
   UTF-8 with an explicit length, which may include NUL bytes; it is also
   NUL-terminated.  A backend copies whatever it keeps.

   Owned data: text and arrays that an operation returns are allocated with
   malloc, each separately, and the bindings free them.  A backend returns
   valid UTF-8.

   Errors: an operation returns true on success.  On failure it returns false
   and sets *error to a message for a Lisp `error' signal, leaving its other
   outputs unset.

   Callbacks: there are none.  Native work that outlives a call uses copies,
   and native notifications reach Emacs through the pipe given to
   portal_channel, so no native code retains an Emacs environment or value. */
#ifndef PORTAL_H
#define PORTAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Borrowed UTF-8. */
typedef struct portal_string {
    const char *data;
    size_t length;
} portal_string;

/* Owned UTF-8: DATA was allocated with malloc. */
typedef struct portal_text {
    char *data;
    size_t length;
} portal_text;

/* Owned text items: ITEMS and each item's data were allocated with malloc. */
typedef struct portal_texts {
    portal_text *items;
    size_t count;
} portal_texts;

/* One entry of portal--open's options plist, such as :directory "~/" or
   :quick t.  Entries keep the plist's order; a later duplicate name wins. */
typedef struct portal_option {
    portal_string name; /* Without the leading colon. */
    bool is_string;
    portal_string string; /* When IS_STRING. */
    bool flag;            /* Otherwise: true for t, false for nil. */
} portal_option;

/* A pane's pixel edges in its frame, as `window-inside-pixel-edges'. */
typedef struct portal_edges {
    int64_t left, top, right, bottom;
} portal_edges;

typedef enum portal_value_kind {
    PORTAL_FLAG,
    PORTAL_INTEGER,
    PORTAL_INTEGERS,
    PORTAL_STRING
} portal_value_kind;

/* One property of portal--inspect's plist, owned like portal_text. */
typedef struct portal_property {
    portal_text name; /* Without the leading colon. */
    portal_value_kind kind;
    bool flag;         /* PORTAL_FLAG */
    int64_t integer;   /* PORTAL_INTEGER */
    int64_t *integers; /* PORTAL_INTEGERS, COUNT of them, allocated with malloc. */
    size_t count;
    portal_text string; /* PORTAL_STRING */
} portal_property;

/* A view's native state.  FOUND is false for an unknown target. */
typedef struct portal_state {
    bool found;
    portal_property *properties;
    size_t count;
} portal_state;

/* Lifecycle, for every view kind.  Targets look like "web:3". */
bool portal_open(portal_string kind, const portal_option *options, size_t count,
                 portal_text *target, portal_text *error);
bool portal_place(portal_string target, portal_edges edges, portal_string title,
                  portal_text *error);
bool portal_hide(portal_string target, portal_text *error);
bool portal_close(portal_string target, portal_text *error);
bool portal_inspect(portal_string target, portal_state *state, portal_text *error);
/* FD is the write end of Emacs's record pipe, or -1 to disconnect.  The
   backend owns FD once this succeeds; on failure it stays the caller's. */
bool portal_channel(int fd, portal_text *error);

/* Web views. */
bool portal_web_load(portal_string target, portal_string url, portal_text *error);
bool portal_web_send(portal_string target, portal_string json, portal_text *error);
bool portal_web_receive(portal_string target, portal_text *json, portal_text *error);

/* Terminal views.  A null NAME restores the default theme. */
bool portal_terminal_theme(const portal_string *name, portal_text *error);
bool portal_terminal_themes(portal_texts *names, portal_text *error);
bool portal_terminal_paste(portal_string target, portal_string text, bool enter,
                           portal_text *error);
bool portal_terminal_text(portal_string target, portal_text *text, portal_text *error);
bool portal_terminal_bindings(portal_string json, portal_text *error);

/* Input.  SERIAL is 0 when absent. */
bool portal_input_prefix(portal_string character, int64_t flags, portal_text *error);
bool portal_input(portal_string target, portal_string action, int64_t serial,
                  bool *result, portal_text *error);

/* Toolbar. */
bool portal_toolbar(bool enabled, portal_text *error);
bool portal_toolbar_theme(portal_string json, portal_text *error);
bool portal_toolbar_action(portal_string target, portal_string action,
                           portal_text *state, portal_text *error);

#endif
