/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Toolbars, as the Emacs bindings and the rest of the core use them.
   toolbar.c implements these and, for the platform, the toolbar calls into
   the core in portal.h, and the web calls about a toolbar's page:
   portal_web_loaded, portal_web_found, portal_web_returned and
   portal_web_headings.  Only the core, tests and the standalone checks
   include this header.

   A view's toolbar has one of these layouts, fixed when it opens: a web
   view's :toolbar, "navigation", "contents" or "markdown", or none for
   "none" or nil; a terminal's text size, or none for a quick terminal. */
#ifndef PORTAL_TOOLBAR_H
#define PORTAL_TOOLBAR_H

#include "portal.h"

/* The Lisp functions, for emacs.c. */

/* Show every view's toolbar, or none, as portal--toolbar does.  Hiding
   them closes every find field.  Toolbars show until Lisp says. */
void portal_toolbar_show(bool shown);
/* Draw every toolbar in COLORS, as portal--toolbar-theme does. */
void portal_toolbar_paint(const portal_colors *colors);
/* Perform ACTION on TARGET's toolbar, as a click would, and set *STATE to
   the toolbar's state as a JSON object, as portal--toolbar-action does.
   ACTION is "state", which changes nothing; "increase", "decrease" or
   "reset"; "find" or "close-find"; or, for a web view, "back", "forward",
   "reload" or "toc".  A view without a toolbar has no actions. */
bool portal_toolbar_perform(portal_string target, portal_string action, portal_text *state,
                            portal_text *error);

/* For views.c: what the core keeps for one view's toolbar. */
struct portal_toolbar_state;

/* The toolbar of a new view of KIND opened with OPTIONS, a hosted app's if
   HOSTED; or NULL, with *ERROR set, for an invalid :toolbar or no memory. */
struct portal_toolbar_state *portal_toolbar_state_new(portal_kind kind,
                                                      const portal_option *options,
                                                      size_t count, bool hosted,
                                                      portal_text *error);
/* The platform has created TOOLBAR's view as NATIVE, which the registry
   names TARGET: draw its first toolbar. */
void portal_toolbar_open(struct portal_toolbar_state *toolbar, portal_view *native,
                         portal_string target);
/* Free TOOLBAR, once its view is destroyed. */
void portal_toolbar_state_free(struct portal_toolbar_state *toolbar);

/* For toolbar.c, from views.c: TARGET's toolbar, if TARGET names an open
   view; and each open view's toolbar in turn, oldest first. */
struct portal_toolbar_state *portal_views_toolbar(portal_string target);
/* For toolbar.c, from views.c: whether TARGET's view is attached in a pane
   with a mode line, where its toolbar shows. */
bool portal_views_mode_line(portal_string target);
void portal_views_each_toolbar(void (*visit)(struct portal_toolbar_state *toolbar));

/* For input.c and web.c: draw TARGET's toolbar again if anything it shows
   has changed.  A TARGET that names no open view does nothing. */
void portal_toolbar_refresh(portal_string target);
/* For input.c: whether KEY, a normalized chord that the app of TARGET's
   view did not use while the view has the keyboard, is a toolbar's
   shortcut, which the core has acted on.  A terminal's Super-= or Super-+,
   Super-- and Super-0 change its text size, with or without a toolbar;
   Super-f opens the find field of a web view's toolbar that shows, and
   Super-r reloads a web view whose toolbar has Reload, even while toolbars
   are hidden. */
bool portal_toolbar_shortcut(portal_string target, portal_chord key);
/* For web.c: web view TARGET committed a page, which has shown no headings
   yet. */
void portal_toolbar_committed(portal_string target);

#endif
