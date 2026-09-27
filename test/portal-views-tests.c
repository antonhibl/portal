/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The core's view registry, native/Core/views.c, with the fake platform.
   These check what the core owns: targets, kinds, the placement it keeps,
   and that no platform view is used outside its life.  The fake counts every
   primitive the core calls, and any call naming a destroyed view.  Where a
   view goes when detached is the platform's business, so these only check
   that the core keeps the same platform view throughout. */
#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "channel.h"
#include "portal-fake-backend.h"
#include "portal.h"
#include "views.h"

static int failures;

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

/* Whether ERROR says MESSAGE, which may hold LENGTH bytes including NULs;
   free it. */
static bool said(portal_text *error, const char *message, size_t length)
{
    bool same = error->data && error->length == length && !memcmp(error->data, message, length);
    if (!same)
        fprintf(stderr, "Expected error \"%.*s\", got \"%s\"\n", (int) length, message,
                error->data ? error->data : "(none)");
    free(error->data);
    *error = (portal_text) {0};
    return same;
}

static bool says(portal_text *error, const char *message)
{
    return said(error, message, strlen(message));
}

/* Open a view of KIND with the string options NAME, VALUE, ...; return its
   target to free, or NULL with *ERROR set. */
static char *open_view(const char *kind, portal_text *error, ...)
{
    portal_option options[4];
    size_t count = 0;
    va_list arguments;
    va_start(arguments, error);
    for (const char *name; (name = va_arg(arguments, const char *));) {
        const char *value = va_arg(arguments, const char *);
        options[count++] = (portal_option) {.name = text(name), .is_string = true,
                                            .string = text(value)};
    }
    va_end(arguments);
    portal_text target = {0};
    if (!portal_views_open(text(kind), options, count, &target, error))
        return NULL;
    return target.data;
}

/* TARGET's state as JSON, to free. */
static char *inspect(const char *target)
{
    portal_text state = {0}, error = {0};
    if (!portal_views_inspect(text(target), &state, &error)) {
        fprintf(stderr, "Inspecting %s failed: %s\n", target, error.data);
        free(error.data);
        return NULL;
    }
    return state.data;
}

/* Whether TARGET's state contains each of the NULL-terminated fragments. */
static bool shows(const char *target, ...)
{
    char *state = inspect(target);
    bool all = state != NULL;
    va_list arguments;
    va_start(arguments, target);
    for (const char *fragment; all && (fragment = va_arg(arguments, const char *));)
        if (!strstr(state, fragment)) {
            fprintf(stderr, "Expected %s in %s\n", fragment, state);
            all = false;
        }
    va_end(arguments);
    free(state);
    return all;
}

static bool place(const char *target, portal_edges edges, const char *frame,
                  portal_text *error)
{
    return portal_views_place(text(target), edges, text(frame), error);
}

static bool same_calls(struct portal_fake_calls a, struct portal_fake_calls b)
{
    return !memcmp(&a, &b, sizeof a);
}

static void close_view(char *target)
{
    portal_text error = {0};
    CHECK(portal_views_close(text(target), &error));
    free(target);
}

/* A view's ID, from its target. */
static long id(const char *target)
{
    return strtol(strchr(target, ':') + 1, NULL, 10);
}

static void test_targets_are_never_reused(void)
{
    portal_text error = {0};
    char *web = open_view("web", &error, NULL);
    char *terminal = open_view("terminal", &error, NULL);
    CHECK(web && !strncmp(web, "web:", 4));
    CHECK(terminal && !strncmp(terminal, "terminal:", 9));
    /* IDs are global across kinds. */
    CHECK(id(terminal) == id(web) + 1);
    CHECK(shows(web, "{\"id\":", "\"kind\":\"web\",\"visible\":false,\"edges\":[],\"handle\":",
                NULL));
    CHECK(shows(terminal, "\"kind\":\"terminal\"", NULL));
    long last = id(terminal);
    close_view(terminal);

    /* A failed open registers nothing, yet its ID is spent. */
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(!open_view("terminal", &error, "fail", "No shell", NULL));
    CHECK(says(&error, "No shell"));
    CHECK(!open_view("window", &error, NULL));
    CHECK(says(&error, "Unknown Portal view kind: window"));
    CHECK(same_calls(portal_fake_calls(), before));
    char failed[32];
    snprintf(failed, sizeof failed, "terminal:%ld", last + 1);
    CHECK(shows(failed, "null", NULL));
    CHECK(!portal_notify(text("select"), text(failed), NULL, 0));

    /* Neither a closed nor a failed view's ID comes back. */
    char *next = open_view("terminal", &error, NULL);
    CHECK(next && id(next) == last + 2);
    close_view(next);
    close_view(web);
    CHECK(!portal_fake_calls().misused);
}

static void test_invalid_targets_reach_no_view(void)
{
    portal_text error = {0};
    char *web = open_view("web", &error, NULL);
    char absent[32];
    snprintf(absent, sizeof absent, "web:%ld", id(web) + 1000);
    const char *targets[] = {"", "web", "web:", absent, "Web:1", "1", "web:01"};
    struct portal_fake_calls before = portal_fake_calls();
    for (size_t i = 0; i < sizeof targets / sizeof *targets; i++) {
        char message[64];
        snprintf(message, sizeof message, "No Portal view %s", targets[i]);
        CHECK(!place(targets[i], (portal_edges) {0, 0, 10, 10}, "frame", &error));
        CHECK(says(&error, message));
        CHECK(!portal_views_hide(text(targets[i]), &error));
        CHECK(says(&error, message));
        CHECK(!portal_views_close(text(targets[i]), &error));
        CHECK(says(&error, message));
        CHECK(shows(targets[i], "null", NULL));
        CHECK(!portal_views_find(text(targets[i]), PORTAL_ANY_KIND, NULL));
    }
    /* A target matches in full, NUL bytes and all. */
    char nul[40];
    size_t length = strlen(web);
    memcpy(nul, web, length + 1);
    portal_string with_nul = {nul, length + 1};
    CHECK(!portal_views_hide(with_nul, &error));
    char message[64] = "No Portal view ";
    memcpy(message + 15, nul, length + 1);
    CHECK(said(&error, message, 15 + length + 1));
    CHECK(same_calls(portal_fake_calls(), before));
    close_view(web);
}

static void test_operations_check_the_kind(void)
{
    portal_text error = {0};
    char *web = open_view("web", &error, NULL);
    char *terminal = open_view("terminal", &error, NULL);
    char message[64];
    snprintf(message, sizeof message, "No Portal view %s", web);
    CHECK(!portal_views_find(text(web), PORTAL_TERMINAL, &error));
    CHECK(says(&error, message));
    CHECK(!portal_views_find(text(terminal), PORTAL_WEB, NULL));
    CHECK(portal_views_find(text(web), PORTAL_WEB, NULL));
    CHECK(portal_views_find(text(web), PORTAL_ANY_KIND, NULL)
          == portal_views_find(text(web), PORTAL_WEB, NULL));

    /* Themes reach every terminal, and only terminals. */
    portal_string beta = text("Beta"), gamma = text("Gamma");
    CHECK(portal_views_terminal_theme(&beta, &error));
    CHECK(shows(terminal, "\"theme\":\"Beta\"", NULL));
    char *state = inspect(web);
    CHECK(state && !strstr(state, "\"theme\":\"Beta\","));
    free(state);
    CHECK(!portal_views_terminal_theme(&gamma, &error));
    CHECK(says(&error, "Unknown terminal theme: Gamma"));
    CHECK(shows(terminal, "\"theme\":\"Beta\"", NULL));
    close_view(web);
    close_view(terminal);
    CHECK(!portal_fake_calls().misused);
}

static void test_the_registry_survives_closes_in_any_order(void)
{
    portal_text error = {0};
    char *first = open_view("terminal", &error, NULL);
    char *second = open_view("terminal", &error, NULL);
    char *third = open_view("terminal", &error, NULL);
    close_view(second);
    close_view(third);
    char *fourth = open_view("terminal", &error, NULL);
    portal_string alpha = text("Alpha");
    CHECK(portal_views_terminal_theme(&alpha, &error));
    CHECK(shows(first, "\"theme\":\"Alpha\"", NULL));
    CHECK(shows(fourth, "\"theme\":\"Alpha\"", NULL));
    close_view(first);
    close_view(fourth);
    char *fifth = open_view("terminal", &error, NULL);
    CHECK(fifth && portal_views_find(text(fifth), PORTAL_TERMINAL, NULL));
    close_view(fifth);
    CHECK(!portal_fake_calls().misused);
}

static void test_invalid_rectangles_change_nothing(void)
{
    portal_text error = {0};
    char *web = open_view("web", &error, NULL);
    CHECK(place(web, (portal_edges) {10, 20, 110, 220}, "one", &error));
    struct portal_fake_calls before = portal_fake_calls();
    const portal_edges empty[] = {{10, 20, 10, 220}, {10, 20, 110, 20}, {10, 20, 5, 220},
                                  {10, 20, 110, -5}, {INT64_MIN, 0, INT64_MAX, 10}};
    for (size_t i = 0; i < sizeof empty / sizeof *empty; i++) {
        CHECK(!place(web, empty[i], "two", &error));
        CHECK(says(&error, i < 4 ? "Expected [LEFT TOP RIGHT BOTTOM] with positive dimensions"
                                 : "Pane edges must fit in 32 bits"));
    }
    CHECK(!place(web, (portal_edges) {0, 0, (int64_t) INT32_MAX + 1, 10}, "two", &error));
    CHECK(says(&error, "Pane edges must fit in 32 bits"));
    CHECK(same_calls(portal_fake_calls(), before));
    CHECK(shows(web, "\"visible\":true,\"edges\":[10,20,110,220]", "\"frame\":\"one\"", NULL));
    /* The extremes that fit are fine. */
    CHECK(place(web, (portal_edges) {INT32_MIN, INT32_MIN, INT32_MAX, INT32_MAX}, "two",
                &error));
    close_view(web);
}

static void test_placing_and_hiding_again(void)
{
    portal_text error = {0};
    char *web = open_view("web", &error, NULL);
    struct portal_fake_calls before = portal_fake_calls();
    /* Hiding a view that was never placed has nothing to detach. */
    CHECK(portal_views_hide(text(web), &error));
    CHECK(portal_fake_calls().detached == before.detached);
    portal_view *handle = portal_views_find(text(web), PORTAL_ANY_KIND, NULL);
    /* The same edges in another frame still move the view, so each place
       attaches. */
    CHECK(place(web, (portal_edges) {0, 0, 100, 100}, "one", &error));
    CHECK(place(web, (portal_edges) {0, 0, 100, 100}, "one", &error));
    CHECK(place(web, (portal_edges) {0, 0, 100, 100}, "two", &error));
    CHECK(portal_fake_calls().attached == before.attached + 3);
    CHECK(shows(web, "\"visible\":true,\"edges\":[0,0,100,100]", "\"frame\":\"two\"",
                "\"attached\":true", NULL));
    CHECK(portal_views_hide(text(web), &error));
    CHECK(portal_views_hide(text(web), &error));
    CHECK(portal_fake_calls().detached == before.detached + 1);
    CHECK(shows(web, "\"visible\":false,\"edges\":[]", "\"attached\":false", NULL));
    CHECK(portal_views_find(text(web), PORTAL_ANY_KIND, NULL) == handle);
    CHECK(portal_fake_calls().created == before.created);
    close_view(web);
}

static void test_a_failed_placement_changes_nothing(void)
{
    portal_text error = {0};
    char *web = open_view("web", &error, NULL);
    /* Detached, it stays detached. */
    CHECK(!place(web, (portal_edges) {0, 0, 100, 100}, "deleted frame", &error));
    CHECK(says(&error, "Cannot find the requested native Emacs frame"));
    CHECK(shows(web, "\"visible\":false,\"edges\":[]", "\"attached\":false", NULL));
    /* Attached, it stays where it was, and hiding still detaches it. */
    CHECK(place(web, (portal_edges) {10, 10, 50, 50}, "one", &error));
    CHECK(!place(web, (portal_edges) {0, 0, 100, 100}, "deleted frame", &error));
    CHECK(says(&error, "Cannot find the requested native Emacs frame"));
    CHECK(shows(web, "\"visible\":true,\"edges\":[10,10,50,50]", "\"frame\":\"one\"", NULL));
    size_t detached = portal_fake_calls().detached;
    CHECK(portal_views_hide(text(web), &error));
    CHECK(portal_fake_calls().detached == detached + 1);
    /* The core still owns it, and closing destroys it once. */
    size_t destroyed = portal_fake_calls().destroyed;
    close_view(web);
    CHECK(portal_fake_calls().destroyed == destroyed + 1);
}

static void test_hiding_keeps_the_session_and_its_size(void)
{
    portal_text error = {0};
    char *terminal = open_view("terminal", &error, NULL);
    portal_view *handle = portal_views_find(text(terminal), PORTAL_TERMINAL, NULL);
    size_t created = portal_fake_calls().created;
    CHECK(portal_terminal_paste(handle, text("echo kept"), true, &error));
    CHECK(place(terminal, (portal_edges) {0, 0, 800, 600}, "one", &error));
    CHECK(portal_views_hide(text(terminal), &error));
    CHECK(shows(terminal, "\"visible\":false", "\"size\":[800,600]", "\"text\":\"echo kept\\u000a\"",
                NULL));
    /* Placing it elsewhere moves the same platform view. */
    CHECK(place(terminal, (portal_edges) {10, 10, 410, 310}, "two", &error));
    CHECK(portal_views_find(text(terminal), PORTAL_TERMINAL, NULL) == handle);
    CHECK(portal_fake_calls().created == created);
    CHECK(shows(terminal, "\"size\":[400,300]", "\"text\":\"echo kept\\u000a\"", NULL));
    close_view(terminal);
}

static void test_a_refusing_platform_changes_nothing(void)
{
    portal_text error = {0};
    char *first = open_view("web", &error, NULL);
    char *web = open_view("web", &error, NULL);
    char *last = open_view("web", &error, NULL);
    CHECK(place(web, (portal_edges) {0, 0, 100, 100}, "one", &error));
    portal_fake_refuse(true);
    CHECK(!open_view("web", &error, NULL));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    CHECK(!portal_views_hide(text(web), &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    CHECK(!portal_views_close(text(web), &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    /* A refused close keeps the view open, in its place in the registry. */
    CHECK(!portal_views_close(text(last), &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    CHECK(shows(web, "\"visible\":true", "\"attached\":true", NULL));
    CHECK(portal_views_find(text(first), PORTAL_WEB, NULL));
    CHECK(portal_views_find(text(last), PORTAL_WEB, NULL));
    size_t destroyed = portal_fake_calls().destroyed;
    close_view(web);
    close_view(last);
    char *next = open_view("web", &error, NULL);
    CHECK(next && portal_views_find(text(next), PORTAL_WEB, NULL));
    CHECK(portal_fake_calls().destroyed == destroyed + 2);
    close_view(next);
    close_view(first);
    CHECK(!portal_fake_calls().misused);
}

/* Everything the pipe holds now, valid until the next call. */
static char *drain(int fd)
{
    static char buffer[4096];
    ssize_t count = read(fd, buffer, sizeof buffer - 1);
    buffer[count > 0 ? count : 0] = '\0';
    return buffer;
}

static void test_closing_ends_the_view_once(void)
{
    int fds[2];
    if (pipe(fds) || fcntl(fds[0], F_SETFL, O_NONBLOCK) == -1)
        abort();
    CHECK(portal_channel_connect(fds[1]));
    portal_text error = {0}, state = {0};
    char *web = open_view("web", &error, "hosted", "yes", NULL);
    portal_view *handle = portal_views_find(text(web), PORTAL_WEB, NULL);
    CHECK(place(web, (portal_edges) {0, 0, 100, 100}, "one", &error));
    /* The platform's records reach Emacs while the view is open. */
    CHECK(portal_web_send(handle, text("{}"), &error));
    char record[64];
    snprintf(record, sizeof record, "bridge %s\n", web);
    CHECK(!strcmp(drain(fds[0]), record));

    struct portal_fake_calls before = portal_fake_calls();
    char *target = strdup(web);
    close_view(web);
    CHECK(portal_fake_calls().destroyed == before.destroyed + 1);
    /* Closed views are not detached first: destroying ends them wherever
       they are. */
    CHECK(portal_fake_calls().detached == before.detached);
    before = portal_fake_calls();
    char message[64];
    snprintf(message, sizeof message, "No Portal view %s", target);
    CHECK(!portal_views_close(text(target), &error));
    CHECK(says(&error, message));
    CHECK(!place(target, (portal_edges) {0, 0, 100, 100}, "one", &error));
    CHECK(says(&error, message));
    CHECK(!portal_views_hide(text(target), &error));
    CHECK(says(&error, message));
    CHECK(portal_views_inspect(text(target), &state, &error));
    CHECK(!strcmp(state.data, "null"));
    free(state.data);
    CHECK(!portal_views_find(text(target), PORTAL_WEB, NULL));
    CHECK(same_calls(portal_fake_calls(), before));
    /* A late record from the platform, for the closed view, never reaches
       Emacs; it could not reach another view either, since no target is
       reused. */
    CHECK(!portal_notify(text("bridge"), text(target), NULL, 0));
    CHECK(!strcmp(drain(fds[0]), ""));
    CHECK(!portal_fake_calls().misused);
    free(target);
    portal_channel_connect(-1);
    close(fds[0]);
}

int main(void)
{
    test_targets_are_never_reused();
    test_invalid_targets_reach_no_view();
    test_operations_check_the_kind();
    test_the_registry_survives_closes_in_any_order();
    test_invalid_rectangles_change_nothing();
    test_placing_and_hiding_again();
    test_a_failed_placement_changes_nothing();
    test_hiding_keeps_the_session_and_its_size();
    test_a_refusing_platform_changes_nothing();
    test_closing_ends_the_view_once();
    CHECK(!portal_fake_calls().misused);
    if (failures) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    puts("The view registry passed");
    return 0;
}
