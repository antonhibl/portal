/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Toolbars: which buttons each view's toolbar has, which of them work, what
   they show, and what a click on one does.  The platform draws each toolbar
   from the snapshot this file builds, a portal_toolbar, and reports clicks
   and the find field's text.  A click and the Lisp command that does the
   same thing run the same code on the same state.

   Ownership.  This file keeps each view's layout, its value, a zoom in
   percent or a font size in points, whether its table of contents is open,
   how many headings its page has, and its find field: the field's text, its
   matches, and the searches that find them.  It also keeps whether toolbars
   show, and their colors.  What other modules own it reads when it draws:
   who has the keyboard from input.c, and whether a page can go back or
   forward from web.c.

   Drawing.  After anything that may change what a toolbar shows, the core
   builds its snapshot, compares it with the last one it drew, and draws it
   only if they differ.  A snapshot rather than a revision number means no
   module has to count its changes, and a draw the platform refuses is
   simply tried again the next time.

   Find.  Searches run one at a time, in order, each in two steps: the
   contents script counts the query's matches in the page, then the
   platform selects the next match.  A search for another query replaces
   those waiting for the old one.  A page that finishes loading starts a new
   generation: the result of a search from an earlier one is dropped, and
   an open field searches again.  Every request to the platform carries a
   token that is never reused, so a result that no request is waiting for,
   or one for a closed view, reaches nothing.

   Showing.  A toolbar covers its pane's mode line while its view has the
   keyboard, Emacs reads a command for it, or its find field is open; the
   mode line shows otherwise, and a pane without one shows no toolbar.

   Focus.  Opening the find field gives it the keyboard.  Closing it gives
   the view's content the keyboard, but only while the view has it: by then
   the user may have moved to Emacs or another view. */
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core.h"
#include "input.h"
#include "toolbar.h"
#include "views.h"
#include "web.h"

enum layout { NONE, NAVIGATION, CONTENTS, MARKDOWN, TEXT_SIZE };

/* A web view's zoom steps, in percent. */
static const double zoom[] = {50, 67, 75, 85, 100, 110, 125, 150, 175, 200, 250, 300};
enum { ZOOM_STEPS = sizeof zoom / sizeof *zoom, STANDARD_ZOOM = 100 };
/* A terminal's font sizes, in points, a step of 1 apart. */
enum { SMALLEST_FONT = 1, LARGEST_FONT = 255 };

/* The search running on a page. */
struct search {
    portal_text query;
    bool backwards;
    bool fresh;          /* Whether its query differs from the search before. */
    uint64_t generation; /* The page's, when it started. */
    uint64_t token;      /* Of the request it waits for. */
    bool counted;        /* Whether it has its count, and waits for the find. */
    int64_t count;
};

struct portal_toolbar_state {
    portal_view *native;
    portal_string target; /* The registry's copy. */
    portal_kind kind;
    enum layout layout;
    bool edit;            /* Open in Emacs: a hosted Markdown preview's. */
    portal_text label;    /* What the view shows, as Lisp named it; "" for the default. */
    double value;
    bool contents;        /* Whether the table of contents is open. */
    int64_t headings;     /* How many the page has. */
    bool finding;         /* Whether the find field is open. */
    portal_text query;    /* The find field's text. */
    int64_t match, matches;
    /* Searches.  Those waiting share one query, and differ in direction. */
    portal_text searched; /* The query of the last search that started. */
    portal_text waiting;  /* The query of the searches waiting, */
    bool *backwards;      /* and their directions, oldest first. */
    size_t count, capacity;
    bool searching;
    struct search search;
    uint64_t generation;      /* 1 + pages loaded. */
    uint64_t contents_token;  /* The call whose result says how many headings there are. */
    /* The last snapshot drawn, if DRAWN, with its own copies of its strings. */
    bool drawn;
    portal_toolbar shown;
    portal_text shown_family, shown_label, shown_query;
};

static struct {
    bool hidden; /* Whether Lisp hid every toolbar. */
    portal_colors colors;
    portal_text family; /* The font's, and */
    double points;      /* its size, as Lisp last painted them. */
    uint64_t tokens; /* The last token given out. */
} toolbars;

static portal_string literal(const char *text)
{
    return (portal_string) {text, strlen(text)};
}

static portal_string borrow(portal_text text)
{
    return (portal_string) {text.data ? text.data : "", text.length};
}

static bool same(portal_string a, portal_string b)
{
    return a.length == b.length && (!a.length || !memcmp(a.data, b.data, a.length));
}

/* Replace *TEXT with a copy of STRING; false, leaving it, without memory. */
static bool set(portal_text *text, portal_string string)
{
    char *data = malloc(string.length + 1);
    if (!data)
        return false;
    if (string.length)
        memcpy(data, string.data, string.length);
    data[string.length] = '\0';
    free(text->data);
    *text = (portal_text) {data, string.length};
    return true;
}

/* Free the error of a primitive that nobody waits for, such as one a click
   caused.  Called on the thread the platform must use, a primitive fails
   only when that is broken. */
static void ignore(bool done, portal_text *error)
{
    if (!done)
        free(error->data);
    *error = (portal_text) {0};
}

static uint32_t bit(portal_button button)
{
    return 1u << button;
}

static bool web(const struct portal_toolbar_state *toolbar)
{
    return toolbar->layout == NAVIGATION || toolbar->layout == CONTENTS
        || toolbar->layout == MARKDOWN;
}

static bool previews(const struct portal_toolbar_state *toolbar)
{
    return toolbar->layout == CONTENTS || toolbar->layout == MARKDOWN;
}

static double standard(const struct portal_toolbar_state *toolbar)
{
    return toolbar->kind == PORTAL_TERMINAL ? PORTAL_TERMINAL_POINTS : STANDARD_ZOOM;
}

static double smallest(const struct portal_toolbar_state *toolbar)
{
    return toolbar->kind == PORTAL_TERMINAL ? SMALLEST_FONT : zoom[0];
}

static double largest(const struct portal_toolbar_state *toolbar)
{
    return toolbar->kind == PORTAL_TERMINAL ? LARGEST_FONT : zoom[ZOOM_STEPS - 1];
}

/* Drawing. */

/* Whether TOOLBAR can show: it has controls, toolbars show, and its view's
   pane has a mode line for it to cover. */
static bool room(const struct portal_toolbar_state *toolbar)
{
    return !toolbars.hidden && toolbar->layout != NONE && portal_views_mode_line(toolbar->target);
}

/* What TOOLBAR's view shows, as its toolbar says: Lisp's label where it set
   one, as a terminal's buffer name; otherwise, for a web view that is not a
   hosted app, the URL its page committed last without its scheme, so that
   following links and history needs nothing from Lisp. */
static portal_string label(const struct portal_toolbar_state *toolbar)
{
    if (toolbar->label.length)
        return borrow(toolbar->label);
    portal_string page = portal_web_views_page(toolbar->target);
    size_t scheme = 0;
    while (scheme < page.length
           && (isalnum((unsigned char) page.data[scheme]) || strchr("+-.", page.data[scheme])))
        scheme++;
    if (scheme + 2 < page.length && !memcmp(page.data + scheme, "://", 3)) {
        page.data += scheme + 3;
        page.length -= scheme + 3;
    }
    if (page.length > 1 && page.data[page.length - 1] == '/')
        page.length--;
    return page;
}

static portal_toolbar snapshot(const struct portal_toolbar_state *toolbar)
{
    portal_toolbar state = {0};
    state.owner = portal_input_owner(toolbar->target);
    /* It shows only while the view has the keyboard, or Emacs reads a
       command for it, or its find field is open: then it replaces the mode
       line, which shows Emacs has the keyboard otherwise. */
    if (!room(toolbar) || (state.owner == PORTAL_OWNER_EMACS && !toolbar->finding))
        return state;
    state.visible = true;
    state.colors = toolbars.colors;
    state.font = (portal_font) {borrow(toolbars.family), toolbars.points};
    state.label = label(toolbar);
    state.buttons = bit(PORTAL_BUTTON_OWNER);
    if (state.owner != PORTAL_OWNER_PENDING)
        state.enabled = bit(PORTAL_BUTTON_OWNER);
    state.value = toolbar->value;
    state.standard = standard(toolbar);
    state.unit = toolbar->kind == PORTAL_TERMINAL ? PORTAL_POINTS : PORTAL_PERCENT;
    state.query = borrow(toolbar->query);
    state.match = toolbar->match;
    state.matches = toolbar->matches;
    if (toolbar->finding) {
        state.finding = true;
        state.buttons |= bit(PORTAL_BUTTON_PREVIOUS) | bit(PORTAL_BUTTON_NEXT)
                       | bit(PORTAL_BUTTON_CLOSE);
        state.enabled |= bit(PORTAL_BUTTON_CLOSE);
        if (toolbar->matches)
            state.enabled |= bit(PORTAL_BUTTON_PREVIOUS) | bit(PORTAL_BUTTON_NEXT);
        return state;
    }
    state.buttons |= bit(PORTAL_BUTTON_DECREASE) | bit(PORTAL_BUTTON_RESET)
                   | bit(PORTAL_BUTTON_INCREASE);
    state.enabled |= bit(PORTAL_BUTTON_RESET);
    if (toolbar->value > smallest(toolbar))
        state.enabled |= bit(PORTAL_BUTTON_DECREASE);
    if (toolbar->value < largest(toolbar))
        state.enabled |= bit(PORTAL_BUTTON_INCREASE);
    if (!web(toolbar))
        return state;
    bool back, forward;
    portal_web_views_history(toolbar->target, &back, &forward);
    state.buttons |= bit(PORTAL_BUTTON_BACK) | bit(PORTAL_BUTTON_FORWARD)
                   | bit(PORTAL_BUTTON_FIND) | bit(PORTAL_BUTTON_RELOAD);
    state.enabled |= bit(PORTAL_BUTTON_FIND) | bit(PORTAL_BUTTON_RELOAD);
    if (back)
        state.enabled |= bit(PORTAL_BUTTON_BACK);
    if (forward)
        state.enabled |= bit(PORTAL_BUTTON_FORWARD);
    if (previews(toolbar)) {
        state.buttons |= bit(PORTAL_BUTTON_CONTENTS);
        if (toolbar->headings > 0)
            state.enabled |= bit(PORTAL_BUTTON_CONTENTS);
        if (toolbar->contents)
            state.selected |= bit(PORTAL_BUTTON_CONTENTS);
    }
    if (toolbar->edit) {
        state.buttons |= bit(PORTAL_BUTTON_EDIT);
        state.enabled |= bit(PORTAL_BUTTON_EDIT);
    }
    return state;
}

static bool same_color(portal_color a, portal_color b)
{
    return a.set == b.set
        && (!a.set || (a.red == b.red && a.green == b.green && a.blue == b.blue));
}

static bool same_colors(const portal_colors *a, const portal_colors *b)
{
    return same_color(a->background, b->background) && same_color(a->border, b->border)
        && same_color(a->shadow, b->shadow) && same_color(a->foreground, b->foreground)
        && same_color(a->success, b->success) && same_color(a->accent, b->accent)
        && same_color(a->tint, b->tint);
}

static bool same_snapshot(const portal_toolbar *a, const portal_toolbar *b)
{
    return a->visible == b->visible && same_colors(&a->colors, &b->colors)
        && same(a->font.family, b->font.family) && a->font.points == b->font.points
        && a->owner == b->owner && a->buttons == b->buttons && a->enabled == b->enabled
        && a->selected == b->selected && a->value == b->value && a->standard == b->standard
        && a->unit == b->unit && same(a->label, b->label) && a->finding == b->finding
        && same(a->query, b->query)
        && a->match == b->match && a->matches == b->matches;
}

/* Draw TOOLBAR if it shows anything new. */
static void refresh(struct portal_toolbar_state *toolbar)
{
    if (!toolbar->native)
        return; /* Not open yet. */
    portal_toolbar state = snapshot(toolbar);
    if (toolbar->drawn && same_snapshot(&state, &toolbar->shown))
        return;
    portal_text family = {0}, label = {0}, query = {0}, error = {0};
    if (!set(&family, state.font.family) || !set(&label, state.label)
        || !set(&query, state.query)) {
        free(family.data);
        free(label.data);
        return; /* Without memory to remember it, draw it next time. */
    }
    if (!portal_toolbar_draw(toolbar->native, &state, &error)) {
        ignore(false, &error);
        free(family.data);
        free(label.data);
        free(query.data);
        return;
    }
    free(toolbar->shown_family.data);
    free(toolbar->shown_label.data);
    free(toolbar->shown_query.data);
    toolbar->shown_family = family;
    toolbar->shown_label = label;
    toolbar->shown_query = query;
    toolbar->shown = state;
    toolbar->shown.font.family = borrow(family);
    toolbar->shown.label = borrow(label);
    toolbar->shown.query = borrow(query);
    toolbar->drawn = true;
}

void portal_toolbar_refresh(portal_string target)
{
    struct portal_toolbar_state *toolbar = portal_views_toolbar(target);
    if (toolbar)
        refresh(toolbar);
}

static void refresh_each(struct portal_toolbar_state *toolbar)
{
    refresh(toolbar);
}

/* Find. */

/* Call FUNCTION of the contents script with ARGUMENT, a JSON value, and
   TOKEN. */
static bool call(struct portal_toolbar_state *toolbar, const char *function,
                 portal_string argument, uint64_t token, portal_text *error)
{
    return portal_web_call(toolbar->native, PORTAL_SCRIPT_CONTENTS, literal(function), argument,
                           token, error);
}

/* Show or hide the table of contents as TOOLBAR says, with TOKEN. */
static bool show_contents(struct portal_toolbar_state *toolbar, uint64_t token,
                          portal_text *error)
{
    return call(toolbar, "portalToolbar.toc", literal(toolbar->contents ? "true" : "false"),
                token, error);
}

static void start(struct portal_toolbar_state *toolbar);

/* The running search is over: start the next. */
static void finish(struct portal_toolbar_state *toolbar)
{
    toolbar->searching = false;
    free(toolbar->search.query.data);
    toolbar->search = (struct search) {0};
    start(toolbar);
}

/* Start the oldest waiting search, unless one is running. */
static void start(struct portal_toolbar_state *toolbar)
{
    while (!toolbar->searching && toolbar->count) {
        struct search search = {.backwards = toolbar->backwards[0],
                                .generation = toolbar->generation};
        memmove(toolbar->backwards, toolbar->backwards + 1,
                --toolbar->count * sizeof *toolbar->backwards);
        struct json argument = {0};
        put_string(&argument, borrow(toolbar->waiting));
        if (argument.failed || !set(&search.query, borrow(toolbar->waiting))) {
            free(argument.data);
            continue; /* Without memory, the search is lost. */
        }
        search.fresh = !same(borrow(search.query), borrow(toolbar->searched));
        if (!set(&toolbar->searched, borrow(search.query)))
            toolbar->searched.length = 0; /* The next search is fresh. */
        search.token = ++toolbars.tokens;
        toolbar->search = search;
        toolbar->searching = true;
        portal_text error = {0};
        bool called = call(toolbar, "portalToolbar.count",
                           (portal_string) {argument.data, argument.length}, search.token, &error);
        free(argument.data);
        if (!called) {
            ignore(false, &error);
            toolbar->searching = false;
            free(toolbar->search.query.data);
            toolbar->search = (struct search) {0};
        }
    }
}

/* Search for QUERY, after the searches waiting, unless they are for another
   query: then instead of them. */
static void search(struct portal_toolbar_state *toolbar, portal_string query, bool backwards)
{
    if (!same(query, borrow(toolbar->waiting))) {
        toolbar->count = 0;
        if (!set(&toolbar->waiting, query))
            return;
    }
    if (toolbar->count == toolbar->capacity) {
        size_t capacity = toolbar->capacity ? 2 * toolbar->capacity : 4;
        bool *grown = realloc(toolbar->backwards, capacity * sizeof *grown);
        if (!grown)
            return;
        toolbar->backwards = grown;
        toolbar->capacity = capacity;
    }
    toolbar->backwards[toolbar->count++] = backwards;
    start(toolbar);
}

void portal_web_returned(portal_string target, uint64_t token, bool ok, int64_t value)
{
    struct portal_toolbar_state *toolbar = portal_views_toolbar(target);
    if (!toolbar || !token)
        return;
    if (token == toolbar->contents_token) {
        toolbar->contents_token = 0;
        if (ok)
            toolbar->headings = value;
        refresh(toolbar);
        return;
    }
    struct search *search = &toolbar->search;
    if (!toolbar->searching || token != search->token || search->counted)
        return;
    if (search->generation != toolbar->generation) {
        finish(toolbar);
        return;
    }
    search->count = ok ? value : 0;
    search->counted = true;
    search->token = ++toolbars.tokens;
    portal_text error = {0};
    if (!portal_web_find(toolbar->native, borrow(search->query), search->backwards, search->token,
                         &error)) {
        ignore(false, &error);
        finish(toolbar);
    }
}

void portal_web_found(portal_string target, uint64_t token, bool found)
{
    struct portal_toolbar_state *toolbar = portal_views_toolbar(target);
    struct search *search = toolbar ? &toolbar->search : NULL;
    if (!toolbar || !toolbar->searching || !token || token != search->token || !search->counted)
        return;
    if (search->generation == toolbar->generation) {
        int64_t matches = !search->query.length || !found ? 0
                        : search->count > 1                ? search->count
                                                           : 1;
        if (!matches)
            toolbar->match = 0;
        else if (search->fresh)
            toolbar->match = search->backwards ? matches : 1;
        else
            toolbar->match = (toolbar->match - 1 + (search->backwards ? -1 : 1) + matches)
                               % matches
                           + 1;
        toolbar->matches = matches;
    }
    finish(toolbar);
    refresh(toolbar);
}

void portal_web_loaded(portal_string target)
{
    struct portal_toolbar_state *toolbar = portal_views_toolbar(target);
    if (!toolbar)
        return;
    toolbar->generation++;
    toolbar->count = 0;
    toolbar->searched.length = 0;
    toolbar->match = toolbar->matches = 0;
    if (previews(toolbar)) {
        portal_text error = {0};
        toolbar->contents_token = ++toolbars.tokens;
        if (!show_contents(toolbar, toolbar->contents_token, &error)) {
            ignore(false, &error);
            toolbar->contents_token = 0;
        }
    }
    if (toolbar->finding)
        search(toolbar, borrow(toolbar->query), false);
    refresh(toolbar);
}

void portal_web_headings(portal_string target, int64_t count)
{
    struct portal_toolbar_state *toolbar = portal_views_toolbar(target);
    if (!toolbar)
        return;
    toolbar->headings = count;
    refresh(toolbar);
}

void portal_toolbar_committed(portal_string target)
{
    portal_web_headings(target, 0);
}

/* Actions, for clicks, shortcuts and Lisp. */

static bool open_find(struct portal_toolbar_state *toolbar, portal_text *error)
{
    if (!web(toolbar) || !room(toolbar))
        return fail_with(error, "Find needs a visible web toolbar");
    bool opening = !toolbar->finding;
    toolbar->finding = true;
    refresh(toolbar); /* The field is there before it takes the keyboard. */
    if (!portal_toolbar_focus(toolbar->native, error))
        return false;
    if (opening && toolbar->query.length)
        search(toolbar, borrow(toolbar->query), false);
    return true;
}

static bool close_find(struct portal_toolbar_state *toolbar, portal_text *error)
{
    if (!toolbar->finding)
        return true;
    toolbar->finding = false;
    search(toolbar, literal(""), false); /* Which clears the selected match. */
    struct portal_input *input = portal_views_input(toolbar->target);
    return !input || !input->focused || portal_view_focus(toolbar->native, error);
}

static bool toggle_contents(struct portal_toolbar_state *toolbar, portal_text *error)
{
    if (!previews(toolbar) || toolbar->headings <= 0)
        return fail_with(error, "This preview has no headings");
    toolbar->contents = !toolbar->contents;
    if (show_contents(toolbar, ++toolbars.tokens, error))
        return true;
    toolbar->contents = !toolbar->contents;
    return false;
}

/* Change the value as BUTTON, DECREASE, RESET or INCREASE, says. */
static bool change(struct portal_toolbar_state *toolbar, portal_button button, portal_text *error)
{
    double value = toolbar->value, next = standard(toolbar);
    if (toolbar->kind == PORTAL_TERMINAL) {
        if (button == PORTAL_BUTTON_INCREASE)
            next = value + 1 < LARGEST_FONT ? value + 1 : LARGEST_FONT;
        else if (button == PORTAL_BUTTON_DECREASE)
            next = value - 1 > SMALLEST_FONT ? value - 1 : SMALLEST_FONT;
    } else if (button == PORTAL_BUTTON_INCREASE) {
        next = zoom[ZOOM_STEPS - 1];
        for (size_t i = ZOOM_STEPS; i-- > 0;)
            if (zoom[i] > value)
                next = zoom[i];
    } else if (button == PORTAL_BUTTON_DECREASE) {
        next = zoom[0];
        for (size_t i = 0; i < ZOOM_STEPS; i++)
            if (zoom[i] < value)
                next = zoom[i];
    }
    if (next == value)
        return true;
    bool changed = toolbar->kind == PORTAL_TERMINAL
        ? portal_terminal_set_font_size(toolbar->native, next, error)
        : portal_web_zoom(toolbar->native, next / 100, error);
    if (changed)
        toolbar->value = next;
    return changed;
}

/* Move the keyboard, as the dot shows it, to Emacs or the view: the same as
   the platform's way back to Emacs, or a click in the view. */
static bool own(struct portal_toolbar_state *toolbar, portal_text *error)
{
    switch (portal_input_owner(toolbar->target)) {
    case PORTAL_OWNER_PENDING:
        return true; /* Emacs is reading a command, and has the prompt. */
    case PORTAL_OWNER_EMACS:
        return portal_view_focus(toolbar->native, error);
    case PORTAL_OWNER_VIEW:
        break;
    }
    portal_input_escape(toolbar->target);
    return true;
}

static bool act(struct portal_toolbar_state *toolbar, portal_button button, portal_text *error)
{
    switch (button) {
    case PORTAL_BUTTON_OWNER:
        return own(toolbar, error);
    case PORTAL_BUTTON_BACK:
        return portal_web_go(toolbar->native, PORTAL_BACK, error);
    case PORTAL_BUTTON_FORWARD:
        return portal_web_go(toolbar->native, PORTAL_FORWARD, error);
    case PORTAL_BUTTON_RELOAD:
        return portal_web_go(toolbar->native, PORTAL_RELOAD, error);
    case PORTAL_BUTTON_FIND:
        return open_find(toolbar, error);
    case PORTAL_BUTTON_CONTENTS:
        return toggle_contents(toolbar, error);
    case PORTAL_BUTTON_EDIT:
        portal_web_views_edit(toolbar->target);
        return true;
    case PORTAL_BUTTON_DECREASE:
    case PORTAL_BUTTON_RESET:
    case PORTAL_BUTTON_INCREASE:
        return change(toolbar, button, error);
    case PORTAL_BUTTON_PREVIOUS:
    case PORTAL_BUTTON_NEXT:
        search(toolbar, borrow(toolbar->query), button == PORTAL_BUTTON_PREVIOUS);
        return true;
    case PORTAL_BUTTON_CLOSE:
        return close_find(toolbar, error);
    }
    return true;
}

/* The platform's calls, from portal.h. */

void portal_toolbar_clicked(portal_string target, portal_button button)
{
    struct portal_toolbar_state *toolbar = portal_views_toolbar(target);
    if (!toolbar || !toolbar->drawn || (unsigned) button >= 32
        || !(toolbar->shown.buttons & bit(button)))
        return;
    portal_text error = {0};
    ignore(act(toolbar, button, &error), &error);
    refresh(toolbar);
}

void portal_toolbar_typed(portal_string target, portal_string query)
{
    struct portal_toolbar_state *toolbar = portal_views_toolbar(target);
    if (!toolbar || !toolbar->finding || !set(&toolbar->query, query))
        return;
    search(toolbar, query, false);
    refresh(toolbar);
}

/* For input.c. */

bool portal_toolbar_shortcut(portal_string target, portal_chord key)
{
    struct portal_toolbar_state *toolbar = portal_views_toolbar(target);
    if (!toolbar || key.modifiers != PORTAL_SUPER)
        return false;
    portal_button button;
    if (toolbar->kind == PORTAL_TERMINAL && (key.character == '=' || key.character == '+'))
        button = PORTAL_BUTTON_INCREASE;
    else if (toolbar->kind == PORTAL_TERMINAL && key.character == '-')
        button = PORTAL_BUTTON_DECREASE;
    else if (toolbar->kind == PORTAL_TERMINAL && key.character == '0')
        button = PORTAL_BUTTON_RESET;
    else if (key.character == 'f' && web(toolbar) && room(toolbar)
             && portal_input_owner(target) == PORTAL_OWNER_VIEW)
        button = PORTAL_BUTTON_FIND;
    else if (key.character == 'r' && web(toolbar) && portal_input_owner(target) == PORTAL_OWNER_VIEW)
        button = PORTAL_BUTTON_RELOAD;
    else
        return false;
    portal_text error = {0};
    ignore(act(toolbar, button, &error), &error);
    refresh(toolbar);
    return true;
}

/* Lifetime, for views.c. */

struct portal_toolbar_state *portal_toolbar_state_new(portal_kind kind,
                                                      const portal_option *options,
                                                      size_t count, bool hosted,
                                                      portal_text *error)
{
    enum layout layout = kind == PORTAL_TERMINAL ? TEXT_SIZE : NONE;
    for (size_t i = 0; i < count; i++) {
        const portal_option *option = &options[i];
        if (kind == PORTAL_TERMINAL && is(option->name, "quick"))
            layout = option->is_string || option->flag ? NONE : TEXT_SIZE;
        if (kind != PORTAL_WEB || !is(option->name, "toolbar"))
            continue;
        if (!option->is_string && !option->flag)
            layout = NONE;
        else if (option->is_string && is(option->string, "navigation"))
            layout = NAVIGATION;
        else if (option->is_string && is(option->string, "contents"))
            layout = CONTENTS;
        else if (option->is_string && is(option->string, "markdown"))
            layout = MARKDOWN;
        else if (option->is_string && is(option->string, "none"))
            layout = NONE;
        else {
            fail_with(error, "A web view's :toolbar must be \"navigation\", \"contents\", "
                             "\"markdown\" or \"none\"");
            return NULL;
        }
    }
    struct portal_toolbar_state *toolbar = calloc(1, sizeof *toolbar);
    if (!toolbar) {
        fail_with(error, "Portal is out of memory");
        return NULL;
    }
    toolbar->kind = kind;
    toolbar->layout = layout;
    toolbar->edit = layout == MARKDOWN && hosted;
    toolbar->value = standard(toolbar);
    toolbar->generation = 1;
    return toolbar;
}

void portal_toolbar_open(struct portal_toolbar_state *toolbar, portal_view *native,
                         portal_string target)
{
    toolbar->native = native;
    toolbar->target = target;
    refresh(toolbar);
}

void portal_toolbar_state_free(struct portal_toolbar_state *toolbar)
{
    if (!toolbar)
        return;
    free(toolbar->label.data);
    free(toolbar->query.data);
    free(toolbar->searched.data);
    free(toolbar->waiting.data);
    free(toolbar->backwards);
    free(toolbar->search.query.data);
    free(toolbar->shown_family.data);
    free(toolbar->shown_label.data);
    free(toolbar->shown_query.data);
    free(toolbar);
}

/* The Lisp functions, for emacs.c. */

static void close_each(struct portal_toolbar_state *toolbar)
{
    portal_text error = {0};
    ignore(close_find(toolbar, &error), &error);
}

void portal_toolbar_show(bool shown)
{
    toolbars.hidden = !shown;
    if (!shown)
        portal_views_each_toolbar(close_each);
    portal_views_each_toolbar(refresh_each);
}

void portal_toolbar_paint(const portal_colors *colors, portal_font font)
{
    toolbars.colors = *colors;
    if (set(&toolbars.family, font.family))
        toolbars.points = font.points;
    portal_views_each_toolbar(refresh_each);
}

bool portal_toolbar_label(portal_string target, portal_string label, portal_text *error)
{
    if (!portal_views_find(target, PORTAL_ANY_KIND, error))
        return false;
    struct portal_toolbar_state *toolbar = portal_views_toolbar(target);
    if (same(label, borrow(toolbar->label)))
        return true;
    if (!set(&toolbar->label, label))
        return fail_with(error, "Portal is out of memory");
    refresh(toolbar);
    return true;
}

static const struct {
    const char *name;
    portal_button button;
    bool web; /* A web view's only. */
} actions[] = {
    {"increase", PORTAL_BUTTON_INCREASE, false}, {"decrease", PORTAL_BUTTON_DECREASE, false},
    {"reset", PORTAL_BUTTON_RESET, false},       {"find", PORTAL_BUTTON_FIND, false},
    {"close-find", PORTAL_BUTTON_CLOSE, false},  {"back", PORTAL_BUTTON_BACK, true},
    {"forward", PORTAL_BUTTON_FORWARD, true},    {"reload", PORTAL_BUTTON_RELOAD, true},
    {"toc", PORTAL_BUTTON_CONTENTS, true},
};

static void put_member(struct json *json, const char *name, const char *value)
{
    put(json, json->length > 1 ? ",\"" : "\"", json->length > 1 ? 2 : 1);
    put(json, name, strlen(name));
    put(json, "\":", 2);
    put(json, value, strlen(value));
}

static const char *flag(bool value)
{
    return value ? "true" : "false";
}

/* TOOLBAR's state as portal--toolbar-action returns it, a JSON object with
   its members sorted. */
static bool describe(const struct portal_toolbar_state *toolbar, portal_text *state,
                     portal_text *error)
{
    bool back, forward;
    portal_web_views_history(toolbar->target, &back, &forward);
    char number[3][32];
    snprintf(number[0], sizeof number[0], "%lld", (long long) toolbar->match);
    snprintf(number[1], sizeof number[1], "%lld", (long long) toolbar->matches);
    snprintf(number[2], sizeof number[2], "%g", toolbar->value);
    struct json json = {0};
    put(&json, "{", 1);
    put_member(&json, "back", flag(back));
    put_member(&json, "find", flag(toolbar->finding));
    put_member(&json, "forward", flag(forward));
    put_member(&json, "headings", flag(toolbar->headings > 0));
    put_member(&json, "match", number[0]);
    put_member(&json, "matches", number[1]);
    put(&json, ",\"query\":", 9);
    put_string(&json, borrow(toolbar->query));
    put_member(&json, "toc", flag(toolbar->contents));
    put_member(&json, "value", number[2]);
    put(&json, "}", 1);
    if (json.failed) {
        free(json.data);
        return fail_with(error, "Portal is out of memory");
    }
    *state = (portal_text) {json.data, json.length};
    return true;
}

bool portal_toolbar_perform(portal_string target, portal_string action, portal_text *state,
                            portal_text *error)
{
    if (!portal_views_find(target, PORTAL_ANY_KIND, error))
        return false;
    struct portal_toolbar_state *toolbar = portal_views_toolbar(target);
    if (toolbar->layout == NONE)
        return fail_with(error, "No toolbar controls for this native view");
    if (!is(action, "state")) {
        bool terminal = toolbar->kind == PORTAL_TERMINAL;
        size_t i = 0;
        while (i < sizeof actions / sizeof *actions
               && !(is(action, actions[i].name) && !(terminal && actions[i].web)))
            i++;
        if (i == sizeof actions / sizeof *actions)
            return fail(error,
                        terminal ? "Unknown terminal toolbar action: "
                                 : "Unknown web toolbar action: ",
                        action);
        bool done = act(toolbar, actions[i].button, error);
        refresh(toolbar);
        if (!done)
            return false;
    }
    return describe(toolbar, state, error);
}
