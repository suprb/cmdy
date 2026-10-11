"""Descriptor-anchored generated export intake. Unrecognized bytes are not retained."""
from __future__ import annotations

import os
from pathlib import Path
import re
import stat

from history_export_protocol import FILE_LIMIT, PATH_LIMIT, require, validate_export_bytes

FIELDS = ("st_dev", "st_ino", "st_uid", "st_gid", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
INVENTORY_LIMIT = 128
PATH_COMPONENT_LIMIT = 4  # At most three directories below the registered root.
DIRECTORY_IDENTITY = ("dev", "ino", "uid", "mode")
DIRECTORY_PHASES = frozenset(("open", "open-revalidation", "after-read", "before-unlink", "failure-cleanup"))


def annotate_directory_failure(failure, context, *, mode, uid, expected_uid, device):
    """Attach only bounded metadata from the stat value the guard rejected."""
    if type(failure) is not ValueError or str(failure) != "owned-directory-is-not-private" or context is None:
        return
    try:
        if type(context) is not tuple or len(context) != 3: return
        phase, ordinal, expected_device = context
        if (type(phase) is not str or phase not in DIRECTORY_PHASES or type(ordinal) is not int or not 0 <= ordinal <= 3
                or type(expected_device) is not int or not 0 < expected_device < 1 << 63
                or type(mode) is not int or not 0 <= mode <= 0xffffffff
                or any(type(value) is not int or not 0 <= value <= 0xffffffff for value in (uid, expected_uid))
                or type(device) is not int or not 0 < device < 1 << 63): return
        if stat.S_ISDIR(mode) and uid == expected_uid and mode & 0o077 == 0: return
        observed_type = "directory" if stat.S_ISDIR(mode) else "regular" if stat.S_ISREG(mode) else "symlink" if stat.S_ISLNK(mode) else "other"
        failure._cmdy_directory_rejection = dict(schemaVersion=1, purpose="failed-owned-directory-check", qualifying=False,
            phase=phase, directory="registered-root" if ordinal == 0 else "relative-ancestor", ordinal=ordinal,
            observedType=observed_type, permissionBits=stat.S_IMODE(mode), uidMatches=uid == expected_uid,
            sameDevice=device == expected_device)
    except Exception:
        # Diagnostic construction must never replace the guard's exception.
        return


def directory_rejection_metadata(failure):
    """Whitelist an attached error record before the worker persists anything."""
    if type(failure) is not ValueError or str(failure) != "owned-directory-is-not-private": return None
    value = getattr(failure, "_cmdy_directory_rejection", None)
    if type(value) is not dict or set(value) != {"schemaVersion", "purpose", "qualifying", "phase", "directory", "ordinal",
                                              "observedType", "permissionBits", "uidMatches", "sameDevice"}: return None
    if (type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
            or type(value["purpose"]) is not str or value["purpose"] != "failed-owned-directory-check" or value["qualifying"] is not False
            or type(value["phase"]) is not str or value["phase"] not in DIRECTORY_PHASES
            or type(value["ordinal"]) is not int or not 0 <= value["ordinal"] <= 3
            or type(value["directory"]) is not str or value["directory"] != ("registered-root" if value["ordinal"] == 0 else "relative-ancestor")
            or type(value["observedType"]) is not str or value["observedType"] not in ("directory", "regular", "symlink", "other")
            or type(value["permissionBits"]) is not int or not 0 <= value["permissionBits"] <= 0o7777
            or type(value["uidMatches"]) is not bool or type(value["sameDevice"]) is not bool): return None
    if value["observedType"] == "directory" and value["uidMatches"] and value["permissionBits"] & 0o077 == 0: return None
    return dict(value)


def metadata(value):
    return {name[3:]: getattr(value, name) for name in FIELDS}


def open_directory(path, *, rejection_context=None):
    """No symlink component, including the registered temporary directory."""
    path = Path(path)
    require(path.is_absolute() and str(path) == os.path.normpath(path), "owned-directory-not-canonical")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in path.parts[1:]:
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd); fd = next_fd
        value = os.fstat(fd)
        try:
            require(value.st_uid == os.getuid() and stat.S_ISDIR(value.st_mode)
                    and value.st_mode & 0o077 == 0, "owned-directory-is-not-private")
        except ValueError as failure:
            try:
                annotate_directory_failure(failure, rejection_context, mode=value.st_mode, uid=value.st_uid,
                                           expected_uid=os.getuid(), device=value.st_dev)
            except Exception:
                pass
            raise
        return fd
    except BaseException:
        os.close(fd); raise


def private_directory(value, uid, *, rejection_context=None):
    try:
        require(stat.S_ISDIR(value["mode"]) and value["uid"] == uid and value["mode"] & 0o077 == 0,
                "owned-directory-is-not-private")
    except ValueError as failure:
        try:
            annotate_directory_failure(failure, rejection_context, mode=value["mode"], uid=value["uid"],
                                       expected_uid=uid, device=value["dev"])
        except Exception:
            pass
        raise


def root_still_named(path, expected, *, rejection_context=None):
    """An old root FD is insufficient if its canonical name was replaced."""
    fd = open_directory(path, rejection_context=rejection_context)
    try:
        named = metadata(os.fstat(fd))
        require(named == expected, "owned-directory-name-or-state-changed")
        return named
    finally:
        os.close(fd)


def inventory(path):
    """Complete bounded nofollow tree inventory, without reading file contents.

    Entries retain identities and parent identities, never directory entry
    names. Every directory is fully visited or the entire arm fails closed.
    """
    fd = open_directory(path)
    entries, scans, seen = [], [], set()
    root = metadata(os.fstat(fd))
    seen.add((root["dev"], root["ino"]))

    def visit(current_fd, current, depth):
        private_directory(current, root["uid"])
        require(depth < PATH_COMPONENT_LIMIT, "temporary-directory-depth-bound")
        names = os.listdir(current_fd)
        require(len(entries) + len(names) <= INVENTORY_LIMIT, "temporary-directory-inventory-bound")
        parent = [current["dev"], current["ino"]]
        for name in sorted(names):
            require(len(entries) < INVENTORY_LIMIT, "temporary-directory-inventory-bound")
            value = metadata(os.stat(name, dir_fd=current_fd, follow_symlinks=False))
            identity = (value["dev"], value["ino"])
            require(identity not in seen, "temporary-directory-repeated-identity")
            require(value["uid"] == root["uid"] and value["dev"] == root["dev"]
                    and (stat.S_ISDIR(value["mode"]) or stat.S_ISREG(value["mode"])),
                    "temporary-directory-entry-type-or-owner-differs")
            seen.add(identity)
            entries.append(dict(parentIdentity=parent, metadata=value))
            if stat.S_ISDIR(value["mode"]):
                private_directory(value, root["uid"])
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=current_fd)
                try:
                    require(metadata(os.fstat(child)) == value, "temporary-directory-changed-during-open")
                    visit(child, value, depth + 1)
                    require(metadata(os.stat(name, dir_fd=current_fd, follow_symlinks=False)) == value,
                            "temporary-directory-changed-during-inventory")
                finally:
                    os.close(child)
        after = metadata(os.fstat(current_fd))
        require(after == current and sorted(os.listdir(current_fd)) == sorted(names),
                "temporary-directory-changed-during-inventory")
        scans.append(dict(identity=parent, before=current, after=after, childCount=len(names)))

    try:
        visit(fd, root, 0)
        root_still_named(path, root)
        return dict(schemaVersion=2, scope="complete-recursive-private-tree", complete=True,
                    maximumEntries=INVENTORY_LIMIT, maximumPathComponents=PATH_COMPONENT_LIMIT,
                    directory=root, identities=sorted([list(value) for value in seen if value != (root["dev"], root["ino"])]),
                    entryCount=len(entries), entries=entries, directoryScans=scans)
    finally:
        os.close(fd)


def parse_owned_path(raw, directory):
    require(isinstance(raw, bytes) and 0 < len(raw) <= PATH_LIMIT, "path-receipt-outside-bound")
    # The pilot deliberately does not guess shell quoting, newline framing or
    # bracketed-paste behavior. These raw path bytes are the preregistered form.
    try:
        text = raw.decode("ascii", errors="strict")
    except UnicodeError:
        raise ValueError("path-receipt-framing-unrecognized") from None
    prefix = str(Path(directory)) + "/"
    # Failure here does not establish that arbitrary received bytes were a
    # pathname, or that any export action ran. Never retain those bytes.
    require(text.startswith(prefix), "input-does-not-match-owned-export-path")
    name = text[len(prefix):]
    components = name.split("/")
    # Ghostty 1.3.1 uses URL-safe base64 for temporary directory names, so
    # either '-' or '_' may be first. Leading dots remain excluded.
    require(1 <= len(components) <= PATH_COMPONENT_LIMIT
            and all(re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,254}", value) is not None
                    and value not in (".", "..") for value in components), "path-receipt-framing-unrecognized")
    return name


def rejected_input_shape(raw, directory):
    """Describe a lexical rejection without retaining input, a hash, or a name.

    This does not unwrap or accept another format and never opens a directory
    or file. The complete raw input still passes through parse_owned_path.
    """
    require(type(raw) is bytes and len(raw) <= PATH_LIMIT, "shape-input-outside-bound")
    try:
        parse_owned_path(raw, directory)
    except ValueError as error:
        code = str(error)
        require(code in ("path-receipt-outside-bound", "path-receipt-framing-unrecognized",
                         "input-does-not-match-owned-export-path"), "shape-rejection-code-differs")
    else:
        return None

    def byte_class(value):
        if value is None: return "absent"
        if value >= 128: return "non-ASCII"
        if 48 <= value <= 57 or 65 <= value <= 90 or 97 <= value <= 122: return "alphanumeric"
        if value < 32 or value == 127: return "ASCII-control"
        return {46: "dot", 95: "underscore", 45: "hyphen", 32: "space", 47: "slash",
                92: "backslash", 39: "single-quote", 34: "double-quote"}.get(value, "other-ASCII")

    prefix_matches = raw.startswith(os.fsencode(str(Path(directory)) + "/"))
    leaf = raw[len(os.fsencode(str(Path(directory)) + "/")):] if prefix_matches else None
    leaf_shape = None if leaf is None else dict(
        bytes=len(leaf), firstByteClass=byte_class(leaf[0] if leaf else None),
        withinFilenameLengthBound=1 <= len(leaf) <= 255,
        containsSlash=b"/" in leaf, containsBackslash=b"\\" in leaf,
        containsWhitespace=any(value in b" \t\r\n\v\f" for value in leaf),
        containsASCIIControl=any(value < 32 or value == 127 for value in leaf),
        onlyDeclaredFilenameAlphabet=re.fullmatch(rb"[A-Za-z0-9._-]*", leaf) is not None)
    return dict(schemaVersion=1, purpose="rejected-history-input-shape-only", errorCode=code,
                qualifying=False, actionInvocationVerified=False, fileOpened=False,
                inputBytesRetained=0, inputHashRetained=False, filenameRetained=False,
                inputBytes=len(raw), asciiOnly=raw.isascii(), exactOwnedDirectoryPrefix=prefix_matches,
                firstByteClass=byte_class(raw[0] if raw else None),
                lastByteClass=byte_class(raw[-1] if raw else None),
                startsSingleQuote=raw.startswith(b"'"), startsDoubleQuote=raw.startswith(b'"'),
                endsSingleQuote=raw.endswith(b"'"), endsDoubleQuote=raw.endswith(b'"'),
                endsCR=raw.endswith(b"\r"), endsLF=raw.endswith(b"\n"), endsCRLF=raw.endswith(b"\r\n"),
                startsBracketedPaste=raw.startswith(b"\x1b[200~"), endsBracketedPaste=raw.endswith(b"\x1b[201~"),
                containsNUL=b"\0" in raw, leaf=leaf_shape)


def read_retained_generated(path, spec):
    """Replay an owned evidence copy without following replacement symlinks."""
    path = Path(path)
    require(path.name == "generated-export.bin", "retained-export-name-differs")
    directory_fd = open_directory(path.parent)
    fd = None
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=directory_fd)
        before = metadata(os.fstat(fd))
        require(stat.S_ISREG(before["mode"]) and stat.S_IMODE(before["mode"]) == 0o600
                and before["uid"] == os.getuid() and before["nlink"] == 1
                and 0 < before["size"] <= FILE_LIMIT, "retained-export-type-owner-mode-size-differs")
        raw = bytearray()
        while len(raw) <= before["size"]:
            part = os.read(fd, min(65536, before["size"] + 1 - len(raw)))
            if not part: break
            raw.extend(part)
        require(metadata(os.fstat(fd)) == before
                == metadata(os.stat(path.name, dir_fd=directory_fd, follow_symlinks=False))
                and len(raw) == before["size"], "retained-export-changed-during-read")
        value = bytes(raw); validate_export_bytes(value, spec)
        return value
    finally:
        if fd is not None: os.close(fd)
        os.close(directory_fd)


def read_generated_export(raw_path, directory, before, spec, retained):
    """Retain only fully recognized contents, then unlink the same owned inode.

    No error message includes received bytes or file contents. The raw path is
    persisted only after it has passed the exact owned-directory grammar.
    """
    components = parse_owned_path(raw_path, directory).split("/")
    require(before.get("schemaVersion") == 2 and before.get("complete") is True
            and before.get("scope") == "complete-recursive-private-tree"
            and before.get("maximumEntries") == INVENTORY_LIMIT
            and before.get("maximumPathComponents") == PATH_COMPONENT_LIMIT,
            "recursive-prearm-inventory-required")
    name = components[-1]
    directory_fds = [open_directory(directory, rejection_context=("open", 0, before["directory"]["dev"]))]
    chain = []
    fd = None
    identity = None
    unlinked = False

    def checkpoint(phase):
        require(len(chain) == len(directory_fds) == len(components), "ancestor-chain-incomplete")
        values = [metadata(os.fstat(item)) for item in directory_fds]
        named_values = [root_still_named(directory, values[0], rejection_context=(phase, 0, before["directory"]["dev"]))]
        for index, value in enumerate(values):
            require(value == chain[index]["opened"], "ancestor-changed-during-intake")
            private_directory(value, before["directory"]["uid"], rejection_context=(phase, index, before["directory"]["dev"]))
            if index:
                named = metadata(os.stat(components[index - 1], dir_fd=directory_fds[index - 1], follow_symlinks=False))
                require(named == value, "ancestor-name-or-identity-changed")
                named_values.append(named)
        return list(zip(values, named_values))

    try:
        directory_now = metadata(os.fstat(directory_fds[0]))
        require(all(directory_now[key] == before["directory"][key] for key in DIRECTORY_IDENTITY),
                "owned-directory-identity-changed")
        chain.append(dict(component=None, parentIdentity=None, opened=directory_now))
        for ordinal, component in enumerate(components[:-1], 1):
            parent = directory_fds[-1]
            value = metadata(os.stat(component, dir_fd=parent, follow_symlinks=False))
            private_directory(value, directory_now["uid"], rejection_context=("open", ordinal, before["directory"]["dev"]))
            require(value["dev"] == directory_now["dev"], "ancestor-device-differs-from-owned-tree")
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
            directory_fds.append(child)
            require(metadata(os.fstat(child)) == value, "ancestor-changed-during-open")
            parent_value = chain[-1]["opened"]
            chain.append(dict(component=component, parentIdentity=[parent_value["dev"], parent_value["ino"]], opened=value))
        for entry, (_, named) in zip(chain, checkpoint("open-revalidation")): entry["namedAtOpen"] = named
        directory_fd = directory_fds[-1]
        listed = metadata(os.stat(name, dir_fd=directory_fd, follow_symlinks=False))
        require(listed["dev"] == directory_now["dev"], "export-device-differs-from-owned-tree")
        require([listed["dev"], listed["ino"]] not in before["identities"], "export-was-not-new")
        require(stat.S_ISREG(listed["mode"]) and stat.S_IMODE(listed["mode"]) == 0o600
                and listed["uid"] == os.getuid() and listed["nlink"] == 1,
                "export-type-owner-mode-or-links-differ")
        require(0 < listed["size"] <= FILE_LIMIT, "export-size-outside-bound")
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=directory_fd)
        opened = metadata(os.fstat(fd))
        require(opened == listed, "export-changed-during-open")
        identity = opened
        data = bytearray()
        while len(data) <= identity["size"]:
            part = os.read(fd, min(65536, identity["size"] + 1 - len(data)))
            if not part:
                break
            data.extend(part)
        after = metadata(os.fstat(fd))
        named_after = metadata(os.stat(name, dir_fd=directory_fd, follow_symlinks=False))
        require(identity == after == named_after and len(data) == identity["size"], "export-changed-during-read")
        for entry, (value, named) in zip(chain, checkpoint("after-read")):
            entry.update(afterRead=value, namedAfterRead=named)
        validated = validate_export_bytes(bytes(data), spec)
        retained = Path(retained)
        output = os.open(retained, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            os.fchmod(output, 0o600)
            offset = 0
            while offset < len(data):
                amount = os.write(output, memoryview(data)[offset:])
                require(amount > 0, "retained-export-write-failed")
                offset += amount
        finally:
            os.close(output)
        for entry, (value, named) in zip(chain, checkpoint("before-unlink")):
            entry.update(beforeUnlink=value, namedBeforeUnlink=named)
        before_unlink = metadata(os.fstat(fd))
        named_before_unlink = metadata(os.stat(name, dir_fd=directory_fd, follow_symlinks=False))
        require(before_unlink == identity == named_before_unlink,
                "export-changed-before-cleanup")
        os.unlink(name, dir_fd=directory_fd); unlinked = True
        return dict(schemaVersion=2, status="recognized-generated-export", pathReceiptASCII=raw_path.decode("ascii"),
                    pathFraming="raw-absolute-path-no-delimiter", pathBytes=len(raw_path),
                    beforeInventory=before, opened=identity, afterRead=after, retainedFile=retained.name,
                    beforeUnlink=before_unlink, namedAtOpen=listed, namedAfterRead=named_after,
                    namedBeforeUnlink=named_before_unlink, ancestorChain=chain, rootNameRevalidated=True,
                    pathTraversal="descriptor-relative-nofollow",
                    validation=validated, cleanup=dict(sourceUnlinked=True, descriptorClosed=True,
                                                     directoryDescriptorClosed=True, sameInodeOnly=True))
    finally:
        # A file already proven new/private/regular remains ours on rejection,
        # but a renamed/replaced/modified entry is never removed by this path.
        if identity is not None and not unlinked:
            try:
                checkpoint("failure-cleanup")
                if metadata(os.fstat(fd)) == identity == metadata(os.stat(name, dir_fd=directory_fds[-1], follow_symlinks=False)):
                    os.unlink(name, dir_fd=directory_fds[-1])
            except (OSError, ValueError):
                pass
        if fd is not None:
            os.close(fd)
        for item in reversed(directory_fds): os.close(item)
