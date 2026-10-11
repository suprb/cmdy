"""Wait for a read-only response from the exact generated PTY fixture."""
import time


def wait_owned_worker(read_state, pid, parent_pid, *, timeout=10, poll_seconds=.02):
    started = time.monotonic_ns()
    deadline = time.monotonic() + timeout
    attempts = 0
    transient_errors = []
    while time.monotonic() < deadline:
        attempts += 1
        try:
            state = read_state()
        except (FileNotFoundError, ConnectionRefusedError) as error:
            # bind() creates the pathname before listen() accepts connections.
            # Only this read-only readiness probe retries; test commands do not.
            transient_errors.append(error.errno)
            time.sleep(poll_seconds)
            continue
        if state.get('pid') != pid or state.get('parentPID') != parent_pid:
            raise RuntimeError('Ready fixture identity differs from the owned pane')
        return dict(status='pass', pid=pid, parentPID=parent_pid, state=state,
                    connectionAttempts=attempts, transientConnectionErrors=transient_errors,
                    startedMonotonicNS=started, finishedMonotonicNS=time.monotonic_ns())
    raise TimeoutError(f'Owned fixture {pid} did not answer its readiness probe')
