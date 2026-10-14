/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Toolbars, native/Core/toolbar.c, with the fake platform.  The tests call
   the core as emacs.c does for Lisp, and as a platform does: clicks, the
   find field's text, key presses, and the answers to finds and script
   calls, which the fake keeps until a test gives them.  They read what the
   core drew from the fake. */
#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <unistd.h>

#include "channel.h"
#include "input.h"
#include "portal-core-tests.h"
#include "toolbar.h"
#include "web.h"

static int records = -1; /* The pipe's read end. */

static const char *drain(void)
{
    static char buffer[8192];
    ssize_t count = read(records, buffer, sizeof buffer - 1);
    buffer[count > 0 ? count : 0] = '\0';
    return buffer;
}

static bool same(portal_string a, portal_string b)
{
    return a.length == b.length && !memcmp(a.data, b.data, a.length);
}

static uint32_t bits(int count, ...)
{
    uint32_t mask = 0;
    va_list arguments;
    va_start(arguments, count);
    for (int i = 0; i < count; i++)
        mask |= 1u << va_arg(arguments, int);
    va_end(arguments);
    return mask;
}

enum {
    OWNER = PORTAL_BUTTON_OWNER,
    BACK = PORTAL_BUTTON_BACK,
    FORWARD = PORTAL_BUTTON_FORWARD,
    FIND = PORTAL_BUTTON_FIND,
    CONTENTS = PORTAL_BUTTON_CONTENTS,
    EDIT = PORTAL_BUTTON_EDIT,
    DECREASE = PORTAL_BUTTON_DECREASE,
    RESET = PORTAL_BUTTON_RESET,
    INCREASE = PORTAL_BUTTON_INCREASE,
    RELOAD = PORTAL_BUTTON_RELOAD,
    PREVIOUS = PORTAL_BUTTON_PREVIOUS,
    NEXT = PORTAL_BUTTON_NEXT,
    CLOSE = PORTAL_BUTTON_CLOSE,
};

/* The toolbar the core last drew for TARGET, which it must have drawn. */
static portal_toolbar drawn(const char *target)
{
    size_t draws;
    const portal_toolbar *toolbar = portal_fake_toolbar(target, &draws);
    CHECK(toolbar != NULL);
    return toolbar ? *toolbar : (portal_toolbar) {0};
}

static size_t draws(const char *target)
{
    size_t count;
    portal_fake_toolbar(target, &count);
    return count;
}

/* A web view with the toolbar LAYOUT, hosted if HOSTED. */
static char *open_web(const char *layout, bool hosted)
{
    portal_text error = {0};
    char *target = hosted ? open_view("web", &error, "toolbar", layout, "hosted", "t", NULL)
                          : open_view("web", &error, "toolbar", layout, NULL);
    CHECK(target != NULL);
    return target;
}

static char *open_terminal(bool quick)
{
    portal_text error = {0};
    char *target = quick ? open_view("terminal", &error, "directory", "/", "quick", "t", NULL)
                         : open_view("terminal", &error, "directory", "/", NULL);
    CHECK(target != NULL);
    return target;
}

/* The mode line below a 640 by 480 pane, which a toolbar covers. */
static const portal_edges bar = {0, 480, 640, 506};

/* Attach TARGET above its mode line, as Emacs does, in FRAME. */
static void place(const char *target, const char *frame)
{
    portal_text error = {0};
    CHECK(portal_views_place(text(target), (portal_edges) {0, 0, 640, 480}, &bar, text(frame),
                             &error));
}

/* Attach TARGET and give it the keyboard, as Emacs does. */
static void enter(const char *target)
{
    portal_text error = {0};
    bool focused = false;
    place(target, "frame");
    CHECK(portal_input_perform(text(target), text("focus"), 0, &focused, &error) && focused);
}

/* Perform ACTION on TARGET as portal--toolbar-action does; return its JSON,
   to free, or NULL with *ERROR set. */
static char *perform(const char *target, const char *action, portal_text *error)
{
    portal_text state = {0};
    return portal_toolbar_perform(text(target), text(action), &state, error) ? state.data : NULL;
}

/* Whether ACTION on TARGET succeeds, returning JSON that contains each of
   the NULL-terminated FRAGMENTS. */
static bool performs(const char *target, const char *action, ...)
{
    portal_text error = {0};
    char *json = perform(target, action, &error);
    if (!json) {
        fprintf(stderr, "%s on %s failed: %s\n", action, target, error.data);
        free(error.data);
        return false;
    }
    bool all = true;
    va_list arguments;
    va_start(arguments, action);
    for (const char *fragment; all && (fragment = va_arg(arguments, const char *));)
        if (!strstr(json, fragment)) {
            fprintf(stderr, "Expected %s in %s\n", fragment, json);
            all = false;
        }
    va_end(arguments);
    free(json);
    return all;
}

/* Whether ACTION on TARGET fails with MESSAGE. */
static bool refuses(const char *target, const char *action, const char *message)
{
    portal_text error = {0};
    char *json = perform(target, action, &error);
    free(json);
    return !json && says(&error, message);
}

static void click(const char *target, portal_button button)
{
    portal_toolbar_clicked(text(target), button);
}

static void type(const char *target, const char *query)
{
    portal_toolbar_typed(text(target), text(query));
}

/* The oldest request the core made that nobody answered, which must be a
   find, when FIND, or a call, of TARGET's, with TEXT; its token, or 0. */
static uint64_t asked(const char *target, bool find, const char *text)
{
    struct portal_fake_request request;
    if (!portal_fake_request(&request)) {
        fprintf(stderr, "Expected a request for %s, got none\n", text);
        return 0;
    }
    bool same = request.find == find && !strcmp(request.target, target)
             && !strcmp(request.text, text);
    if (!same)
        fprintf(stderr, "Expected %s %s from %s, got %s %s from %s\n", find ? "find" : "call",
                text, target, request.find ? "find" : "call", request.text, request.target);
    return same ? request.token : 0;
}

static bool nothing_asked(void)
{
    struct portal_fake_request request;
    if (!portal_fake_request(&request))
        return true;
    fprintf(stderr, "Expected no request, got %s from %s\n", request.text, request.target);
    return false;
}

/* Answer TARGET's search for QUERY: its count, then whether it found one.
   BACKWARDS says which way it must go. */
static void answer(const char *target, const char *query, bool backwards, int64_t count,
                   bool found)
{
    /* The call's argument is QUERY as a JSON string. */
    char call[256] = "portalToolbar.count(\"", find[256];
    for (const char *c = query; *c; c++) {
        size_t length = strlen(call);
        if (*c == '"' || *c == '\\')
            call[length++] = '\\';
        call[length] = *c;
        call[length + 1] = '\0';
    }
    strcat(call, "\")");
    snprintf(find, sizeof find, "%s%s", backwards ? "back " : "", query);
    uint64_t token = asked(target, false, call);
    CHECK(token);
    portal_web_returned(text(target), token, true, count);
    token = asked(target, true, find);
    CHECK(token);
    portal_web_found(text(target), token, found);
}

static bool matches(const char *target, int64_t match, int64_t count)
{
    portal_toolbar toolbar = drawn(target);
    if (toolbar.match == match && toolbar.matches == count)
        return true;
    fprintf(stderr, "Expected match %lld of %lld, got %lld of %lld\n", (long long) match,
            (long long) count, (long long) toolbar.match, (long long) toolbar.matches);
    return false;
}

static void test_each_layout_has_its_buttons(void)
{
    portal_text error = {0};
    uint32_t value = bits(3, DECREASE, RESET, INCREASE);
    uint32_t page = bits(5, OWNER, BACK, FORWARD, FIND, RELOAD) | value;
    char *navigation = open_web("navigation", false), *contents = open_web("contents", false);
    char *markdown = open_web("markdown", false), *hosted = open_web("markdown", true);
    char *terminal = open_terminal(false);
    /* A toolbar shows only while its view has the keyboard. */
    const char *each[] = {navigation, contents, markdown, hosted, terminal};
    for (size_t i = 0; i < 5; i++) {
        place(each[i], "frame");
        CHECK(!drawn(each[i]).visible && drawn(each[i]).owner == PORTAL_OWNER_EMACS);
        enter(each[i]);
        CHECK(drawn(each[i]).visible && drawn(each[i]).owner == PORTAL_OWNER_VIEW);
    }
    enter(navigation);
    portal_toolbar toolbar = drawn(navigation);
    CHECK(toolbar.visible && toolbar.buttons == page && !toolbar.finding);
    CHECK(toolbar.owner == PORTAL_OWNER_VIEW && toolbar.unit == PORTAL_PERCENT);
    CHECK(toolbar.value == 100 && toolbar.standard == 100);
    /* Nothing to go back or forward to yet. */
    CHECK(toolbar.enabled == bits(6, OWNER, FIND, RELOAD, DECREASE, RESET, INCREASE));
    enter(contents);
    CHECK(drawn(contents).buttons == (page | bits(1, CONTENTS)));
    /* Headings arrive once the page has them. */
    CHECK(!(drawn(contents).enabled & bits(1, CONTENTS)));
    enter(markdown);
    CHECK(drawn(markdown).buttons == (page | bits(1, CONTENTS)));
    /* Only a hosted preview can ask Emacs to edit its file. */
    enter(hosted);
    CHECK(drawn(hosted).buttons == (page | bits(2, CONTENTS, EDIT)));
    enter(terminal);
    toolbar = drawn(terminal);
    CHECK(toolbar.visible && toolbar.buttons == (bits(1, OWNER) | value));
    CHECK(toolbar.unit == PORTAL_POINTS && toolbar.value == PORTAL_TERMINAL_POINTS
          && toolbar.standard == PORTAL_TERMINAL_POINTS);
    CHECK(performs(terminal, "state", "\"value\":14", NULL));
    CHECK(performs(navigation, "state",
                   "{\"back\":false,\"find\":false,\"forward\":false,\"headings\":false,"
                   "\"match\":0,\"matches\":0,\"query\":\"\",\"toc\":false,\"value\":100}",
                   NULL));
    /* Views that have no toolbar on purpose draw none, and have no actions. */
    char *none = open_web("none", false), *quick = open_terminal(true);
    char *plain = open_view("web", &error, NULL);
    const char *bare[] = {none, quick, plain};
    for (size_t i = 0; i < 3; i++) {
        CHECK(!drawn(bare[i]).visible);
        CHECK(shows(bare[i], "\"strip\":false", NULL));
        CHECK(refuses(bare[i], "state", "No toolbar controls for this native view"));
        /* Toolbar-free views still say who has the keyboard. */
        portal_input_focus(text(bare[i]), true);
        CHECK(!drawn(bare[i]).visible && drawn(bare[i]).owner == PORTAL_OWNER_VIEW);
        portal_input_focus(text(bare[i]), false);
        CHECK(!drawn(bare[i]).visible && drawn(bare[i]).owner == PORTAL_OWNER_EMACS);
    }
    enter(navigation);
    CHECK(shows(navigation, "\"strip\":true", NULL));
    CHECK(refuses("web:0", "state", "No Portal view web:0"));
    CHECK(refuses(navigation, "edit", "Unknown web toolbar action: edit"));
    CHECK(refuses(terminal, "back", "Unknown terminal toolbar action: back"));
    CHECK(refuses(terminal, "find", "Find needs a visible web toolbar"));
    /* An invalid toolbar creates nothing. */
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(!open_view("web", &error, "toolbar", "floating", NULL));
    CHECK(says(&error, "A web view's :toolbar must be \"navigation\", \"contents\", "
                       "\"markdown\" or \"none\""));
    CHECK(portal_fake_calls().created == before.created);
    char *views[] = {navigation, contents, markdown, hosted, terminal, none, quick, plain};
    for (size_t i = 0; i < sizeof views / sizeof *views; i++)
        close_view(views[i]);
}

static void test_zoom_and_text_size_stop_at_their_limits(void)
{
    char *web = open_web("navigation", false);
    enter(web);
    const double steps[] = {110, 125, 150, 175, 200, 250, 300};
    for (size_t i = 0; i < sizeof steps / sizeof *steps; i++) {
        CHECK(performs(web, "increase", NULL));
        CHECK(drawn(web).value == steps[i]);
    }
    CHECK(shows(web, "\"zoom\":3", NULL));
    CHECK(!(drawn(web).enabled & bits(1, INCREASE)));
    CHECK(performs(web, "increase", "\"value\":300", NULL));
    CHECK(performs(web, "reset", "\"value\":100", NULL));
    const double down[] = {85, 75, 67, 50, 50};
    for (size_t i = 0; i < sizeof down / sizeof *down; i++) {
        click(web, DECREASE);
        CHECK(drawn(web).value == down[i]);
    }
    CHECK(shows(web, "\"zoom\":0.5", NULL));
    CHECK(!(drawn(web).enabled & bits(1, DECREASE)) && (drawn(web).enabled & bits(1, INCREASE)));
    click(web, RESET);
    CHECK(drawn(web).value == 100 && shows(web, "\"zoom\":1", NULL));
    /* A zoom the platform refuses leaves the value as it was. */
    portal_fake_refuse(true);
    CHECK(refuses(web, "increase", "The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    CHECK(performs(web, "state", "\"value\":100", NULL));

    char *terminal = open_terminal(false);
    enter(terminal);
    CHECK(performs(terminal, "increase", "\"value\":15", NULL));
    CHECK(shows(terminal, "\"font-size\":15", NULL));
    for (int i = 0; i < 20; i++)
        click(terminal, DECREASE);
    CHECK(drawn(terminal).value == 1 && shows(terminal, "\"font-size\":1", NULL));
    CHECK(!(drawn(terminal).enabled & bits(1, DECREASE)));
    for (int i = 0; i < 300; i++)
        click(terminal, INCREASE);
    CHECK(drawn(terminal).value == 255 && !(drawn(terminal).enabled & bits(1, INCREASE)));
    CHECK(performs(terminal, "reset", "\"value\":14", NULL));
    CHECK(shows(terminal, "\"font-size\":14", NULL));
    /* A terminal that cannot change its font keeps its size. */
    portal_text broken = {0};
    char *failing = open_view("terminal", &broken, "directory", "/", "broken", "No font", NULL);
    CHECK(refuses(failing, "increase", "No font"));
    CHECK(performs(failing, "state", "\"value\":14", NULL));
    close_view(failing);

    /* The keyboard's shortcuts take the same steps, in a terminal with the
       keyboard, with or without a toolbar. */
    char *quick = open_terminal(true);
    enter(terminal);
    portal_fake_keys();
    portal_fake_press((portal_chord) {'=', PORTAL_SUPER}, false);
    portal_fake_press((portal_chord) {'+', PORTAL_SUPER | PORTAL_SHIFT}, true);
    CHECK(!strcmp(portal_fake_keys(), "taken s-=, taken s-S-+ repeat"));
    CHECK(drawn(terminal).value == 16);
    portal_fake_press((portal_chord) {'-', PORTAL_SUPER}, false);
    portal_fake_press((portal_chord) {'0', PORTAL_SUPER | PORTAL_SHIFT}, false);
    CHECK(drawn(terminal).value == 14);
    CHECK(!strcmp(portal_fake_keys(), "taken s--, taken s-S-0"));
    enter(quick);
    portal_fake_press((portal_chord) {'=', PORTAL_SUPER}, false);
    CHECK(shows(quick, "\"font-size\":15", NULL));
    /* A web view has no text size shortcut: what its page does not use is
       Emacs's. */
    enter(web);
    portal_fake_keys();
    portal_fake_press((portal_chord) {'=', PORTAL_SUPER}, false);
    portal_fake_answer(false);
    CHECK(!strcmp(portal_fake_keys(), "offered s-=, unused held s-="));
    CHECK(drawn(web).value == 100);
    drain();
    close_view(quick);
    close_view(terminal);
    close_view(web);
}

/* A toolbar covers its pane's mode line while its view has the keyboard,
   or Emacs reads a command for it; its dot then gives Emacs the keyboard. */
static void test_the_toolbar_shows_while_the_view_has_the_keyboard(void)
{
    portal_text error = {0};
    char *web = open_web("navigation", false);
    place(web, "frame");
    CHECK(!drawn(web).visible && drawn(web).owner == PORTAL_OWNER_EMACS);
    bool done = false;
    CHECK(portal_input_perform(text(web), text("focus"), 0, &done, &error) && done);
    CHECK(drawn(web).visible && drawn(web).owner == PORTAL_OWNER_VIEW);
    CHECK(drawn(web).enabled & bits(1, OWNER));
    click(web, OWNER);
    CHECK(!drawn(web).visible && drawn(web).owner == PORTAL_OWNER_EMACS);
    /* A hidden toolbar's buttons do nothing. */
    struct portal_fake_calls before = portal_fake_calls();
    click(web, OWNER);
    click(web, RELOAD);
    CHECK(same_calls(before, portal_fake_calls()) && drawn(web).owner == PORTAL_OWNER_EMACS);
    CHECK(portal_input_perform(text(web), text("focus"), 0, &done, &error) && done);
    drain();
    /* While the page decides on a chord, the view still has the keyboard. */
    portal_fake_press((portal_chord) {'x', PORTAL_CONTROL}, false);
    CHECK(drawn(web).owner == PORTAL_OWNER_VIEW);
    /* While Emacs reads a command, the toolbar stays, its dot says so and
       does nothing. */
    portal_fake_answer(false);
    CHECK(drawn(web).visible && drawn(web).owner == PORTAL_OWNER_PENDING);
    CHECK(!(drawn(web).enabled & bits(1, OWNER)));
    before = portal_fake_calls();
    click(web, OWNER);
    CHECK(drawn(web).owner == PORTAL_OWNER_PENDING);
    CHECK(same_calls(before, portal_fake_calls()));
    /* The user's way back ends the handoff, and the mode line shows again. */
    portal_fake_escape();
    CHECK(!drawn(web).visible && drawn(web).owner == PORTAL_OWNER_EMACS);
    drain();
    /* Hiding the view returns the keyboard. */
    enter(web);
    CHECK(portal_views_hide(text(web), &error));
    CHECK(!drawn(web).visible && drawn(web).owner == PORTAL_OWNER_EMACS);
    /* A pane without a mode line shows no toolbar, and has no find. */
    CHECK(portal_views_place(text(web), (portal_edges) {0, 0, 640, 480}, NULL, text("frame"),
                             &error));
    CHECK(portal_input_perform(text(web), text("focus"), 0, &done, &error) && done);
    CHECK(!drawn(web).visible && drawn(web).owner == PORTAL_OWNER_VIEW);
    CHECK(refuses(web, "find", "Find needs a visible web toolbar"));
    /* Its mode line back, the toolbar shows at once. */
    place(web, "frame");
    CHECK(drawn(web).visible);
    /* Hidden with find open, and placed again in a pane with a mode line,
       the view shows its find field again. */
    CHECK(performs(web, "find", NULL));
    CHECK(portal_views_hide(text(web), &error));
    CHECK(!drawn(web).visible);
    place(web, "frame");
    CHECK(drawn(web).visible && drawn(web).finding);
    CHECK(performs(web, "close-find", NULL));
    answer(web, "", false, 0, false);
    CHECK(shows(web, "\"bar\":[0,480,640,26]", NULL));
    close_view(web);
    drain();
}

static void test_find_runs_searches_in_order(void)
{
    char *web = open_web("navigation", false);
    enter(web);
    size_t fields = portal_fake_calls().fields;
    CHECK(performs(web, "find", "\"find\":true", NULL));
    portal_toolbar toolbar = drawn(web);
    CHECK(toolbar.finding && toolbar.buttons == bits(4, OWNER, PREVIOUS, NEXT, CLOSE));
    CHECK(toolbar.enabled == bits(2, OWNER, CLOSE));
    /* The field has the keyboard, which is the view's. */
    CHECK(portal_fake_calls().fields == fields + 1 && toolbar.owner == PORTAL_OWNER_VIEW);
    CHECK(nothing_asked());
    type(web, "n");
    /* Newer text replaces the searches still waiting for older text. */
    type(web, "ne");
    type(web, "needle \"one\"");
    CHECK(drawn(web).query.length == 12);
    answer(web, "n", false, 9, true);
    CHECK(matches(web, 1, 9));
    answer(web, "needle \"one\"", false, 3, true);
    CHECK(matches(web, 1, 3));
    CHECK(nothing_asked());
    CHECK(drawn(web).enabled == bits(4, OWNER, PREVIOUS, NEXT, CLOSE));
    CHECK(performs(web, "state", "\"match\":1", "\"matches\":3", "\"query\":\"needle \\\"one\\\"\"",
                   NULL));
    type(web, "needle");
    answer(web, "needle", false, 3, true);
    /* Rapid steps run one at a time, each after the last one's result. */
    click(web, NEXT);
    click(web, NEXT);
    uint64_t token = asked(web, false, "portalToolbar.count(\"needle\")");
    CHECK(nothing_asked());
    portal_web_returned(text(web), token, true, 3);
    token = asked(web, true, "needle");
    CHECK(nothing_asked());
    portal_web_found(text(web), token, true);
    CHECK(matches(web, 2, 3));
    answer(web, "needle", false, 3, true);
    CHECK(matches(web, 3, 3));
    click(web, NEXT);
    answer(web, "needle", false, 3, true);
    CHECK(matches(web, 1, 3));
    click(web, PREVIOUS);
    answer(web, "needle", true, 3, true);
    CHECK(matches(web, 3, 3));
    /* A count that changed wraps within the new one. */
    click(web, NEXT);
    answer(web, "needle", false, 2, true);
    CHECK(matches(web, 2, 2));
    /* A new query starts from its first match, or its last going back. */
    type(web, "needl");
    answer(web, "needl", false, 4, true);
    CHECK(matches(web, 1, 4));
    type(web, "absent");
    answer(web, "absent", false, 0, false);
    CHECK(matches(web, 0, 0));
    CHECK(drawn(web).enabled == bits(2, OWNER, CLOSE));
    /* The field's Return searches again even with no match. */
    click(web, NEXT);
    answer(web, "absent", false, 0, false);
    /* A match the count missed, such as in a frame, still counts once. */
    type(web, "frame");
    answer(web, "frame", false, 0, true);
    CHECK(matches(web, 1, 1));
    /* A failed count counts nothing. */
    click(web, PREVIOUS);
    token = asked(web, false, "portalToolbar.count(\"frame\")");
    portal_web_returned(text(web), token, false, 0);
    portal_web_found(text(web), asked(web, true, "back frame"), true);
    CHECK(matches(web, 1, 1));
    close_view(web);
}

static void test_a_new_page_drops_old_results(void)
{
    char *web = open_web("contents", false);
    enter(web);
    CHECK(performs(web, "find", NULL));
    type(web, "word");
    uint64_t counting = asked(web, false, "portalToolbar.count(\"word\")");
    click(web, NEXT); /* Waits behind it. */
    /* The page loads another document: the waiting search goes, and the
       running one's result will not count. */
    portal_web_committed(text(web), text("https://example.com/next"));
    portal_web_loaded(text(web));
    uint64_t contents = asked(web, false, "portalToolbar.toc(false)");
    CHECK(nothing_asked());
    portal_web_returned(text(web), counting, true, 7);
    /* Dropped at once: no find, and the search again, fresh, on the new page. */
    uint64_t token = asked(web, false, "portalToolbar.count(\"word\")");
    CHECK(nothing_asked());
    CHECK(matches(web, 0, 0));
    portal_web_returned(text(web), token, true, 2);
    token = asked(web, true, "word");
    /* Results nobody waits for reach nothing. */
    portal_web_found(text(web), token + 100, true);
    portal_web_returned(text(web), token + 100, true, 5);
    portal_web_found(text(web), 0, true);
    CHECK(matches(web, 0, 0) && nothing_asked());
    portal_web_found(text(web), token, true);
    CHECK(matches(web, 1, 2));
    /* A find the page finished before it loaded again is dropped too. */
    click(web, NEXT);
    token = asked(web, false, "portalToolbar.count(\"word\")");
    portal_web_returned(text(web), token, true, 2);
    token = asked(web, true, "word");
    portal_web_loaded(text(web));
    CHECK(asked(web, false, "portalToolbar.toc(false)"));
    portal_web_found(text(web), token, true);
    CHECK(matches(web, 0, 0));
    answer(web, "word", false, 2, true);
    CHECK(matches(web, 1, 2));
    /* Only the latest load's table of contents call says how many headings
       there are. */
    portal_web_returned(text(web), contents, true, 3);
    CHECK(!(drawn(web).enabled & bits(1, CONTENTS)));
    close_view(web);
}

static void test_the_table_of_contents(void)
{
    char *web = open_web("contents", false), *page = open_web("navigation", false);
    enter(web);
    CHECK(refuses(page, "toc", "This preview has no headings"));
    CHECK(refuses(web, "toc", "This preview has no headings"));
    portal_web_headings(text(web), 2);
    CHECK(drawn(web).enabled & bits(1, CONTENTS));
    CHECK(performs(web, "toc", "\"toc\":true", "\"headings\":true", NULL));
    CHECK(drawn(web).selected == bits(1, CONTENTS));
    CHECK(asked(web, false, "portalToolbar.toc(true)"));
    /* A new page has no headings until it reports them; its load shows the
       table again, and says how many there are. */
    portal_web_committed(text(web), text("https://example.com/"));
    CHECK(!(drawn(web).enabled & bits(1, CONTENTS)) && drawn(web).selected);
    portal_web_loaded(text(web));
    uint64_t token = asked(web, false, "portalToolbar.toc(true)");
    portal_web_returned(text(web), token, true, 4);
    CHECK(performs(web, "state", "\"headings\":true", "\"toc\":true", NULL));
    /* A failed call leaves the headings as they were. */
    portal_web_loaded(text(web));
    portal_web_returned(text(web), asked(web, false, "portalToolbar.toc(true)"), false, 0);
    CHECK(drawn(web).enabled & bits(1, CONTENTS));
    click(web, CONTENTS);
    CHECK(!drawn(web).selected && asked(web, false, "portalToolbar.toc(false)"));
    portal_web_headings(text(web), 0);
    CHECK(refuses(web, "toc", "This preview has no headings"));
    CHECK(nothing_asked());
    close_view(page);
    close_view(web);
}

/* Closing find returns the keyboard to the content only while the view
   has it. */
static void test_closing_find_keeps_the_users_focus(void)
{
    char *web = open_web("navigation", false), *other = open_web("navigation", false);
    enter(web);
    CHECK(performs(web, "find", NULL));
    struct portal_fake_calls before = portal_fake_calls();
    click(web, CLOSE);
    CHECK(!drawn(web).finding && drawn(web).owner == PORTAL_OWNER_VIEW);
    CHECK(portal_fake_calls().focused == before.focused + 1);
    /* Closing clears the page's selected match. */
    answer(web, "", false, 0, false);
    /* The user moved to Emacs. */
    click(web, FIND);
    CHECK(drawn(web).finding);
    portal_fake_escape();
    before = portal_fake_calls();
    CHECK(performs(web, "close-find", "\"find\":false", NULL));
    CHECK(portal_fake_calls().focused == before.focused);
    CHECK(drawn(web).owner == PORTAL_OWNER_EMACS);
    answer(web, "", false, 0, false);
    /* The user moved to another view. */
    CHECK(performs(web, "find", NULL));
    place(other, "frame");
    CHECK(portal_fake_click(other));
    click(web, CLOSE);
    CHECK(drawn(other).owner == PORTAL_OWNER_VIEW && drawn(web).owner == PORTAL_OWNER_EMACS);
    answer(web, "", false, 0, false);
    /* Closing a closed field does nothing. */
    before = portal_fake_calls();
    CHECK(performs(web, "close-find", NULL));
    CHECK(same_calls(before, portal_fake_calls()) && nothing_asked());
    drain();
    close_view(other);
    close_view(web);
}

/* A Super chord that a web view's page does not use goes to its shortcuts,
   and then to Emacs, whose handoff ends here. */
static void unused(const char *target, char character, uint32_t modifiers, const char *keys)
{
    portal_fake_keys();
    portal_fake_press((portal_chord) {(unsigned char) character, modifiers}, false);
    portal_fake_answer(false);
    CHECK(!strcmp(portal_fake_keys(), keys));
    if (portal_input_owner(text(target)) == PORTAL_OWNER_PENDING) {
        portal_fake_escape();
        enter(target);
    }
    drain();
}

/* Command-F, as macOS spells Super-f, opens a visible find field in a web
   view that has the keyboard, when its page does not use it. */
static void test_super_f_opens_find(void)
{
    char *web = open_web("contents", false), *none = open_web("none", false);
    enter(web);
    unused(web, 'f', PORTAL_SUPER, "offered s-f, unused taken s-f");
    CHECK(drawn(web).finding);
    CHECK(performs(web, "close-find", NULL));
    answer(web, "", false, 0, false);
    /* A page that uses it keeps it. */
    portal_fake_keys();
    portal_fake_press((portal_chord) {'f', PORTAL_SUPER}, false);
    portal_fake_answer(true);
    CHECK(!strcmp(portal_fake_keys(), "offered s-f, used s-f") && !drawn(web).finding);
    unused(web, 'f', PORTAL_SUPER | PORTAL_SHIFT, "offered s-S-f, unused held s-S-f");
    CHECK(!drawn(web).finding);
    enter(none);
    unused(none, 'f', PORTAL_SUPER, "offered s-f, unused held s-f");
    CHECK(refuses(none, "find", "No toolbar controls for this native view"));
    /* Hidden toolbars have no find field. */
    enter(web);
    portal_toolbar_show(false);
    unused(web, 'f', PORTAL_SUPER, "offered s-f, unused held s-f");
    CHECK(refuses(web, "find", "Find needs a visible web toolbar"));
    portal_toolbar_show(true);
    CHECK(nothing_asked());
    close_view(none);
    close_view(web);
}

/* Command-R reloads a web view that has the keyboard and whose toolbar has
   Reload, even while toolbars are hidden, when its page does not use it. */
static void test_super_r_reloads(void)
{
    char *web = open_web("markdown", true), *none = open_web("none", true);
    enter(web);
    unused(web, 'r', PORTAL_SUPER, "offered s-r, unused taken s-r");
    portal_toolbar_show(false);
    unused(web, 'r', PORTAL_SUPER, "offered s-r, unused taken s-r");
    portal_toolbar_show(true);
    CHECK(shows(web, "\"history\":\"reload reload\"", NULL));
    struct portal_fake_calls before = portal_fake_calls();
    unused(web, 'r', PORTAL_SUPER | PORTAL_SHIFT, "offered s-S-r, unused held s-S-r");
    /* Excalidraw's view has no toolbar, so Emacs gets Command-R. */
    enter(none);
    unused(none, 'r', PORTAL_SUPER, "offered s-r, unused held s-r");
    CHECK(portal_fake_calls().went == before.went);
    close_view(none);
    close_view(web);
}

static void test_state_is_kept_and_drawn_only_when_it_changes(void)
{
    portal_text error = {0};
    char *web = open_web("contents", false);
    enter(web);
    portal_web_headings(text(web), 1);
    CHECK(performs(web, "increase", NULL) && performs(web, "toc", NULL));
    CHECK(asked(web, false, "portalToolbar.toc(true)"));
    CHECK(performs(web, "find", NULL));
    type(web, "kept");
    answer(web, "kept", false, 2, true);
    /* Asking changes nothing, so draws nothing. */
    size_t count = draws(web);
    CHECK(performs(web, "state", NULL));
    portal_toolbar_refresh(text(web));
    CHECK(draws(web) == count);
    /* Hidden and shown again, in another frame, the view keeps it all. */
    CHECK(portal_views_hide(text(web), &error));
    place(web, "other");
    CHECK(performs(web, "state", "\"find\":true", "\"query\":\"kept\"", "\"matches\":2",
                   "\"toc\":true", "\"value\":110", NULL));
    /* Hiding every toolbar closes find, and shows no toolbar. */
    enter(web);
    CHECK(performs(web, "find", NULL));
    portal_toolbar_show(false);
    CHECK(!drawn(web).visible && shows(web, "\"strip\":false", NULL));
    answer(web, "", false, 0, false);
    count = draws(web);
    portal_toolbar_show(false);
    CHECK(draws(web) == count);
    portal_toolbar_show(true);
    portal_toolbar toolbar = drawn(web);
    CHECK(toolbar.visible && !toolbar.finding && toolbar.value == 110);
    CHECK(toolbar.selected == bits(1, CONTENTS));
    CHECK(performs(web, "state", "\"query\":\"kept\"", NULL));
    /* Colors reach every toolbar, and only a change draws. */
    char *terminal = open_terminal(false);
    enter(terminal);
    enter(web);
    portal_colors colors = {.background = {true, 0.1, 0.2, 0.3}, .success = {true, 0, 1, 0}};
    portal_toolbar_paint(&colors);
    CHECK(drawn(web).colors.background.set && drawn(web).colors.background.blue == 0.3);
    /* A toolbar that does not show draws no colors. */
    CHECK(!drawn(terminal).visible && !drawn(terminal).colors.background.set);
    CHECK(drawn(web).colors.success.green == 1 && !drawn(web).colors.accent.set);
    count = draws(web);
    portal_toolbar_paint(&colors);
    CHECK(draws(web) == count);
    colors.success.set = false;
    portal_toolbar_paint(&colors);
    CHECK(draws(web) == count + 1 && !drawn(web).colors.success.set);
    colors.tint = (portal_color) {true, 1, 0, 1};
    portal_toolbar_paint(&colors);
    CHECK(draws(web) == count + 2 && drawn(web).colors.tint.set
          && drawn(web).colors.tint.blue == 1);
    /* The label is Lisp's; the toolbar shows it, and only a change draws. */
    CHECK(drawn(web).label.length == 0);
    CHECK(portal_toolbar_label(text(web), text("docs/README.md"), &error));
    CHECK(draws(web) == count + 3 && same(drawn(web).label, text("docs/README.md")));
    CHECK(portal_toolbar_label(text(web), text("docs/README.md"), &error));
    CHECK(draws(web) == count + 3);
    /* A hidden toolbar keeps its label for when it shows again. */
    CHECK(portal_toolbar_label(text(terminal), text("*terminal: portal*"), &error));
    CHECK(!drawn(terminal).visible && drawn(terminal).label.length == 0);
    enter(terminal);
    CHECK(same(drawn(terminal).label, text("*terminal: portal*")));
    CHECK(!portal_toolbar_label(text("web:999"), text("gone"), &error)
          && says(&error, "No Portal view web:999"));
    enter(web);
    /* A draw the platform refuses is tried again. */
    portal_fake_refuse(true);
    portal_toolbar_show(false);
    portal_fake_refuse(false);
    CHECK(drawn(web).visible);
    portal_toolbar_refresh(text(web));
    CHECK(!drawn(web).visible);
    portal_toolbar_show(true);
    portal_toolbar_paint(&(portal_colors) {0});
    close_view(terminal);
    close_view(web);
}

static void test_buttons_act_on_the_view(void)
{
    char *web = open_web("markdown", true), *plain = open_web("markdown", false);
    enter(web);
    /* Back and forward follow the page's history. */
    portal_web_history(text(web), true, false);
    CHECK((drawn(web).enabled & bits(2, BACK, FORWARD)) == bits(1, BACK));
    CHECK(performs(web, "state", "\"back\":true", "\"forward\":false", NULL));
    click(web, BACK);
    click(web, FORWARD);
    click(web, RELOAD);
    CHECK(performs(web, "back", NULL) && performs(web, "reload", NULL));
    CHECK(shows(web, "\"history\":\"back forward reload back reload\"", NULL));
    /* Open in Emacs gives Emacs the keyboard, then asks over the bridge. */
    drain();
    click(web, EDIT);
    CHECK(drawn(web).owner == PORTAL_OWNER_EMACS);
    char records_expected[64];
    snprintf(records_expected, sizeof records_expected, "bridge %s\n", web);
    CHECK(!strcmp(drain(), records_expected));
    portal_text json = {0}, error = {0};
    CHECK(portal_web_views_receive(text(web), &json, &error));
    CHECK(json.data && !strcmp(json.data, "[{\"type\":\"edit\"}]"));
    free(json.data);
    /* Buttons a toolbar does not have do nothing. */
    struct portal_fake_calls before = portal_fake_calls();
    click(plain, EDIT);
    click(web, PREVIOUS);
    click(web, CLOSE);
    click(web, (portal_button) 31);
    CHECK(same_calls(before, portal_fake_calls()) && nothing_asked() && !strcmp(drain(), ""));
    close_view(plain);
    close_view(web);
}

static void test_a_closed_view_hears_nothing(void)
{
    char *web = open_web("contents", false);
    char *target = strdup(web);
    enter(web);
    CHECK(performs(web, "find", NULL));
    type(web, "late");
    uint64_t token = asked(web, false, "portalToolbar.count(\"late\")");
    close_view(web);
    struct portal_fake_calls before = portal_fake_calls();
    portal_web_returned(text(target), token, true, 1);
    portal_web_found(text(target), token, true);
    portal_web_loaded(text(target));
    portal_web_headings(text(target), 3);
    portal_web_history(text(target), true, true);
    portal_toolbar_clicked(text(target), FIND);
    portal_toolbar_typed(text(target), text("later"));
    portal_toolbar_refresh(text(target));
    CHECK(same_calls(before, portal_fake_calls()) && nothing_asked());
    CHECK(draws(target) == 0);
    free(target);
}

int main(void)
{
    int fds[2];
    if (pipe(fds) || fcntl(fds[0], F_SETFL, O_NONBLOCK) == -1)
        abort();
    records = fds[0];
    CHECK(portal_channel_connect(fds[1]));
    test_each_layout_has_its_buttons();
    test_zoom_and_text_size_stop_at_their_limits();
    test_the_toolbar_shows_while_the_view_has_the_keyboard();
    test_find_runs_searches_in_order();
    test_a_new_page_drops_old_results();
    test_the_table_of_contents();
    test_closing_find_keeps_the_users_focus();
    test_super_f_opens_find();
    test_super_r_reloads();
    test_state_is_kept_and_drawn_only_when_it_changes();
    test_buttons_act_on_the_view();
    test_a_closed_view_hears_nothing();
    CHECK(nothing_asked());
    CHECK(!portal_fake_calls().misused);
    portal_channel_connect(-1);
    close(records);
    if (failures) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    puts("Toolbars passed");
    return 0;
}
