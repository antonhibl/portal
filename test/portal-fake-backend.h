/* SPDX-License-Identifier: GPL-3.0-or-later */
/* What tests can do to test/portal-fake-backend.c beyond portal.h. */
#ifndef PORTAL_FAKE_BACKEND_H
#define PORTAL_FAKE_BACKEND_H

#include <stdbool.h>
#include <stddef.h>

#include "portal.h"

/* How many times the core called each view and web primitive, and some
   terminal primitives, and how many calls named a view after the core
   destroyed it, or a view of the wrong kind, which must never happen. */
struct portal_fake_calls {
    size_t created, destroyed, attached, detached, described, misused;
    size_t loaded, went, posted; /* Web pages loaded, history steps, and messages posted. */
    size_t focused, unfocused, replayed, discarded;
    size_t listed, themed, entered; /* Theme lists, themes applied, and Enters tried. */
    size_t fields; /* Find fields given the keyboard. */
};
struct portal_fake_calls portal_fake_calls(void);

/* The toolbar the core last drew for TARGET's view, valid until it draws
   again, and in *DRAWS how many times it drew; NULL before the first. */
const portal_toolbar *portal_fake_toolbar(const char *target, size_t *draws);

/* A find or a call the core asked a web view for, which a test answers as
   the platform would, with portal_web_found or portal_web_returned. */
struct portal_fake_request {
    char target[32];
    bool find;      /* A find, or else a call. */
    char text[256]; /* A find's query, after "back " when backwards; or a
                       call such as portalToolbar.count("x"). */
    uint64_t token;
};
/* Take the oldest request not taken yet into *REQUEST; false for none. */
bool portal_fake_request(struct portal_fake_request *request);

/* While REFUSE, every view, web and terminal primitive fails without doing
   anything, as a platform does when called on the wrong thread. */
void portal_fake_refuse(bool refuse);

/* End TERMINAL's process, as when its shell exits: it describes itself as
   "exited", and stays open. */
void portal_fake_exit(portal_view *terminal);

/* How many timers portal_timer_start started that have not fired. */
size_t portal_fake_timers(void);
/* Fire those timers, oldest first.  Timers they start wait for the next call. */
void portal_fake_fire_timers(void);

/* A user presses CHORD, or it repeats, in the fake's one window.  It goes to
   the view holding a trigger, if any, else the view with the keyboard, else
   Emacs, and the fake logs where it went. */
void portal_fake_press(portal_chord chord, bool repeat);
/* Run the event loop: deliver the presses the core replayed, in order. */
void portal_fake_run(void);
/* The user presses Command-Escape. */
void portal_fake_escape(void);
/* The user clicks in TARGET's view, which sends a select record and gives it
   the keyboard.  False if TARGET names no attached view. */
bool portal_fake_click(const char *target);
/* Where each press went since the last call, such as "held C-b, emacs x":
   to Emacs, a view's app, by its target, held, taken, or its trigger
   delivered as a literal.  Valid until the next call. */
const char *portal_fake_keys(void);

#endif
