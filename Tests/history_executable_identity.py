"""Exact canonical executable alias join, shared by new evidence readers."""
import hashlib
import os
from pathlib import Path
import re
import stat
import sys


def _running_executable():
    """Ask macOS for this process's actual image, not Python's launcher path."""
    import ctypes
    if sys.platform != 'darwin':
        raise RuntimeError('native interpreter identity requires macOS')
    library = ctypes.CDLL('/usr/lib/libproc.dylib')
    query = library.proc_pidpath
    query.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    query.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    if query(os.getpid(), buffer, len(buffer)) <= 0:
        raise RuntimeError('cannot identify the current native interpreter')
    return os.fsdecode(buffer.value)


def pin_current_interpreter():
    """Fail before GUI work when a framework launcher names a different image."""
    path = Path(sys.executable).resolve(strict=True)
    pin = dict(path=str(path), bytes=path.stat().st_size,
               sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    observed = _running_executable()
    if not same_executable_file(observed, pin):
        raise RuntimeError('Python launcher differs from its native executable; '
                           'run this recorder with the exact interpreter: ' + observed)
    return pin


def same_executable_file(observed, planned):
    """Join Foundation/Python path aliases without accepting copies or new bytes."""
    if type(planned) is not dict or type(observed) is not str:
        return False
    named, checksum, size = planned.get('path'), planned.get('sha256'), planned.get('bytes')
    if (type(named) is not str or any(not value or len(value) > 4096 or '\0' in value
            or not Path(value).is_absolute() for value in (observed, named))
            or type(checksum) is not str or re.fullmatch('[0-9a-f]{64}', checksum) is None
            or type(size) is not int or size <= 0):
        return False
    descriptors = []
    def identity(value):
        return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
                value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    try:
        paths = (Path(named), Path(observed))
        canonical = [path.resolve(strict=True) for path in paths]
        if canonical[0] != canonical[1]:
            return False
        for path in paths:
            descriptors.append(os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK))
        initial = [os.fstat(fd) for fd in descriptors]
        pinned = identity(initial[0])
        if not stat.S_ISREG(initial[0].st_mode) or initial[0].st_size != size or identity(initial[1]) != pinned:
            return False
        digest = hashlib.sha256(); remaining = size
        while remaining:
            chunk = os.read(descriptors[0], min(65536, remaining))
            if not chunk: return False
            digest.update(chunk); remaining -= len(chunk)
        if os.read(descriptors[0], 1) or digest.hexdigest() != checksum:
            return False
        return (all(identity(os.fstat(fd)) == pinned for fd in descriptors)
            and all(identity(os.stat(path, follow_symlinks=False)) == pinned for path in paths)
            and [path.resolve(strict=True) for path in paths] == canonical)
    except (OSError, ValueError, RuntimeError):
        return False
    finally:
        for fd in descriptors: os.close(fd)
