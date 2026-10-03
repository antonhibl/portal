/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The raw Darwin argument area is otherwise hard to induce safely in a process. */
#include "../native/Processes/Processes.c"
#include <assert.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <util.h>

static pid_t spawn_pty(const char *program, const char *mode, int *master)
{
    pid_t pid = forkpty(master, NULL, NULL, NULL);
    assert(pid >= 0);
    if (!pid) {
        setenv("PORTAL_TEST_TTY_MARKER", "inherited", 1);
        execl(program, program, mode, NULL);
        _exit(127);
    }
    return pid;
}

static bool has_tty_parent(const char *json, pid_t pid, pid_t parent)
{
    char key[64], value[64];
    snprintf(key, sizeof key, "{\"pid\":%d,", pid);
    snprintf(value, sizeof value, "\"tty-parent\":%d,", parent);
    const char *object = strstr(json, key);
    if (!object) return false;
    const char *field = strstr(object, value);
    return field && field < strchr(object, '}');
}

static void real_tty_ownership(const char *program)
{
    int master;
    pid_t direct = spawn_pty(program, "--nested", &master);
    struct pollfd ready = {master, POLLIN, 0};
    assert(poll(&ready, 1, 5000) > 0);
    char line[32] = {0};
    assert(read(master, line, sizeof line - 1) > 0);
    pid_t nested = (pid_t) strtol(line, NULL, 10);
    assert(nested > 1);
    bool verified = false;
    /* Both PTYs inherit the same marker; only the original belongs to us.
       Retry until the inner child has finished exec and acquired its TTY. */
    for (int attempt = 0; attempt < 100 && !verified; attempt++) {
        portal_text result = {0}, error = {0};
        assert(portal_process_snapshot((portal_string) {"PORTAL_TEST_TTY_MARKER", 22}, &result, &error));
        verified = has_tty_parent(result.data, direct, getpid())
                   && has_tty_parent(result.data, nested, direct);
        free(result.data);
        if (!verified) usleep(10000);
    }
    kill(nested, SIGTERM);
    kill(direct, SIGTERM);
    waitpid(direct, NULL, 0);
    close(master);
    assert(verified);
}

static void ancestry_requires_complete_evidence(void)
{
    struct kinfo_proc procs[4] = {0};
    for (int i = 0; i < 4; i++) {
        procs[i].kp_proc.p_pid = i + 10;
        procs[i].kp_eproc.e_ppid = i + 9;
        procs[i].kp_eproc.e_tdev = i ? 7 : NODEV;
        procs[i].kp_eproc.e_ucred.cr_uid = getuid();
    }
    /* Owner -> login -> shell -> agent, including a different-UID parent. */
    procs[1].kp_eproc.e_ucred.cr_uid = 0;
    assert(tty_parent(procs, 4, 3) == 10);
    procs[3].kp_eproc.e_tdev = 8;
    assert(tty_parent(procs, 4, 3) == 12);
    procs[3].kp_eproc.e_tdev = 7;
    procs[1].kp_eproc.e_ppid = 99;
    assert(tty_parent(procs, 4, 3) == 0);
    procs[1].kp_eproc.e_ppid = 13;
    assert(tty_parent(procs, 4, 3) == 0);
    assert(tty_parent(procs, 4, 0) == 0);
}

static void encoded_string_is(const char *input, const char *expected)
{
    char *json = NULL;
    size_t length = 0;
    FILE *out = open_memstream(&json, &length);
    assert(out);
    string(out, input);
    assert(!fclose(out));
    assert(!strcmp(json, expected));
    free(json);
}

int main(int count, char **args)
{
    if (count == 2 && (!strcmp(args[1], "--wait") || !strcmp(args[1], "--nested"))) {
        alarm(30); /* Bound fixture lifetime even if its test fails. */
        if (!strcmp(args[1], "--nested")) {
            int master;
            pid_t pid = spawn_pty(args[0], "--wait", &master);
            printf("%d\n", pid);
            fflush(stdout);
        }
        for (;;) pause();
    }
    if (count == 3 && !strcmp(args[1], "--snapshot")) {
        portal_text result = {0}, error = {0};
        assert(portal_process_snapshot((portal_string) {args[2], strlen(args[2])}, &result, &error));
        puts(result.data);
        free(result.data);
        return 0;
    }
    portal_string variable = {"PORTAL_TERMINAL", 15};
    struct arguments parsed;
    char bytes[256] = {0};
    int argc = 2;
    memcpy(bytes, &argc, sizeof argc);
    const char area[] = "/bin/node\0\0node\0/bin/claude\0\0\0PORTAL_TERMINAL=42/terminal:9\0X=y\0";
    memcpy(bytes + sizeof argc, area, sizeof area);
    assert(parse_arguments(bytes, sizeof argc + sizeof area, variable, &parsed));
    assert(parsed.argc == 2 && !strcmp(parsed.argv, "node"));
    assert(!strcmp(parsed.value, "42/terminal:9"));
    /* Truncations, malformed argc, missing NULs, a marker prefix and no marker. */
    for (size_t n = 0; n < sizeof argc + 24; n++)
        assert(!parse_arguments(bytes, n, variable, &parsed));
    assert(!parse_arguments(bytes, sizeof bytes, (portal_string) {"PORTAL", 6}, &parsed));
    argc = -1; memcpy(bytes, &argc, sizeof argc);
    assert(!parse_arguments(bytes, sizeof bytes, variable, &parsed));
    memset(bytes, 'x', sizeof bytes);
    argc = 1; memcpy(bytes, &argc, sizeof argc);
    assert(!parse_arguments(bytes, sizeof bytes, variable, &parsed));
    /* JSON strings must escape control bytes and quotes in paths and markers. */
    char *json = NULL;
    size_t length = 0;
    FILE *out = open_memstream(&json, &length);
    assert(out);
    string(out, "a\n\"\\é");
    assert(!fclose(out));
    assert(!strcmp(json, "\"a\\u000a\\\"\\\\é\""));
    free(json);
    /* Process strings are arbitrary POSIX bytes. Preserve Unicode, replacing
       each invalid byte without eating adjacent ASCII or valid code points. */
    encoded_string_is("é日本🙂", "\"é日本🙂\"");
    encoded_string_is("before\xff" "after", "\"before\\ufffdafter\"");
    encoded_string_is("\x80\xc0\xaf", "\"\\ufffd\\ufffd\\ufffd\"");
    encoded_string_is("\xe2\x82", "\"\\ufffd\\ufffd\"");
    encoded_string_is("\xe0\x80\x80", "\"\\ufffd\\ufffd\\ufffd\"");
    encoded_string_is("\xf0\x80\x80\x80", "\"\\ufffd\\ufffd\\ufffd\\ufffd\"");
    encoded_string_is("\xed\xa0\x80", "\"\\ufffd\\ufffd\\ufffd\"");
    encoded_string_is("\xf4\x90\x80\x80", "\"\\ufffd\\ufffd\\ufffd\\ufffd\"");
    encoded_string_is("\xe2" "Aé\xff\\\"", "\"\\ufffdAé\\ufffd\\\\\\\"\"");
    encoded_string_is("\xc2\x80\xe0\xa0\x80\xed\x9f\xbf\xf4\x8f\xbf\xbf",
                      "\"\xc2\x80\xe0\xa0\x80\xed\x9f\xbf\xf4\x8f\xbf\xbf\"");
    portal_text result = {0}, error = {0};
    assert(!portal_process_snapshot((portal_string) {"bad=name", 8}, &result, &error));
    free(error.data);
    /* Real snapshot with an absent marker is an empty array, not an error. */
    assert(portal_process_snapshot((portal_string) {"PORTAL_TEST_ABSENT_MARKER", 25}, &result, &error));
    assert(!strcmp(result.data, "[]"));
    free(result.data);
    ancestry_requires_complete_evidence();
    real_tty_ownership(args[0]);
    return 0;
}
