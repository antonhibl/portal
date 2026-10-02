// Agent discovery spike: list coding agents running in one Emacs's Portal
// terminals.  The reference for the selected identity source; see
// docs/agent-discovery-research.md.  usage: agentscan EMACS_PID
// Build: cc -O2 -o build/agentscan docs/agent-discovery/agentscan.c
//
// An agent is a process named claude, codex or pi whose environment has
// PORTAL_TERMINAL=EMACS_PID/<target>.  The name is the basename of argv[0],
// or of the script a runtime or shell runs (as Herdr names processes), and the
// executable must agree: the agent's own binary, or that runtime.  So
// `exec -a claude sleep` is not Claude, and npm's `node .../bin/claude` is.  Prints one JSON object
// per agent, then {"scan_us":...}.  "fg" is whether its process group owns its
// terminal's foreground; "nested" whether an agent ancestor shares its target.
#include <libproc.h>
#include <sys/sysctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct agent { pid_t pid, ppid, pgid, tpgid; const char *harness; char target[96]; char tty[32];
               unsigned long long start_s, start_us; int nested; };

static char *buf; static int argmax;

static const char *basename_of(const char *path)
{
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

/* Runtimes and shells that run an agent as a script. */
static int runtime(const char *name)
{
    static const char *const names[] = {"node", "bun", "deno", "python", "python3",
                                        "sh", "bash", "zsh", "fish"};
    for (size_t i = 0; i < sizeof names / sizeof *names; i++)
        if (!strcmp(name, names[i])) return 1;
    return 0;
}

/* Fill ARGV0, SCRIPT (the first argument after argv[0] that is not an option,
   or "" when an option evaluates code instead) and TARGET from PID's arguments
   and environment.  Returns 0 if they cannot be read. */
static int procargs(pid_t pid, const char *prefix, char *argv0, size_t n0, char *script, size_t ns,
                    char *target, size_t nt)
{
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = argmax;
    *argv0 = *script = *target = 0;
    if (sysctl(mib, 3, buf, &size, NULL, 0) < 0) return 0;
    int nargs; memcpy(&nargs, buf, sizeof nargs);
    char *p = buf + sizeof nargs, *end = buf + size;
    p += strlen(p) + 1;
    while (p < end && !*p) p++;
    int scripted = 0;
    for (int a = 0; a < nargs && p < end; a++, p += strlen(p) + 1) {
        if (a == 0) { snprintf(argv0, n0, "%s", p); continue; }
        if (scripted) continue;
        if (!strcmp(p, "-e") || !strcmp(p, "--eval") || !strcmp(p, "-p") || !strcmp(p, "--print")
            || !strcmp(p, "-c") || !strcmp(p, "-m")) scripted = 1;
        else if (*p != '-') { snprintf(script, ns, "%s", p); scripted = 1; }
    }
    /* A process that renamed itself (Pi via Node's process.title) leaves its
       old argument bytes as NUL padding before the environment. */
    while (p < end && !*p) p++;
    size_t plen = strlen(prefix);
    for (; p < end && *p; p += strlen(p) + 1)
        if (!strncmp(p, "PORTAL_TERMINAL=", 16) && !strncmp(p + 16, prefix, plen))
            snprintf(target, nt, "%s", p + 16 + plen);
    return 1;
}

/* The agent PID runs, from its executable PATH, ARGV0 and SCRIPT, or NULL. */
static const char *agent_name(const char *path, const char *argv0, const char *script)
{
    const char *exe = basename_of(path), *name = basename_of(argv0);
    if (runtime(name)) name = basename_of(script);
    static const char *const agents[] = {"claude", "codex", "pi"};
    for (size_t i = 0; i < sizeof agents / sizeof *agents; i++) {
        if (strcmp(name, agents[i])) continue;
        /* Native Claude runs from .../claude/versions/<version>. */
        int own = !strcmp(exe, name) || (!strcmp(name, "claude") && strstr(path, "/claude/versions/"));
        return own || runtime(exe) ? agents[i] : NULL;
    }
    return NULL;
}

int main(int argc, char **argv)
{
    if (argc != 2) { fprintf(stderr, "usage: agentscan EMACS_PID\n"); return 2; }
    char prefix[32]; snprintf(prefix, sizeof prefix, "%s/", argv[1]);
    size_t s = sizeof argmax; int m[2] = {CTL_KERN, KERN_ARGMAX};
    sysctl(m, 2, &argmax, &s, NULL, 0); buf = malloc(argmax);
    unsigned long long t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

    /* One snapshot of this user's processes.  Only processes in their
       terminal's foreground group can be an agent the user is running. */
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_UID, (int) getuid()};
    size_t length = 0;
    sysctl(mib, 4, NULL, &length, NULL, 0);
    length += length / 8;
    struct kinfo_proc *procs = malloc(length);
    if (sysctl(mib, 4, procs, &length, NULL, 0) < 0) return 1;
    int n = (int) (length / sizeof *procs), inspected = 0;
    static struct agent agents[256]; int count = 0;
    for (int i = 0; i < n && count < 256; i++) {
        struct kinfo_proc *k = &procs[i];
        if (k->kp_eproc.e_tdev == NODEV || k->kp_eproc.e_pgid != k->kp_eproc.e_tpgid) continue;
        pid_t pid = k->kp_proc.p_pid;
        inspected++;
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, path, sizeof path) <= 0) continue;
        char argv0[256], script[1024], target[96];
        if (!procargs(pid, prefix, argv0, sizeof argv0, script, sizeof script, target, sizeof target)) continue;
        const char *harness = agent_name(path, argv0, script);
        if (!harness || !*target) continue;
        struct proc_bsdinfo b;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, sizeof b) != sizeof b) continue;
        struct agent *a = &agents[count++];
        *a = (struct agent) {pid, b.pbi_ppid, b.pbi_pgid, b.e_tpgid, harness, "", "",
                             b.pbi_start_tvsec, b.pbi_start_tvusec, 0};
        snprintf(a->target, sizeof a->target, "%s", target);
        char *dn = devname(b.e_tdev, S_IFCHR);
        snprintf(a->tty, sizeof a->tty, "%s", dn ? dn : "");
    }
    /* An agent started by another agent in the same terminal is nested. */
    for (int i = 0; i < count; i++) {
        pid_t up = agents[i].ppid;
        for (int depth = 0; up > 1 && depth < 32 && !agents[i].nested; depth++) {
            for (int k = 0; k < count; k++)
                if (agents[k].pid == up && !strcmp(agents[k].target, agents[i].target)) agents[i].nested = 1;
            struct proc_bsdinfo b;
            if (proc_pidinfo(up, PROC_PIDTBSDINFO, 0, &b, sizeof b) != sizeof b) break;
            up = b.pbi_ppid;
        }
    }
    unsigned long long t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (int i = 0; i < count; i++) {
        struct agent *a = &agents[i];
        printf("{\"target\":\"%s\",\"harness\":\"%s\",\"pid\":%d,\"start\":\"%llu.%06llu\",\"pgid\":%d,"
               "\"tpgid\":%d,\"fg\":%s,\"tty\":\"%s\",\"nested\":%s}\n",
               a->target, a->harness, a->pid, a->start_s, a->start_us, a->pgid, a->tpgid,
               a->pgid == a->tpgid ? "true" : "false", a->tty, a->nested ? "true" : "false");
    }
    printf("{\"scan_us\":%llu,\"procs\":%d,\"inspected\":%d}\n", (t1 - t0) / 1000, n, inspected);
    return 0;
}
