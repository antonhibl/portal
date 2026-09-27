/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Helpers that the core's own files share, for portal.h's strings and errors.
   Only the core includes this header. */
#ifndef PORTAL_CORE_H
#define PORTAL_CORE_H

#include <stdlib.h>
#include <string.h>

#include "portal.h"

/* Whether STRING is LITERAL. */
static inline bool is(portal_string string, const char *literal)
{
    return string.length == strlen(literal) && !memcmp(string.data, literal, string.length);
}

/* Set *ERROR to MESSAGE followed by DETAIL, which may hold any bytes, and
   return false.  With no memory for it, leave *ERROR unset. */
static inline bool fail(portal_text *error, const char *message, portal_string detail)
{
    size_t length = strlen(message);
    char *text = malloc(length + detail.length + 1);
    if (text) {
        memcpy(text, message, length);
        if (detail.length)
            memcpy(text + length, detail.data, detail.length);
        text[length + detail.length] = '\0';
        *error = (portal_text) {text, length + detail.length};
    }
    return false;
}

static inline bool fail_with(portal_text *error, const char *message)
{
    return fail(error, message, (portal_string) {"", 0});
}

#endif
