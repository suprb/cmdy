#ifndef CMDY_PTY_SHIM_H
#define CMDY_PTY_SHIM_H

#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Creates a new pseudo-terminal session and execs `executable` in its child.
///
/// All pointer-backed arguments are consumed before this function returns in
/// the parent. A NULL environment inherits the caller's environment; a NULL
/// working directory leaves the child in the caller's current directory. A
/// failed working-directory change is ignored for compatibility. Returns zero
/// on success or an errno value when the PTY/fork operation fails; child-side
/// exec failures terminate the child with status 127.
int32_t cmdy_spawn_pty(pid_t *child_pid,
                       int *master_fd,
                       const char *executable,
                       char *const argv[],
                       char *const envp[],
                       const char *working_directory,
                       const struct winsize *initial_size,
                       int descriptor_limit);

/// Thin C boundary for FIONREAD, whose structured ioctl macro is not imported
/// by Swift on every macOS SDK.
int32_t cmdy_pty_available_bytes(int descriptor, int32_t *size);

#ifdef __cplusplus
}
#endif

#endif
