// Read-only, public macOS process accounting. No task_for_pid, GUI or signals.
#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

static uint64_t monotonic_ns(void) {
    // Match Python's macOS perf_counter clock explicitly, without assuming
    // CLOCK_MONOTONIC and mach_absolute_time handle sleep identically.
    mach_timebase_info_data_t timebase = {0};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.denom) return 0;
    return (uint64_t)((__uint128_t)mach_absolute_time() * timebase.numer / timebase.denom);
}
static int fail(const char *message) {
    fprintf(stderr, "%s\n", message);
    return 2;
}
int main(int argc, char **argv) {
    if (argc != 2 && argc != 3) return fail("usage: terminal-memory-snapshot OWNED_PID [EXPECTED_START_TICKS]");
    char *end = NULL;
    errno = 0;
    long parsed_pid = strtol(argv[1], &end, 10);
    if (errno || !end || *end || parsed_pid <= 1 || parsed_pid > INT_MAX)
        return fail("invalid owned PID");
    uint64_t expected_start = 0;
    if (argc == 3) {
        errno = 0;
        expected_start = strtoull(argv[2], &end, 10);
        if (errno || !end || *end || !expected_start || argv[2][0] == '-')
            return fail("invalid expected process-start ticks");
    }
    int pid = (int)parsed_pid;
    uint64_t started_ns = monotonic_ns();
    struct rusage_info_v4 usage = {0}, checked = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0)
        return fail("proc_pid_rusage failed; no sample recorded");
    struct proc_bsdinfo identity = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &identity, sizeof(identity)) != (int)sizeof(identity))
        return fail("process identity lookup failed; no sample recorded");
    if (identity.pbi_uid != getuid()) return fail("target is not owned by this user");
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&checked) != 0
        || usage.ri_proc_start_abstime != checked.ri_proc_start_abstime
        || checked.ri_proc_exit_abstime != 0)
        return fail("process identity changed during sampling");
    if (expected_start && expected_start != usage.ri_proc_start_abstime)
        return fail("process-start identity mismatch");
    mach_timebase_info_data_t timebase = {0};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS) return fail("mach timebase unavailable");
    uint64_t finished_ns = monotonic_ns();
    if (!started_ns || finished_ns < started_ns) return fail("monotonic clock failed");
    printf("{\"ok\":true,\"pid\":%d,\"parentPID\":%u,\"uid\":%u,"
           "\"processStartSeconds\":%" PRIu64 ",\"processStartMicroseconds\":%" PRIu64 ","
           "\"processStartTicks\":%" PRIu64 ",\"timebaseNumer\":%u,\"timebaseDenom\":%u,"
           "\"startedMonotonicNS\":%" PRIu64 ",\"sampleElapsedNS\":%" PRIu64 ","
           "\"residentBytes\":%" PRIu64 ",\"physicalFootprintBytes\":%" PRIu64 ","
           "\"lifetimeMaximumPhysicalFootprintBytes\":%" PRIu64 ","
           "\"wiredBytes\":%" PRIu64 ",\"pageins\":%" PRIu64 ","
           "\"userTimeNS\":%" PRIu64 ",\"systemTimeNS\":%" PRIu64 ","
           "\"cpuTimeUnit\":\"nanoseconds\",\"cpuTimeSource\":\"rusage-mach-absolute-ticks\","
           "\"userTimeTicks\":%" PRIu64 ",\"systemTimeTicks\":%" PRIu64 ","
           "\"interruptWakeups\":%" PRIu64 ",\"packageIdleWakeups\":%" PRIu64 ","
           "\"diskReadBytes\":%" PRIu64 ",\"diskWrittenBytes\":%" PRIu64 "}\n",
           pid, identity.pbi_ppid, identity.pbi_uid,
           (uint64_t)identity.pbi_start_tvsec, (uint64_t)identity.pbi_start_tvusec,
           usage.ri_proc_start_abstime, timebase.numer, timebase.denom,
           started_ns, finished_ns - started_ns,
           usage.ri_resident_size, usage.ri_phys_footprint,
           usage.ri_lifetime_max_phys_footprint, usage.ri_wired_size, usage.ri_pageins,
           (uint64_t)((__uint128_t)usage.ri_user_time * timebase.numer / timebase.denom),
           (uint64_t)((__uint128_t)usage.ri_system_time * timebase.numer / timebase.denom),
           usage.ri_user_time, usage.ri_system_time,
           usage.ri_interrupt_wkups, usage.ri_pkg_idle_wkups,
           usage.ri_diskio_bytesread, usage.ri_diskio_byteswritten);
    return 0;
}
