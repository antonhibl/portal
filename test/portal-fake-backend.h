/* SPDX-License-Identifier: GPL-3.0-or-later */
/* What tests can do to test/portal-fake-backend.c beyond portal.h. */
#ifndef PORTAL_FAKE_BACKEND_H
#define PORTAL_FAKE_BACKEND_H

#include <stdbool.h>
#include <stddef.h>

#include "portal.h"

/* How many times the core called each view primitive, and how many calls
   named a view after the core destroyed it, or a view of the wrong kind,
   which must never happen. */
struct portal_fake_calls {
    size_t created, destroyed, attached, detached, described, misused;
    size_t focused, unfocused, replayed, discarded;
};
struct portal_fake_calls portal_fake_calls(void);

/* While REFUSE, every view primitive fails without doing anything, as a
   platform does when called on the wrong thread. */
void portal_fake_refuse(bool refuse);

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
