# CmdyPTY implementation contract

CmdyPTY is cmdy's native macOS pseudo-terminal transport. It is intentionally
small and depends only on documented Darwin/POSIX process, terminal, signal,
descriptor, and Dispatch APIs.

## Process creation

- A C boundary performs `forkpty` followed directly by async-signal-safe child
  setup and `execve`; Swift code never runs in the post-fork child.
- The child starts as a session and process-group leader with its PTY as the
  controlling terminal.
- `argv[0]`, the optional replacement environment, working directory, and
  initial `winsize` are passed without shell interpolation. For compatibility,
  a failed working-directory change is advisory and execution continues from
  the inherited directory; every `execve` failure exits with status 127.
- Inherited descriptors above standard error are closed before `execve`.
- `LocalProcess` configures its parent master close-on-exec and nonblocking.
  The low-level compatibility helper deliberately returns the kernel's
  blocking, non-close-on-exec descriptor unchanged and accepts an empty argv.
- A nil high-level environment uses `defaultEnvironment(termName:)`; a
  nonnil environment, including an empty array, is passed exactly.

## Transport and backpressure

- A private serial queue owns each `LocalProcess` lifecycle and all master-FD
  reads/writes.
- Reads preserve bytes exactly. Only one 64 KiB read can wait for the delegate;
  a stalled delegate therefore applies PTY/kernel backpressure instead of
  growing an unbounded user-space buffer.
- Writes retain partial progress and resume from a Dispatch write source after
  `EAGAIN`.
- Delegate callbacks run asynchronously on the queue supplied to
  `LocalProcess`, defaulting to the main queue, with output ordered before the
  corresponding termination callback.
- Explicit host logging writes each received chunk asynchronously as a 0600
  `log-N` file in the selected directory. The counter persists for the
  lifetime of the `LocalProcess`; logging failures never interrupt drainage.

## Lifecycle guarantees

- Every launch has a monotonically increasing generation. A start request is a
  complete no-op while a session is active. Explicit termination retires the
  active generation synchronously, so an immediate new start is safe; retired
  sessions cannot deliver stale bytes or termination callbacks.
- A shared Dispatch process-source reaper calls `waitpid` for every child even
  when its owning `LocalProcess` has already deallocated.
- Child reaping and process-group signaling share one lock across `waitpid`
  and `kill`, preventing delayed escalation from signaling a PID after it
  becomes reusable.
- Termination targets the entire child process group with `SIGTERM`, then
  `SIGHUP`, and finally `SIGKILL` after bounded grace periods.
- Normal exits report their status. Signal exits use shell-compatible
  `128 + signal` values. A missing/invalid wait status reports `nil`.
- Master/read/write descriptors and Dispatch sources are canceled and closed
  on EOF, replacement, explicit termination, and owner deallocation.

The Core test suite covers environment and working-directory compatibility,
legacy helper behavior, window sizing and resize storms, byte preservation,
callback identity and backpressure, concurrent partial writes, process groups,
signal status, escalation, hundreds of immediate terminate/start generations,
many-pane drainage, reaping, host logging, and descriptor stability.
