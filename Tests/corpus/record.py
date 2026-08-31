#!/usr/bin/env python3
"""Record a command's PTY output into a termite .term replay file.

Runs the command on a real pty with a fixed 80x24 winsize, optionally
feeding scripted keystrokes, and captures every output byte in read-sized
chunks — exactly what a terminal emulator would have been fed.

usage: record.py out.term [--input "bytes"] [--delay 0.4] [--timeout 6] -- cmd args…
"""
import argparse
import fcntl
import os
import select
import signal
import struct
import subprocess
import sys
import termios
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--input", default="", help="keystrokes to send after --delay (supports \\x escapes)")
    ap.add_argument("--delay", type=float, default=0.5)
    ap.add_argument("--timeout", type=float, default=6.0)
    ap.add_argument("--cols", type=int, default=80)
    ap.add_argument("--rows", type=int, default=24)
    argv = sys.argv[1:]
    if "--" in argv:
        split = argv.index("--")
        own, cmd = argv[:split], argv[split + 1:]
    else:
        own, cmd = argv, []
    args = ap.parse_args(own)
    if not cmd:
        print("no command given", file=sys.stderr)
        return 2

    master, slave = os.openpty()
    winsz = struct.pack("HHHH", args.rows, args.cols, 0, 0)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, winsz)

    env = dict(os.environ)
    env.update({"TERM": "xterm-256color", "COLUMNS": str(args.cols), "LINES": str(args.rows)})
    proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                            env=env, preexec_fn=os.setsid, close_fds=True)
    os.close(slave)

    chunks = []
    keys = args.input.encode().decode("unicode_escape").encode("latin-1") if args.input else b""
    sent = False
    start = time.time()
    deadline = start + args.timeout

    while time.time() < deadline:
        if keys and not sent and time.time() - start >= args.delay:
            os.write(master, keys)
            sent = True
        r, _, _ = select.select([master], [], [], 0.05)
        if r:
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            chunks.append(data)
        elif proc.poll() is not None:
            # drain whatever is left
            while True:
                r, _, _ = select.select([master], [], [], 0.1)
                if not r:
                    break
                try:
                    data = os.read(master, 65536)
                except OSError:
                    data = b""
                if not data:
                    break
                chunks.append(data)
            break

    if proc.poll() is None:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            pass
    os.close(master)

    total = sum(len(c) for c in chunks)
    with open(args.out, "wb") as f:
        f.write(f"TERMITE-REPLAY 1\ncols={args.cols} rows={args.rows}\n----\n".encode())
        for c in chunks:
            f.write(struct.pack("<I", len(c)))
            f.write(c)
    print(f"{args.out}: {len(chunks)} chunks, {total} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
