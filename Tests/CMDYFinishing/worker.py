"""Owned raw PTY fixture for normal-app lifetime/native qualification."""
import fcntl
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import struct
import sys
import termios
import time
import tty

root = Path(sys.argv[1]).resolve()
assert root.is_dir() and root.stat().st_mode & 0o777 == 0o700
pid = os.getpid()
path = root / f"w-{pid}.sock"
received = bytearray()
original = termios.tcgetattr(0)
running = True
def stop(*_):
    global running
    running = False
for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT): signal.signal(signum, stop)
def state():
    rows, cols, _, _ = struct.unpack("HHHH", fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))
    return dict(pid=pid, parentPID=os.getppid(), rows=rows, columns=cols, inputHex=received.hex())
def write(data):
    while data:
        count = os.write(1, data); data = data[count:]
def draw():
    write(f"\x1b[0m\x1b[2J\x1b[HFINISHING-{pid}\r\nStyled \x1b[31mred\x1b[0m é Å 中文 😀\r\n┌─────┐ ▀▄█\r\n".encode())
server = socket.socket(socket.AF_UNIX)
server.bind(str(path)); os.chmod(path, 0o600); server.listen(4)
selector = selectors.DefaultSelector()
selector.register(server, selectors.EVENT_READ, "control"); selector.register(0, selectors.EVENT_READ, "input")
started = time.monotonic()
try:
    tty.setraw(0); draw()
    while running and time.monotonic() - started < 1800:
        for selected, _ in selector.select(0.05):
            if selected.data == "input":
                data = os.read(0, 4096)
                if not data: running = False; break
                assert len(received) + len(data) < 65536
                received.extend(data)
            else:
                with server.accept()[0] as client:
                    client.settimeout(2)
                    raw = bytearray()
                    while not raw.endswith(b"\n"):
                        part = client.recv(4096)
                        assert part and len(raw) + len(part) <= 8192
                        raw.extend(part)
                    request = json.loads(raw)
                    command = request["command"]
                    if command == "draw": draw()
                    elif command == "clear-input": received.clear()
                    elif command == "history":
                        write(b"\x1b[?1049l\x1b[3J\x1b[2J\x1b[H")
                        write("\r\n".join(f"HISTORY-{index:05d} é Å 中文 😀" for index in range(1000)).encode())
                    elif command == "alternate":
                        write(b"\x1b[?1049h\x1b[2J\x1b[HALTERNATE\x1b[?1049l")
                    elif command == "image":
                        write(b"\x1b_Ga=T,f=32,s=1,v=1,i=31,q=2;/////w==\x1b\\")
                    elif command == "stop": running = False
                    elif command != "state": raise ValueError("unknown fixture command")
                    client.sendall(json.dumps(state()).encode() + b"\n")
finally:
    try: termios.tcsetattr(0, termios.TCSANOW, original)
    except termios.error: pass
    selector.close(); server.close(); path.unlink(missing_ok=True)
    (root / f"w-{pid}-closed.json").write_text(json.dumps(dict(**state(), closed=True)))
