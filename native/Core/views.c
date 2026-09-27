/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Portal views: every view's identity and the lifecycle bookkeeping that
   every kind shares.  A view is registered here from a successful create
   until close, and the platform view it holds is never used outside that
   span.  The platform renders views; Lisp chooses where (portal-view.el).

   The registry is a list in creation order.  Emacs has few views at once,
   so finding a target walks the list. */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "channel.h"
#include "views.h"

struct view {
    struct view *next;
    portal_view *native;
    portal_kind kind;
    uint64_t id;
    bool attached;
    portal_edges edges; /* Where it is attached, while ATTACHED. */
    size_t length;
    char target[]; /* LENGTH bytes, NUL-terminated, such as "web:3". */
};

static struct {
    struct view *first, *last; /* Open views, oldest first. */
    uint64_t ids;              /* The last ID given out. */
} views;

static const char *const kinds[] = {[PORTAL_WEB] = "web", [PORTAL_TERMINAL] = "terminal"};

static bool is(portal_string string, const char *literal)
{
    return string.length == strlen(literal) && !memcmp(string.data, literal, string.length);
}

/* Set *ERROR to MESSAGE followed by DETAIL, which may hold any bytes. */
static bool fail(portal_text *error, const char *message, portal_string detail)
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

static bool fail_with(portal_text *error, const char *message)
{
    return fail(error, message, (portal_string) {"", 0});
}

static struct view *find(portal_string target, int kind, portal_text *error)
{
    for (struct view *view = views.first; view; view = view->next)
        if (view->length == target.length && !memcmp(view->target, target.data, target.length)
            && (kind == PORTAL_ANY_KIND || (int) view->kind == kind))
            return view;
    if (error)
        fail(error, "No Portal view ", target);
    return NULL;
}

portal_view *portal_views_find(portal_string target, int kind, portal_text *error)
{
    struct view *view = find(target, kind, error);
    return view ? view->native : NULL;
}

bool portal_views_open(portal_string kind_name, const portal_option *options, size_t count,
                       portal_text *target, portal_text *error)
{
    portal_kind kind;
    if (is(kind_name, "web"))
        kind = PORTAL_WEB;
    else if (is(kind_name, "terminal"))
        kind = PORTAL_TERMINAL;
    else
        return fail(error, "Unknown Portal view kind: ", kind_name);
    /* Taken before anything can fail, so no two opens share an ID. */
    uint64_t id = ++views.ids;
    char name[32];
    size_t length = (size_t) snprintf(name, sizeof name, "%s:%" PRIu64, kinds[kind], id);
    /* Allocate all the core needs first: once the platform has a view,
       nothing but the platform can fail. */
    struct view *view = malloc(sizeof *view + length + 1);
    char *copy = malloc(length + 1);
    if (!view || !copy) {
        free(view);
        free(copy);
        return fail_with(error, "Portal is out of memory");
    }
    *view = (struct view) {.kind = kind, .id = id, .length = length};
    memcpy(view->target, name, length + 1);
    memcpy(copy, name, length + 1);
    if (!portal_view_create(kind, (portal_string) {view->target, length}, options, count,
                            &view->native, error)) {
        free(view);
        free(copy);
        return false;
    }
    if (views.last)
        views.last->next = view;
    else
        views.first = view;
    views.last = view;
    *target = (portal_text) {copy, length};
    return true;
}

/* EDGES as a rectangle, if it has positive dimensions and fits in 32 bits. */
static bool rectangle(portal_edges edges, portal_rect *rect, portal_text *error)
{
    int64_t values[] = {edges.left, edges.top, edges.right, edges.bottom};
    for (size_t i = 0; i < 4; i++)
        if (values[i] < INT32_MIN || values[i] > INT32_MAX)
            return fail_with(error, "Pane edges must fit in 32 bits");
    if (edges.right <= edges.left || edges.bottom <= edges.top)
        return fail_with(error, "Expected [LEFT TOP RIGHT BOTTOM] with positive dimensions");
    *rect = (portal_rect) {edges.left, edges.top, edges.right - edges.left,
                           edges.bottom - edges.top};
    return true;
}

bool portal_views_place(portal_string target, portal_edges edges, portal_string title,
                        portal_text *error)
{
    portal_rect rect;
    struct view *view = find(target, PORTAL_ANY_KIND, error);
    if (!view || !rectangle(edges, &rect, error))
        return false;
    /* The frame may differ even when EDGES do not, so every place attaches. */
    if (!portal_view_attach(view->native, title, rect, error))
        return false;
    view->attached = true;
    view->edges = edges;
    return true;
}

bool portal_views_hide(portal_string target, portal_text *error)
{
    struct view *view = find(target, PORTAL_ANY_KIND, error);
    if (!view)
        return false;
    if (view->attached && !portal_view_detach(view->native, error))
        return false;
    view->attached = false;
    return true;
}

bool portal_views_close(portal_string target, portal_text *error)
{
    struct view *view = find(target, PORTAL_ANY_KIND, error), *previous = NULL;
    if (!view)
        return false;
    for (struct view *other = views.first; other != view; other = other->next)
        previous = other;
    struct view **link = previous ? &previous->next : &views.first;
    *link = view->next;
    if (views.last == view)
        views.last = previous;
    if (!portal_view_destroy(view->native, error)) {
        /* Nothing changed, so the view is open where it was. */
        *link = view;
        if (!view->next)
            views.last = view;
        return false;
    }
    free(view);
    return true;
}

/* Whether C is JSON whitespace. */
static bool blank(char c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

bool portal_views_inspect(portal_string target, portal_text *state, portal_text *error)
{
    struct view *view = find(target, PORTAL_ANY_KIND, NULL);
    if (!view) {
        char *null = malloc(5);
        if (!null)
            return fail_with(error, "Portal is out of memory");
        memcpy(null, "null", 5);
        *state = (portal_text) {null, 4};
        return true;
    }
    portal_text described = {0};
    if (!portal_view_describe(view->native, &described, error))
        return false;
    /* Splice the core's properties into the platform's object: {"id":...,REST}.
       Any JSON whitespace may surround the object or fill an empty one. */
    const char *data = described.data;
    size_t start = 0, end = described.length;
    while (start < end && blank(data[start]))
        start++;
    while (end > start && blank(data[end - 1]))
        end--;
    if (end - start < 2 || data[start] != '{' || data[end - 1] != '}') {
        free(described.data);
        return fail_with(error, "The platform described a view with no JSON object");
    }
    size_t rest = start + 1; /* The object's first member, or its '}'. */
    while (blank(data[rest]))
        rest++;
    char prefix[256];
    if (view->attached)
        snprintf(prefix, sizeof prefix,
                 "{\"id\":%" PRIu64 ",\"kind\":\"%s\",\"visible\":true,"
                 "\"edges\":[%" PRId64 ",%" PRId64 ",%" PRId64 ",%" PRId64 "]",
                 view->id, kinds[view->kind], view->edges.left, view->edges.top,
                 view->edges.right, view->edges.bottom);
    else
        snprintf(prefix, sizeof prefix,
                 "{\"id\":%" PRIu64 ",\"kind\":\"%s\",\"visible\":false,\"edges\":[]", view->id,
                 kinds[view->kind]);
    bool empty = rest == end - 1;
    size_t head = strlen(prefix), total = head + (empty ? 1 : 1 + end - rest);
    char *json = malloc(total + 1);
    if (!json) {
        free(described.data);
        return fail_with(error, "Portal is out of memory");
    }
    memcpy(json, prefix, head);
    if (empty) {
        json[head] = '}';
    } else {
        json[head] = ',';
        memcpy(json + head + 1, data + rest, end - rest);
    }
    json[total] = '\0';
    free(described.data);
    *state = (portal_text) {json, total};
    return true;
}

bool portal_views_terminal_theme(const portal_string *name, portal_text *error)
{
    size_t count = 0;
    for (struct view *view = views.first; view; view = view->next)
        count += view->kind == PORTAL_TERMINAL;
    portal_view **terminals = malloc((count ? count : 1) * sizeof *terminals);
    if (!terminals)
        return fail_with(error, "Portal is out of memory");
    count = 0;
    for (struct view *view = views.first; view; view = view->next)
        if (view->kind == PORTAL_TERMINAL)
            terminals[count++] = view->native;
    bool applied = portal_terminal_theme(name, terminals, count, error);
    free(terminals);
    return applied;
}

/* A platform's late record, for a view that is gone or not yet open, would
   reach Emacs with a target no buffer has.  It never leaves the core. */
bool portal_notify(portal_string type, portal_string target, const portal_string *fields,
                   size_t count)
{
    return find(target, PORTAL_ANY_KIND, NULL)
        && portal_channel_send(type, target, fields, count);
}
