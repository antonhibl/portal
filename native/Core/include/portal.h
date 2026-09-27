/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The platform interface of Portal's Emacs module.

   The C core in native/Core is the module's portable part.  emacs.c
   registers the Lisp interface (docs/adr/0002), converts arguments and
   results, and signals errors; it calls one operation below per Lisp
   function.  channel.c owns the pipe that carries records to Emacs.  The
   platform implements the operations below: the production module links the
   macOS backend, native/Backend.swift, and the module tests link
   test/portal-fake-backend.c.  Nothing here knows about Emacs values or a UI
   toolkit.

   For now these operations mirror the Lisp functions.  They are becoming the
   platform interface of docs/adr/0003: as Portal's rules move into the C
   core, their operations here give way to the primitives a platform must
   provide.

   Threads: the bindings call each operation synchronously, on the thread that
   runs the Emacs module call.  A backend may require a particular thread and
   fail otherwise; the macOS backend requires the main thread.  The platform
   calls into the core, below, only on that thread too.

   Borrowed data: a portal_string, and any array argument, belongs to the
   caller and is valid only until the call returns.  A portal_string is UTF-8
   with an explicit length, which may include NUL bytes; it is also
   NUL-terminated.  The callee copies whatever it keeps.

   Owned data: text an operation returns was allocated with malloc, and the
   bindings free it.  It is valid UTF-8.  Structured results are JSON.

   Errors: an operation returns true on success.  On failure it returns false
   and sets *error to a message for a Lisp `error' signal, leaving its other
   outputs unset.

   Callbacks: none into Emacs.  Native work that outlives a call uses copies,
   and native notifications reach Emacs as records through the core's pipe, so
   no native code retains an Emacs environment or value.  The platform may
   call the core's functions at the end of this file whenever it runs on the
   module thread, with borrowed arguments; they never reach Emacs. */
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

/* Lifecycle, for every view kind.  Targets look like "web:3". */
bool portal_open(portal_string kind, const portal_option *options, size_t count,
                 portal_text *target, portal_text *error);
bool portal_place(portal_string target, portal_edges edges, portal_string title,
                  portal_text *error);
bool portal_hide(portal_string target, portal_text *error);
bool portal_close(portal_string target, portal_text *error);
/* STATE is a JSON object of flags, integers, integer arrays and strings, or
   null for an unknown target. */
bool portal_inspect(portal_string target, portal_text *state, portal_text *error);

/* Web views.  JSON is a JSON array of the messages received. */
bool portal_web_load(portal_string target, portal_string url, portal_text *error);
bool portal_web_send(portal_string target, portal_string json, portal_text *error);
bool portal_web_receive(portal_string target, portal_text *json, portal_text *error);

/* Terminal views.  A null NAME restores the default theme; NAMES is a JSON
   array of strings. */
bool portal_terminal_theme(const portal_string *name, portal_text *error);
bool portal_terminal_themes(portal_text *names, portal_text *error);
bool portal_terminal_paste(portal_string target, portal_string text, bool enter,
                           portal_text *error);
bool portal_terminal_text(portal_string target, portal_text *text, portal_text *error);
bool portal_terminal_bindings(portal_string json, portal_text *error);

/* Input.  SERIAL is 0 when absent. */
bool portal_input_prefix(portal_string character, int64_t flags, portal_text *error);
bool portal_input(portal_string target, portal_string action, int64_t serial,
                  bool *result, portal_text *error);

/* Toolbar.  STATE is a JSON object. */
bool portal_toolbar(bool enabled, portal_text *error);
bool portal_toolbar_theme(portal_string json, portal_text *error);
bool portal_toolbar_action(portal_string target, portal_string action,
                           portal_text *state, portal_text *error);

/* Timers, implemented by the platform.  Call portal_timer_fired(TOKEN) once,
   from the platform's event loop on the module thread, no sooner than
   MILLISECONDS from now; never from inside this call.  A timer cannot fail
   and is never cancelled: the core cancels one by ignoring its token when it
   fires.  The core chooses TOKEN, which is never 0 and never reused. */
void portal_timer_start(uint64_t token, uint64_t milliseconds);

/* Calls into the core, implemented by the core for the platform. */

/* Send Emacs the record "TYPE TARGET FIELD...", one line of COUNT + 2 words
   joined by spaces.  Each word is nonempty printable ASCII without spaces,
   and the line, with its newline, is at most PIPE_BUF bytes, so each write
   of it is atomic.  Records reach Emacs in the order they are sent: while
   the pipe is full or disconnected, a record waits with those sent after it
   and none is lost.  Returns false only for a record that will never be sent:
   malformed, too long, or with no memory to hold it while it waits.  Payloads
   that may be longer stay with the platform, which announces them here. */
bool portal_notify(portal_string type, portal_string target, const portal_string *fields,
                   size_t count);
/* A timer from portal_timer_start has fired. */
void portal_timer_fired(uint64_t token);

#endif
