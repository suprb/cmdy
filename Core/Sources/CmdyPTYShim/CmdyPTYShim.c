#include "CmdyPTYShim.h"

#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <util.h>

extern char **environ;

static void cmdy_reset_child_signals(void) {
    struct sigaction action;
    action.sa_handler = SIG_DFL;
    action.sa_flags = 0;
    sigemptyset(&action.sa_mask);

    for (int signal_number = 1; signal_number < NSIG; signal_number++) {
        if (signal_number == SIGKILL || signal_number == SIGSTOP) {
            continue;
        }
        (void)sigaction(signal_number, &action, NULL);
    }

    sigset_t empty_mask;
    sigemptyset(&empty_mask);
    (void)sigprocmask(SIG_SETMASK, &empty_mask, NULL);
}

static void cmdy_close_inherited_descriptors(int descriptor_limit) {
    if (descriptor_limit < STDERR_FILENO + 1) {
        return;
    }
    for (int descriptor = STDERR_FILENO + 1;
         descriptor < descriptor_limit;
         descriptor++) {
        (void)close(descriptor);
    }
}

int32_t cmdy_spawn_pty(pid_t *child_pid,
                       int *master_fd,
                       const char *executable,
                       char *const argv[],
                       char *const envp[],
                       const char *working_directory,
                       const struct winsize *initial_size,
                       int descriptor_limit) {
    if (child_pid == NULL || master_fd == NULL || executable == NULL ||
        argv == NULL) {
        return EINVAL;
    }

    int primary = -1;
    struct winsize size;
    struct winsize *size_pointer = NULL;
    if (initial_size != NULL) {
        size = *initial_size;
        size_pointer = &size;
    }

    pid_t pid = forkpty(&primary, NULL, NULL, size_pointer);
    if (pid < 0) {
        return errno;
    }

    if (pid == 0) {
        cmdy_reset_child_signals();

        /*
         * Compatibility: the legacy helper treated a failed directory change
         * as advisory and still attempted execve from the inherited directory.
         */
        if (working_directory != NULL) {
            (void)chdir(working_directory);
        }

        cmdy_close_inherited_descriptors(descriptor_limit);
        execve(executable, argv, envp != NULL ? envp : environ);
        _exit(127);
    }

    *child_pid = pid;
    *master_fd = primary;
    return 0;
}

int32_t cmdy_pty_available_bytes(int descriptor, int32_t *size) {
    if (size == NULL) {
        errno = EINVAL;
        return -1;
    }

    int value = 0;
    int status = ioctl(descriptor, FIONREAD, &value);
    *size = (int32_t)value;
    return (int32_t)status;
}
