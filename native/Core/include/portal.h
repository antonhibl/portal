/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The platform interface of Portal's Emacs module.

   The C core in native/Core is the module's portable part.  emacs.c
   registers the Lisp interface (docs/adr/0002), converts arguments and
   results, and signals errors.  views.c owns every Portal view's identity
   and lifecycle, input.c decides who gets each key press, terminals.c keeps
   the rules of terminal views, and channel.c owns the pipe that carries
   records to Emacs.
   The platform implements the operations below: the production module links
   the macOS backend, native/Backend.swift, and the core's tests link
   test/portal-fake-backend.c.  Nothing here knows about Emacs values or a UI
   toolkit.

   These operations are becoming the primitives of docs/adr/0003.  The view
   lifecycle, input and terminal operations already are; the web and toolbar
   operations still mirror their Lisp functions, until their rules move into
   the core.

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

/* Terminal views.  The core implements the terminal Lisp functions with
   these primitives, each on one terminal, and keeps Portal's rules: it checks
   a terminal's options before creating it, and a theme's name against
   portal_terminal_list_themes before applying it to any terminal.  A
   terminal's options, passed to portal_view_create, are :directory, the
   working directory, a string; :command, a shell command line to run instead
   of the login shell, a string or false; :argv, a JSON array containing an
   absolute program path and literal arguments, a string or false, mutually
   exclusive with :command; :environment, a JSON object of exported
   environment overrides (string values, or null to remove a variable), a
   string or false, with removals requiring :argv; :theme, a name the
   platform lists, or false for the default; and :quick, a flag.

   A terminal describes itself with "ready", whether its engine can draw and
   take input; "title", which the running program may set; "columns" and
   "rows", its grid, 0 until known; and "exited", whether its process has
   ended.  A process that exits leaves its view open, showing its last
   output, until Lisp closes it; destroying a view ends its process.  Any
   other fact a platform describes, such as macOS's "layer", the class of the
   renderer's layer, is a diagnostic for tests.

   List the names of the themes the terminal engine offers, in any order:
   *NAMES is an array of *COUNT texts, allocated with malloc like each text,
   and the core frees them all. */
bool portal_terminal_list_themes(portal_text **names, size_t *count, portal_text *error);
/* Apply the theme NAME, which the platform listed, or the default theme for a
   null NAME, to TERMINAL.  The default may follow the system's appearance. */
bool portal_terminal_apply_theme(portal_view *terminal, const portal_string *name,
                                 portal_text *error);
/* Paste TEXT as the user's paste, bracketed if the running program asked. */
bool portal_terminal_paste_text(portal_view *terminal, portal_string text, portal_text *error);
/* Press and release the Enter key. */
bool portal_terminal_press_enter(portal_view *terminal, portal_text *error);
/* Read all of TERMINAL's text, its scrollback and screen.  macOS reads it by
   selecting everything, and leaves that selection active. */
bool portal_terminal_read_text(portal_view *terminal, portal_text *text, portal_text *error);
/* Set TERMINAL's font size to POINTS, which is positive. */
bool portal_terminal_set_font_size(portal_view *terminal, double points, portal_text *error);

/* Input, for a view of any kind.  The core decides what each key press in a
   view does: the view's app gets it, or it starts a handoff, in which Emacs
   reads and runs a command (docs/terminal-input-bridge.md).  The platform
   captures keys, moves the keyboard, and keeps the native events: the core
   sees only portal_chord values, never replays them.

   Give VIEW the keyboard, if it is attached; or, if VIEW has the keyboard,
   return it to Emacs.  Either reports what changed with portal_input_focus
   before it returns, so the core knows the result. */
bool portal_view_focus(portal_view *view, portal_text *error);
bool portal_view_unfocus(portal_view *view, portal_text *error);
/* The key events VIEW holds, from a press the core answered
   PORTAL_KEY_HOLD (below): that press, its trigger, and the events after it.
   With REPLAY, deliver the events after the trigger again, in order, ahead
   of any new ones, as if they had just happened, and stop holding them; VIEW
   keeps its trigger.  Without, discard them all, trigger included.  Holding
   nothing, either does nothing. */
bool portal_view_replay(portal_view *view, bool replay, portal_text *error);
/* Deliver VIEW's trigger to the app, as a real press and release of that
   key where VIEW's keyboard input goes.  The core gives VIEW the keyboard
   first.  Fails if VIEW holds no trigger. */
bool portal_view_literal(portal_view *view, portal_text *error);

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

/* Modifier keys, as Emacs names them.  Which keys are Meta and Super is the
   platform's business: on macOS, Option and Command. */
typedef enum portal_modifier {
    PORTAL_SHIFT = 1 << 0,
    PORTAL_CONTROL = 1 << 1,
    PORTAL_META = 1 << 2,
    PORTAL_SUPER = 1 << 3,
} portal_modifier;

/* A key press: CHARACTER, the Unicode code point the key types with Shift
   but no other modifier, such as 'b' for Control-B and '!' for Shift-1 on a
   US layout, or 0 for a key that types no single character; and the
   portal_modifier bits held.  The core ignores other bits, case, and Shift
   on a character Shift already made. */
typedef struct portal_chord {
    uint32_t character;
    uint32_t modifiers;
} portal_chord;

/* What the platform does with a key press.  PASS: deliver it as it would
   without Portal.  TAKE: drop it.  HOLD: keep it as the view's trigger, and
   hold every key event after it in the view's window, in order, presses,
   repeats, releases and modifier changes alike, without asking the core,
   until portal_view_replay.  While a view holds a trigger, the key events in
   its window are its own, whichever view has the keyboard: the platform asks
   the core about each press there. */
typedef enum portal_key { PORTAL_KEY_PASS, PORTAL_KEY_TAKE, PORTAL_KEY_HOLD } portal_key;

/* CHORD was pressed, or REPEAT-ed, in TARGET's view: the view has the
   keyboard, or holds a trigger in the window where the key was pressed.
   Press and repeat only: a release or a modifier change never needs the
   core. */
portal_key portal_input_key(portal_string target, portal_chord chord, bool repeat);

/* TARGET's view gained or lost the keyboard.  Report each change, whatever
   made it; one the platform makes for the core, before that call returns.
   Report the user moving the keyboard too, before anything changes: a click
   that will give the view the keyboard, and the platform's own way back to
   Emacs, Command-Escape on macOS, which returns the keyboard without asking
   the core, even when the view does not have it.  A report that neither
   Emacs nor the core caused abandons the view's handoff. */
void portal_input_focus(portal_string target, bool focused);

/* Who has TARGET's keyboard, for a toolbar to show until the toolbar's state
   moves into the core: Emacs, the view, Emacs handling the view's handoff, or
   the view in passthrough, which gives its app every key. */
typedef enum portal_owner {
    PORTAL_OWNER_EMACS,
    PORTAL_OWNER_VIEW,
    PORTAL_OWNER_PENDING,
    PORTAL_OWNER_PASSTHROUGH,
} portal_owner;
portal_owner portal_input_owner(portal_string target);

#endif
