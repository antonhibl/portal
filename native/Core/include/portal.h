/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The platform interface of Portal's Emacs module.

   The C core in native/Core is the module's portable part.  emacs.c
   registers the Lisp interface (docs/adr/0002), converts arguments and
   results, and signals errors.  views.c owns every Portal view's identity
   and lifecycle, and channel.c owns the pipe that carries records to Emacs.
   The platform implements the operations below: the production module links
   the macOS backend, native/Backend.swift, and the core's tests link
   test/portal-fake-backend.c.  Nothing here knows about Emacs values or a UI
   toolkit.

   These operations are becoming the primitives of docs/adr/0003.  The view
   lifecycle already is; the web, terminal, input and toolbar operations
   still mirror their Lisp functions, until their rules move into the core.

   Threads: the core calls each operation synchronously, on the thread that
   runs the Emacs module call.  A backend may require a particular thread and
   fail otherwise; the macOS backend requires the main thread.  The platform
   calls into the core, below, only on that thread too.

   Borrowed data: a portal_string, and any array argument, belongs to the
   caller and is valid only until the call returns.  A portal_string is UTF-8
   with an explicit length, which may include NUL bytes; it is also
   NUL-terminated.  The callee copies whatever it keeps.

   Owned data: text an operation returns was allocated with malloc, and the
   core frees it.  It is valid UTF-8.  Structured results are JSON.

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

/* A rectangle in a frame, in Emacs's frame pixels, as
   `window-inside-pixel-edges' measures them: the origin is the top left of
   the frame's native content area, and y grows downward.  WIDTH and HEIGHT
   are positive, and every value fits in 32 bits.  The platform converts it
   to its own coordinates and scale; on macOS, Emacs's pixels are AppKit
   points, so only the y axis flips. */
typedef struct portal_rect {
    int64_t x, y, width, height;
} portal_rect;

/* A view kind (CONTEXT.md). */
typedef enum portal_kind { PORTAL_WEB, PORTAL_TERMINAL } portal_kind;

/* A native view, opaque to the core. */
typedef struct portal_view portal_view;

/* Native views.  The core owns every view from create to destroy, and never
   passes a view to the platform after destroying it: it resolves each Lisp
   target to its view, checks the view's kind, and keeps the bookkeeping that
   every kind shares: its identity, whether it is attached, and where.  Each
   primitive either does all it says or, on failure, changes nothing.  Only
   create and attach fail for reasons of their own; any primitive fails when
   the platform cannot run it at all, such as on the wrong thread.

   Create a view of KIND from OPTIONS, detached, with its page or session
   running.  TARGET, such as "web:3", names it in the records it sends; it is
   never reused.  On failure, the platform has already released anything it
   made.  Destroying VIEW ends its page or session, wherever it is; the core
   destroys each view once, when Lisp closes it. */
bool portal_view_create(portal_kind kind, portal_string target, const portal_option *options,
                        size_t count, portal_view **view, portal_text *error);
bool portal_view_destroy(portal_view *view, portal_text *error);
/* Attach VIEW to the frame whose title is FRAME now, at RECT.  The title is
   temporary and unique (docs/adr/0002), so a platform finds the frame again on
   every call and keeps nothing that could go stale.  VIEW may be detached or
   attached to this or another frame; it moves in one step, keeping its page
   or session.  A failed attach, such as for a frame that is gone, leaves VIEW
   where it was. */
bool portal_view_attach(portal_view *view, portal_string frame, portal_rect rect,
                        portal_text *error);
/* Detach an attached VIEW, keeping its page or session and its last size.
   Where a detached view lives is the platform's business: macOS parks it in
   an offscreen window. */
bool portal_view_detach(portal_view *view, portal_text *error);
/* Describe VIEW as a JSON object of flags, integers, integer arrays and
   strings: only what the platform alone knows, such as a page's title or a
   terminal's grid.  The core adds the view's "id", "kind", "visible" and
   "edges", so the platform never reports those. */
bool portal_view_describe(portal_view *view, portal_text *state, portal_text *error);

/* Web views.  JSON is a JSON array of the messages received. */
bool portal_web_load(portal_view *web, portal_string url, portal_text *error);
bool portal_web_send(portal_view *web, portal_string json, portal_text *error);
bool portal_web_receive(portal_view *web, portal_text *json, portal_text *error);

/* Terminal views.  Apply the theme NAME, or the default theme for a null
   NAME, to the COUNT open TERMINALS; an unknown NAME changes none of them.
   NAMES is a JSON array of strings. */
bool portal_terminal_theme(const portal_string *name, portal_view *const *terminals,
                           size_t count, portal_text *error);
bool portal_terminal_themes(portal_text *names, portal_text *error);
bool portal_terminal_paste(portal_view *terminal, portal_string text, bool enter,
                           portal_text *error);
bool portal_terminal_text(portal_view *terminal, portal_text *text, portal_text *error);
bool portal_terminal_bindings(portal_string json, portal_text *error);

/* Input, for a view of any kind.  SERIAL is 0 when absent. */
bool portal_input_prefix(portal_string character, int64_t flags, portal_text *error);
bool portal_input(portal_view *view, portal_string action, int64_t serial, bool *result,
                  portal_text *error);

/* Toolbar.  STATE is a JSON object. */
bool portal_toolbar(bool enabled, portal_text *error);
bool portal_toolbar_theme(portal_string json, portal_text *error);
bool portal_toolbar_action(portal_view *view, portal_string action, portal_text *state,
                           portal_text *error);

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
   malformed, too long, with no memory to hold it while it waits, or for a
   TARGET that names no open view, before create returns or once Lisp has
   closed it.  Payloads that may be longer stay with the platform, which
   announces them here. */
bool portal_notify(portal_string type, portal_string target, const portal_string *fields,
                   size_t count);
/* A timer from portal_timer_start has fired. */
void portal_timer_fired(uint64_t token);

#endif
