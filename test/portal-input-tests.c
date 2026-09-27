/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The core's input handoff, native/Core/input.c, with the fake platform.
   Keys are pressed as a user would, and the fake routes them as the macOS
   platform does: it holds what the core says to hold, and replays it when a
   test runs the event loop.  Emacs's side is played by the actions
   portal-input.el takes, in its order: ack, command, then finish.  Records
   are read from a real pipe. */
#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "channel.h"
#include "input.h"
#include "portal-fake-backend.h"
#include "portal.h"
#include "views.h"

static int failures;
static int records = -1; /* The pipe's read end. */

#define CHECK(condition) check((condition), #condition, __LINE__)

static void check(bool passed, const char *condition, int line)
{
    if (!passed) {
        fprintf(stderr, "%s:%d: FAIL: %s\n", __FILE__, line, condition);
        failures++;
    }
}

static portal_string text(const char *literal)
{
    return (portal_string) {literal, strlen(literal)};
}

enum { C = PORTAL_CONTROL, M = PORTAL_META, S = PORTAL_SUPER, SHIFT = PORTAL_SHIFT };

static void press(char character, uint32_t modifiers)
{
    portal_fake_press((portal_chord) {(unsigned char) character, modifiers}, false);
}

static void repeat(char character, uint32_t modifiers)
{
    portal_fake_press((portal_chord) {(unsigned char) character, modifiers}, true);
}

/* Whether the presses since the last call went where EXPECTED says, a
   format for the targets. */
static bool went(const char *expected, ...)
{
    char wanted[1024];
    va_list arguments;
    va_start(arguments, expected);
    vsnprintf(wanted, sizeof wanted, expected, arguments);
    va_end(arguments);
    const char *keys = portal_fake_keys();
    if (strcmp(keys, wanted))
        fprintf(stderr, "Expected keys \"%s\", got \"%s\"\n", wanted, keys);
    return !strcmp(keys, wanted);
}

/* The records sent since the last call, valid until the next. */
static const char *received(void)
{
    static char buffer[4096];
    ssize_t count = read(records, buffer, sizeof buffer - 1);
    buffer[count > 0 ? count : 0] = '\0';
    return buffer;
}

/* Whether the records since the last call are EXPECTED, a format. */
static bool sent(const char *expected, ...)
{
    char wanted[1024];
    va_list arguments;
    va_start(arguments, expected);
    vsnprintf(wanted, sizeof wanted, expected, arguments);
    va_end(arguments);
    const char *got = received();
    if (strcmp(got, wanted))
        fprintf(stderr, "Expected records \"%s\", got \"%s\"\n", wanted, got);
    return !strcmp(got, wanted);
}

/* The serial of the one handoff record TYPE for TARGET sent since the last
   call, or 0; set *KEY to its key field, unless KEY is NULL. */
static int64_t handoff_key(const char *type, const char *target, int64_t *event)
{
    const char *got = received();
    char format[64];
    int64_t serial = 0, key = 0;
    snprintf(format, sizeof format, "%s %s %%" SCNd64 " %%" SCNd64 "\n", type, target);
    if (sscanf(got, format, &serial, &key) != 2 || !strchr(got, '\n') || strchr(got, '\n')[1]) {
        fprintf(stderr, "Expected one %s record for %s, got \"%s\"\n", type, target, got);
        return 0;
    }
    if (event)
        *event = key;
    return serial;
}

static int64_t handoff(const char *type, const char *target)
{
    return handoff_key(type, target, NULL);
}

/* The event of TARGET's one binding record since the last call, ending that
   handoff. */
static int64_t binding(const char *target);

/* Perform ACTION on TARGET with SERIAL, which must succeed; its result. */
static bool act(const char *target, const char *action, int64_t serial)
{
    bool result = false;
    portal_text error = {0};
    if (!portal_input_perform(text(target), text(action), serial, &result, &error)) {
        fprintf(stderr, "%s on %s failed: %s\n", action, target, error.data);
        free(error.data);
        failures++;
    }
    return result;
}

/* Open a view of KIND, with the flag option :quick if QUICK, attached, and
   with the keyboard. */
static char *open_view(const char *kind, bool quick)
{
    /* Terminals need a directory (terminals.c). */
    portal_option options[] = {{.name = text("directory"), .is_string = true, .string = text("/")},
                               {.name = text("quick"), .flag = true}};
    portal_text target = {0}, error = {0};
    if (!portal_views_open(text(kind), options, quick ? 2 : 1, &target, &error)
        || !portal_views_place(text(target.data), (portal_edges) {0, 0, 100, 100}, text("frame"),
                               &error))
        abort();
    CHECK(act(target.data, "focus", 0));
    CHECK(act(target.data, "focused", 0));
    return target.data;
}

static void close_view(char *target)
{
    portal_text error = {0};
    CHECK(portal_views_close(text(target), &error));
    free(target);
}

static bool same_calls(struct portal_fake_calls a, struct portal_fake_calls b)
{
    return !memcmp(&a, &b, sizeof a);
}

static void test_a_handoff_from_the_prefix_to_the_command(void)
{
    char *web = open_view("web", false);
    press('x', 0);
    press('b', C);
    CHECK(went("%s x, held C-b", web));
    int64_t serial = handoff("prefix", web);
    CHECK(serial > 0);
    /* Emacs has the keyboard while it handles the handoff. */
    CHECK(!act(web, "focused", 0));
    CHECK(act(web, "pending", serial));
    CHECK(portal_input_owner(text(web)) == PORTAL_OWNER_PENDING);
    /* Emacs is slow to acknowledge: everything typed meanwhile waits. */
    press('x', C);
    press('b', 0);
    CHECK(went("held C-x, held b"));
    portal_fake_run();
    CHECK(went(""));
    CHECK(act(web, "ack", serial));
    CHECK(!act(web, "ack", serial));
    portal_fake_run();
    CHECK(went("emacs C-x, emacs b"));
    CHECK(act(web, "command", serial));
    CHECK(act(web, "pending", serial));
    press('y', 0);
    CHECK(went("emacs y"));
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(act(web, "finish", serial));
    CHECK(portal_fake_calls().discarded == before.discarded + 1);
    CHECK(!act(web, "pending", 0));
    /* Emacs gives the view the keyboard back. */
    CHECK(act(web, "focus", 0));
    CHECK(portal_input_owner(text(web)) == PORTAL_OWNER_VIEW);
    press('z', 0);
    CHECK(went("%s z", web));
    CHECK(sent(""));
    close_view(web);
}

static void test_the_trigger_again_goes_to_the_app(void)
{
    char *web = open_view("web", false);
    /* Typed faster than Emacs acknowledges: the prefix, repeated, then the
       key held down. */
    press('b', C);
    press('b', C);
    repeat('b', C);
    press('x', 0);
    CHECK(went("held C-b, held C-b, held C-b repeat, held x"));
    int64_t serial = handoff("prefix", web);
    CHECK(act(web, "ack", serial));
    portal_fake_run();
    /* Only the first key of the sequence, and only its press, is literal. */
    CHECK(went("taken C-b, taken C-b repeat, emacs x"));
    CHECK(sent("literal %s %" PRId64 " 0\n", web, serial));
    CHECK(act(web, "command", serial));
    CHECK(act(web, "literal", serial));
    CHECK(went("literal C-b"));
    CHECK(act(web, "focused", 0));
    CHECK(act(web, "pending", serial)); /* Emacs's own focus is no abandonment. */
    CHECK(act(web, "finish", serial));
    /* A key of the sequence after the first is Emacs's, even the trigger,
       as in C-b C-x C-b. */
    press('b', C);
    serial = handoff("prefix", web);
    CHECK(act(web, "ack", serial));
    press('x', C);
    press('b', C);
    CHECK(went("held C-b, emacs C-x, emacs C-b"));
    CHECK(act(web, "finish", serial));
    /* Without a trigger, there is nothing to send. */
    portal_text error = {0};
    bool result;
    CHECK(!portal_input_perform(text(web), text("literal"), 0, &result, &error));
    CHECK(error.data && !strcmp(error.data, "No captured prefix key to send"));
    free(error.data);
    CHECK(sent(""));
    close_view(web);
}

static void test_cancelling_a_handoff(void)
{
    char *web = open_view("web", false);
    /* C-g while Emacs reads. */
    press('b', C);
    int64_t serial = handoff("prefix", web);
    CHECK(act(web, "ack", serial));
    press('g', C);
    repeat('g', C);
    CHECK(went("held C-b, taken C-g, taken C-g repeat"));
    CHECK(sent("cancel %s %" PRId64 " 0\n", web, serial));
    CHECK(act(web, "finish", serial));

    /* Command-Escape, before Emacs acknowledges: what the view held is
       dropped, and a late acknowledgement does nothing. */
    CHECK(act(web, "focus", 0));
    press('b', C);
    press('x', 0);
    serial = handoff("prefix", web);
    portal_fake_escape();
    CHECK(sent("escape %s %" PRId64 " 0\n", web, serial));
    CHECK(!act(web, "pending", 0));
    CHECK(!act(web, "ack", serial));
    portal_fake_run();
    press('y', 0);
    CHECK(went("held C-b, held x, emacs y"));

    /* Command-Escape while the view has the keyboard only returns it. */
    CHECK(act(web, "focus", 0));
    portal_fake_escape();
    CHECK(!act(web, "focused", 0));
    CHECK(sent(""));

    /* Emacs's unfocus ends a handoff silently: Emacs asked for it. */
    CHECK(act(web, "focus", 0));
    press('b', C);
    serial = handoff("prefix", web);
    CHECK(act(web, "ack", serial));
    CHECK(act(web, "unfocus", 0));
    CHECK(!act(web, "pending", serial));
    CHECK(!act(web, "finish", serial));
    press('b', C);
    CHECK(went("held C-b, emacs C-b"));
    CHECK(sent(""));
    close_view(web);
}

static void test_a_click_abandons_a_handoff_first(void)
{
    char *web = open_view("web", false);
    press('b', C);
    int64_t serial = handoff("prefix", web);
    CHECK(act(web, "ack", serial));
    /* Emacs reads the escape before the select, so it does not read the
       select as the next key. */
    CHECK(portal_fake_click(web));
    CHECK(sent("escape %s %" PRId64 " 0\nselect %s\n", web, serial, web));
    CHECK(act(web, "focused", 0));
    CHECK(!act(web, "finish", serial));
    press('x', 0);
    CHECK(went("held C-b, %s x", web));
    /* A click in the view that has the keyboard selects nothing. */
    CHECK(portal_fake_click(web));
    CHECK(sent(""));
    close_view(web);
}

static void test_emacs_moving_the_keyboard_keeps_the_handoff(void)
{
    char *web = open_view("web", false);
    char *other = open_view("web", false);
    press('b', C);
    int64_t serial = handoff("prefix", other);
    CHECK(act(other, "ack", serial));
    CHECK(act(other, "command", serial));
    /* The command gives views the keyboard, as C-b s-f and C-b o do. */
    portal_input_request(true);
    CHECK(act(web, "focus", 0));
    portal_input_focus(text(other), true);
    portal_input_request(false);
    CHECK(act(other, "pending", serial));
    CHECK(act(other, "finish", serial));
    CHECK(sent(""));
    /* The same report from the user abandons it. */
    CHECK(act(other, "focus", 0));
    press('b', C);
    serial = handoff("prefix", other);
    portal_input_focus(text(other), true);
    CHECK(sent("escape %s %" PRId64 " 0\n", other, serial));
    CHECK(went("held C-b, held C-b"));
    close_view(other);
    close_view(web);
}

static void test_serials_name_one_handoff(void)
{
    char *web = open_view("web", false);
    char *other = open_view("web", false);
    press('b', C);
    int64_t first = handoff("prefix", other);
    CHECK(act(other, "ack", first));
    CHECK(act(other, "finish", first));
    CHECK(act(other, "focus", 0));
    press('b', C);
    int64_t second = handoff("prefix", other);
    CHECK(second != first);
    /* A finished handoff's serial, or another view's, does nothing. */
    struct portal_fake_calls before = portal_fake_calls();
    const char *actions[] = {"pending", "ack", "command", "finish", "literal", "focus",
                             "unfocus", "passthrough", "unknown"};
    for (size_t i = 0; i < sizeof actions / sizeof *actions; i++) {
        CHECK(!act(other, actions[i], first));
        CHECK(!act(web, actions[i], second));
    }
    CHECK(same_calls(portal_fake_calls(), before));
    CHECK(act(other, "pending", second));
    CHECK(act(other, "finish", second));
    CHECK(!act(other, "finish", second));
    /* A target that names no view does nothing, whatever the action. */
    CHECK(!act("web:0", "unknown", 0));
    bool result = true;
    portal_text error = {0};
    CHECK(!portal_input_perform(text(web), text("unknown"), 0, &result, &error));
    CHECK(error.data && !strcmp(error.data, "Unknown Portal input action: unknown"));
    free(error.data);
    CHECK(went("held C-b, held C-b"));
    close_view(other);
    close_view(web);
}

static void test_hiding_or_closing_ends_a_handoff(void)
{
    char *web = open_view("web", false);
    press('b', C);
    int64_t serial = handoff("prefix", web);
    CHECK(act(web, "ack", serial));
    press('x', 0);
    struct portal_fake_calls before = portal_fake_calls();
    portal_text error = {0};
    CHECK(portal_views_hide(text(web), &error));
    CHECK(portal_fake_calls().discarded == before.discarded + 1);
    CHECK(!act(web, "pending", 0));
    CHECK(!act(web, "finish", serial));
    /* A hidden view cannot have the keyboard. */
    CHECK(!act(web, "focus", 0));
    CHECK(sent(""));
    CHECK(portal_views_place(text(web), (portal_edges) {0, 0, 100, 100}, text("frame"), &error));
    CHECK(act(web, "focus", 0));

    /* Closing before Emacs acknowledges: the late acknowledgement and
       completion reach no view, and no later view takes the serial. */
    press('b', C);
    press('y', 0);
    serial = handoff("prefix", web);
    char *closed = strdup(web);
    close_view(web);
    CHECK(!act(closed, "ack", serial));
    CHECK(!act(closed, "finish", serial));
    char *next = open_view("web", false);
    CHECK(!act(next, "ack", serial));
    press('y', 0);
    CHECK(went("held C-b, emacs x, held C-b, held y, %s y", next));
    CHECK(sent(""));
    free(closed);
    close_view(next);
}

static void test_passthrough_gives_the_app_every_key(void)
{
    char *web = open_view("web", false);
    CHECK(act(web, "passthrough", 0));
    CHECK(act(web, "passthrough-p", 0));
    CHECK(portal_input_owner(text(web)) == PORTAL_OWNER_PASSTHROUGH);
    press('b', C);
    press('g', C);
    CHECK(went("%s C-b, %s C-g", web, web));
    /* Until the view loses the keyboard. */
    portal_fake_escape();
    CHECK(!act(web, "passthrough-p", 0));
    CHECK(portal_input_owner(text(web)) == PORTAL_OWNER_EMACS);
    CHECK(act(web, "focus", 0));
    press('b', C);
    CHECK(went("held C-b"));
    int64_t serial = handoff("prefix", web);
    /* M-x portal-input-passthrough, run from the prefix. */
    CHECK(act(web, "ack", serial));
    CHECK(act(web, "command", serial));
    CHECK(act(web, "passthrough", 0));
    CHECK(act(web, "finish", serial));
    CHECK(act(web, "passthrough-p", 0));
    press('b', C);
    CHECK(went("%s C-b", web));
    /* Emacs's focus ends it, and so does another view taking the keyboard. */
    CHECK(act(web, "focus", 0));
    CHECK(!act(web, "passthrough-p", 0));
    char *other = open_view("web", false);
    CHECK(act(web, "passthrough", 0));
    CHECK(act(other, "focus", 0));
    CHECK(!act(web, "passthrough-p", 0));
    /* A view Emacs cannot focus is not in passthrough. */
    portal_text error = {0};
    CHECK(portal_views_hide(text(web), &error));
    CHECK(!act(web, "passthrough", 0));
    CHECK(!act(web, "passthrough-p", 0));
    CHECK(sent(""));
    close_view(other);
    close_view(web);
}

static bool bindings(const portal_binding *regular, size_t regular_count,
                     const portal_binding *quick, size_t quick_count, const char *failure)
{
    portal_text error = {0};
    bool done = portal_input_bindings(regular, regular_count, quick, quick_count, &error);
    bool expected = failure ? !done && error.data && !strcmp(error.data, failure) : done;
    if (!expected)
        fprintf(stderr, "Expected %s, got %s\n", failure ? failure : "success",
                error.data ? error.data : "success");
    free(error.data);
    return expected;
}

static bool prefix(portal_chord chord, const char *failure)
{
    portal_text error = {0};
    bool done = portal_input_prefix(chord, &error);
    bool expected = failure ? !done && error.data && !strcmp(error.data, failure) : done;
    if (!expected)
        fprintf(stderr, "Expected %s, got %s\n", failure ? failure : "success",
                error.data ? error.data : "success");
    free(error.data);
    return expected;
}

static int64_t binding(const char *target)
{
    int64_t event = 0, serial = handoff_key("binding", target, &event);
    CHECK(act(target, "finish", serial));
    CHECK(act(target, "focus", 0));
    return event;
}

static void test_native_bindings_by_profile(void)
{
    const portal_binding regular[] = {{{'j', S}, 100}, {{'!', S}, 101}, {{'J', S | SHIFT}, 102}};
    const portal_binding quick[] = {{{'`', S}, 200}, {{'j', S}, 100}};
    CHECK(bindings(regular, 3, quick, 2, NULL));
    char *terminal = open_view("terminal", false);
    press('`', S);
    CHECK(went("%s s-`", terminal));
    /* Shift that made the punctuation is no modifier; on a letter it is. */
    press('!', S | SHIFT);
    CHECK(went("held s-S-!"));
    int64_t event, serial = handoff_key("binding", terminal, &event);
    CHECK(event == 101);
    CHECK(act(terminal, "ack", serial));
    press('!', S | SHIFT);
    CHECK(went("taken s-S-!"));
    CHECK(sent("literal %s %" PRId64 " 0\n", terminal, serial));
    CHECK(act(terminal, "finish", serial));
    CHECK(act(terminal, "focus", 0));
    press('J', S | SHIFT);
    CHECK(binding(terminal) == 102);
    press('j', S);
    CHECK(binding(terminal) == 100);
    press('J', S);
    CHECK(binding(terminal) == 100);
    CHECK(went("held s-S-J, held s-j, held s-J"));
    close_view(terminal);

    char *quick_terminal = open_view("terminal", true);
    press('`', S);
    CHECK(binding(quick_terminal) == 200);
    press('j', S);
    CHECK(binding(quick_terminal) == 100);
    close_view(quick_terminal);
    char *web = open_view("web", false);
    press('j', S);
    press('j', 0);
    CHECK(went("held s-`, held s-j, %s s-j, %s j", web, web));
    close_view(web);
    CHECK(bindings(NULL, 0, NULL, 0, NULL));
}

static void test_configuration_changes_atomically(void)
{
    const portal_binding working[] = {{{'j', S}, 100}};
    CHECK(bindings(working, 1, working, 1, NULL));
    /* Invalid or conflicting bindings, in either profile, change nothing. */
    const portal_binding invalid[][1] = {
        {{{'a', 0}, 1}},          {{{'!', SHIFT}, 1}},  {{{0x7f, C}, 1}}, {{{0xe9, C}, 1}},
        {{{'a', C | 16}, 1}},     {{{'a', C}, 0}},      {{{'a', C}, -1}}, {{{0, C}, 1}},
    };
    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; i++) {
        CHECK(bindings(invalid[i], 1, NULL, 0, "Invalid native terminal binding"));
        CHECK(bindings(working, 1, invalid[i], 1, "Invalid native terminal binding"));
    }
    const portal_binding prefix_binding[] = {{{'B', C}, 1}};
    const portal_binding duplicate[] = {{{'k', S}, 1}, {{'K', S}, 2}};
    CHECK(bindings(prefix_binding, 1, NULL, 0, "Conflicting native terminal binding"));
    CHECK(bindings(working, 1, duplicate, 2, "Conflicting native terminal binding"));
    /* A prefix that is a binding's chord, or not one modified ASCII
       character, changes nothing either. */
    CHECK(prefix((portal_chord) {'J', S}, "Portal prefix conflicts with a native binding"));
    const portal_chord bad[] = {{'a', 0}, {'!', SHIFT}, {0x7f, C}, {'a', 16}, {0, C}, {0x3bb, C}};
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++)
        CHECK(prefix(bad[i], "Expected one modified ASCII prefix"));
    char *terminal = open_view("terminal", false);
    press('b', C);
    CHECK(act(terminal, "finish", handoff("prefix", terminal)));
    CHECK(act(terminal, "focus", 0));
    press('j', S);
    CHECK(act(terminal, "finish", handoff("binding", terminal)));
    CHECK(act(terminal, "focus", 0));
    /* A new prefix takes over at once. */
    CHECK(prefix((portal_chord) {'a', C}, NULL));
    press('b', C);
    press('A', C | SHIFT);
    CHECK(went("held C-b, held s-j, %s C-b, %s C-S-A", terminal, terminal));
    press('a', C);
    CHECK(went("held C-a"));
    CHECK(act(terminal, "finish", handoff("prefix", terminal)));
    CHECK(prefix((portal_chord) {'b', C}, NULL));
    CHECK(bindings(NULL, 0, NULL, 0, NULL));
    close_view(terminal);
}

static void test_a_held_prefix_takes_one_handoff(void)
{
    char *web = open_view("web", false);
    /* The prefix's own repeats, before and after it starts a handoff. */
    repeat('b', C);
    CHECK(went("taken C-b repeat"));
    CHECK(sent(""));
    press('b', C);
    repeat('b', C);
    int64_t serial = handoff("prefix", web);
    CHECK(act(web, "ack", serial));
    portal_fake_run();
    CHECK(went("held C-b, held C-b repeat, taken C-b repeat"));
    CHECK(sent(""));
    CHECK(act(web, "finish", serial));
    close_view(web);
}

int main(void)
{
    int fds[2];
    if (pipe(fds) || fcntl(fds[0], F_SETFL, O_NONBLOCK) == -1 || !portal_channel_connect(fds[1]))
        abort();
    records = fds[0];
    test_a_handoff_from_the_prefix_to_the_command();
    test_the_trigger_again_goes_to_the_app();
    test_cancelling_a_handoff();
    test_a_click_abandons_a_handoff_first();
    test_emacs_moving_the_keyboard_keeps_the_handoff();
    test_serials_name_one_handoff();
    test_hiding_or_closing_ends_a_handoff();
    test_passthrough_gives_the_app_every_key();
    test_native_bindings_by_profile();
    test_configuration_changes_atomically();
    test_a_held_prefix_takes_one_handoff();
    CHECK(!portal_fake_calls().misused);
    if (failures) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    puts("Input handoff passed");
    return 0;
}
