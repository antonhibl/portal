/* SPDX-License-Identifier: GPL-3.0-or-later */
/* macOS process facts, with no agent names or dashboard policy. */
#include "portal.h"
#include <errno.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

/* A bounded C string in the kernel's argument area. */
static char *next(char *p, char *end)
{
    char *zero = memchr(p, 0, (size_t) (end - p));
    return zero ? zero + 1 : NULL;
}

struct arguments {
    char *argv;
    int argc;
    const char *value;
};

static bool parse_arguments(char *bytes, size_t size, portal_string variable,
                            struct arguments *result)
{
    if (size <= sizeof(int)) return false;
    int argc;
    memcpy(&argc, bytes, sizeof argc);
    if (argc < 1 || (size_t) argc > size) return false;
    char *end = bytes + size, *argv = next(bytes + sizeof argc, end);
    if (!argv) return false;
    while (argv < end && !*argv) argv++;
    char *p = argv;
    for (int a = 0; p && a < argc; a++) p = next(p, end);
    if (!p) return false;
    /* Node's process.title leaves NUL padding before the environment. */
    while (p < end && !*p) p++;
    const char *value = NULL;
    while (p < end && *p) {
        char *after = next(p, end);
        if (!after) return false;
        if ((size_t) (after - p) > variable.length + 1
            && !memcmp(p, variable.data, variable.length) && p[variable.length] == '=')
            value = p + variable.length + 1;
        p = after;
    }
    if (!value || !*value) return false;
    *result = (struct arguments) {argv, argc, value};
    return true;
}

/* Length of the next well-formed UTF-8 code point, or zero for invalid input.
   POSIX paths and arguments are bytes, unlike the platform's JSON result. */
static size_t utf8_width(const unsigned char *p, size_t remaining)
{
    size_t width;
    uint32_t code, minimum;
    if (p[0] >= 0xc2 && p[0] <= 0xdf) {
        width = 2; code = p[0] & 0x1f; minimum = 0x80;
    } else if (p[0] >= 0xe0 && p[0] <= 0xef) {
        width = 3; code = p[0] & 0x0f; minimum = 0x800;
    } else if (p[0] >= 0xf0 && p[0] <= 0xf4) {
        width = 4; code = p[0] & 0x07; minimum = 0x10000;
    } else {
        return 0;
    }
    if (remaining < width) return 0;
    for (size_t i = 1; i < width; i++) {
        if ((p[i] & 0xc0) != 0x80) return 0;
        code = (code << 6) | (p[i] & 0x3f);
    }
    if (code < minimum || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff))
        return 0;
    return width;
}

static void string(FILE *out, const char *s)
{
    fputc('"', out);
    const unsigned char *p = (const unsigned char *) s;
    for (size_t remaining = strlen(s); remaining;) {
        size_t width = 1;
        if (*p == '"' || *p == '\\') fprintf(out, "\\%c", *p);
        else if (*p < 32) fprintf(out, "\\u%04x", *p);
        else if (*p < 0x80) fputc(*p, out);
        else {
            width = utf8_width(p, remaining);
            if (width) fwrite(p, 1, width, out);
            else {
                /* Replace each invalid byte; preserve adjacent valid text. */
                fputs("\\ufffd", out);
                width = 1;
            }
        }
        p += width;
        remaining -= width;
    }
    fputc('"', out);
}

static bool failed(portal_text *error, const char *message)
{
    error->data = strdup(message);
    error->length = error->data ? strlen(error->data) : 0;
    return false;
}

/* First ancestor outside this process's controlling TTY.  Zero means that
   incomplete ancestry or a cycle prevents proving where the TTY originates.
   This is an OS fact, not an agent or environment-marker policy. */
static pid_t tty_parent(const struct kinfo_proc *procs, size_t count, size_t index)
{
    dev_t tty = procs[index].kp_eproc.e_tdev;
    if (tty == NODEV) return 0;
    for (size_t depth = 0; depth < count; depth++) {
        pid_t parent = procs[index].kp_eproc.e_ppid;
        size_t above = 0;
        while (above < count && procs[above].kp_proc.p_pid != parent) above++;
        if (above == count) return 0;
        if (procs[above].kp_eproc.e_tdev != tty) return parent;
        index = above;
    }
    return 0;
}

bool portal_process_snapshot(portal_string variable, portal_text *result, portal_text *error)
{
    if (!variable.length || memchr(variable.data, 0, variable.length)
        || memchr(variable.data, '=', variable.length))
        return failed(error, "Expected an environment variable name");
    int argmax = 0, argmib[] = {CTL_KERN, KERN_ARGMAX};
    size_t size = sizeof argmax;
    if (sysctl(argmib, 2, &argmax, &size, NULL, 0) < 0 || argmax <= 0)
        return failed(error, "Cannot read process argument limit");
    /* Ancestry must include other users: macOS login can keep a root-owned
       parent between our terminal shell and Emacs. Read arguments only for
       this user's foreground candidates below. */
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    struct kinfo_proc *procs = NULL;
    size_t length = 0;
    /* Processes can start between sizing and reading. Retry a bounded number. */
    for (int attempt = 0; attempt < 3; attempt++) {
        if (sysctl(mib, 4, NULL, &length, NULL, 0) < 0) break;
        length += length / 4 + sizeof *procs;
        free(procs);
        procs = malloc(length);
        if (!procs) break;
        if (sysctl(mib, 4, procs, &length, NULL, 0) == 0) goto collected;
        if (errno != ENOMEM) break;
    }
    free(procs);
    return failed(error, "Cannot read foreground processes");
collected:;
    char *arguments = malloc((size_t) argmax), *json = NULL;
    size_t json_size = 0;
    FILE *out = open_memstream(&json, &json_size);
    if (!arguments || !out) {
        if (out) fclose(out);
        free(json); free(arguments); free(procs);
        return failed(error, "Cannot allocate process snapshot");
    }
    size_t count = length / sizeof *procs;
    bool comma = false;
    fputc('[', out);
    for (size_t i = 0; i < count; i++) {
        const struct kinfo_proc *k = &procs[i];
        if (k->kp_eproc.e_ucred.cr_uid != getuid()
            || k->kp_eproc.e_tdev == NODEV || k->kp_eproc.e_pgid != k->kp_eproc.e_tpgid
            || k->kp_proc.p_stat == SSTOP || k->kp_proc.p_stat == SZOMB) continue;
        int argsmib[] = {CTL_KERN, KERN_PROCARGS2, k->kp_proc.p_pid};
        size = (size_t) argmax;
        if (sysctl(argsmib, 3, arguments, &size, NULL, 0) < 0 || size <= sizeof(int)) continue;
        struct arguments parsed;
        if (!parse_arguments(arguments, size, variable, &parsed)) continue;
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(k->kp_proc.p_pid, path, sizeof path) <= 0) continue;
        /* Revalidate identity and foreground ownership after reading arguments. */
        struct proc_bsdinfo b;
        if (proc_pidinfo(k->kp_proc.p_pid, PROC_PIDTBSDINFO, 0, &b, sizeof b) != sizeof b
            || b.pbi_start_tvsec != (uint64_t) k->kp_proc.p_starttime.tv_sec
            || b.pbi_start_tvusec != (uint64_t) k->kp_proc.p_starttime.tv_usec
            || b.pbi_ppid != (uint32_t) k->kp_eproc.e_ppid
            || b.e_tdev != (uint32_t) k->kp_eproc.e_tdev
            || b.pbi_status == SSTOP || b.pbi_status == SZOMB
            || b.pbi_pgid != b.e_tpgid || b.e_tdev == (uint32_t) NODEV) continue;
        fprintf(out, "%s{\"pid\":%d,\"start\":\"%llu.%06llu\",\"tty\":%u,\"tty-parent\":%d,\"executable\":",
                comma ? "," : "", k->kp_proc.p_pid, b.pbi_start_tvsec, b.pbi_start_tvusec,
                b.e_tdev, tty_parent(procs, count, i));
        comma = true;
        string(out, path);
        fputs(",\"environment\":", out); string(out, parsed.value);
        fputs(",\"argv\":[", out);
        char *p = parsed.argv;
        for (int a = 0; a < parsed.argc; a++) {
            if (a) fputc(',', out);
            string(out, p);
            p = next(p, arguments + size);
        }
        fputs("],\"ancestors\":[", out);
        pid_t parent = k->kp_eproc.e_ppid;
        for (size_t depth = 0; parent > 1 && depth < count; depth++) {
            if (depth) fputc(',', out);
            fprintf(out, "%d", parent);
            pid_t above = 0;
            for (size_t j = 0; j < count; j++)
                if (procs[j].kp_proc.p_pid == parent) { above = procs[j].kp_eproc.e_ppid; break; }
            if (above == parent) break;
            parent = above;
        }
        fputs("]}", out);
    }
    fputc(']', out);
    bool ok = !ferror(out);
    if (fclose(out) != 0) ok = false;
    free(arguments); free(procs);
    if (!ok) { free(json); return failed(error, "Cannot write process snapshot"); }
    *result = (portal_text) {json, json_size};
    return true;
}
