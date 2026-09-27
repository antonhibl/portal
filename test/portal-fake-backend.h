/* SPDX-License-Identifier: GPL-3.0-or-later */
/* What tests can do to test/portal-fake-backend.c beyond portal.h. */
#ifndef PORTAL_FAKE_BACKEND_H
#define PORTAL_FAKE_BACKEND_H

#include <stddef.h>

/* How many timers portal_timer_start started that have not fired. */
size_t portal_fake_timers(void);
/* Fire those timers, oldest first.  Timers they start wait for the next call. */
void portal_fake_fire_timers(void);

#endif
