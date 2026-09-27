/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The notification pipe, as the Emacs bindings connect it.  channel.c
   implements these and, for the platform, portal_notify and
   portal_timer_fired from portal.h.  Only emacs.c and tests include this
   header: the platform sends records but never connects the pipe. */
#ifndef PORTAL_CHANNEL_H
#define PORTAL_CHANNEL_H

#include <stdbool.h>
#include <sys/types.h>

/* Send records to FD, the write end of Emacs's record pipe, or keep them
   waiting while FD is -1.  Records already waiting go to FD first, in order.
   On success the core owns FD, closes the descriptor it had unless that is
   FD, and cancels any pending retry.  On failure errno says why and nothing
   changes: FD stays the caller's and the old pipe stays connected. */
bool portal_channel_connect(int fd);

/* How the channel writes: write(2), unless a test replaces it to produce what
   a real pipe cannot on demand, such as EINTR or a short write. */
extern ssize_t (*portal_channel_write)(int fd, const void *bytes, size_t length);

#endif
