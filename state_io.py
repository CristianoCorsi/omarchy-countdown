"""Bounded, no-follow state IO for the Countdown plugin.

The QML process never opens the state file itself.  This helper performs every
read through one non-blocking, no-follow descriptor, validates that descriptor
with fstat(), and only then decodes a size-bounded JSON payload.  Writes use a
new regular file in the same verified directory followed by an atomic rename.
"""

from __future__ import annotations

import errno
import json
import os
import secrets
import stat
import sys
from typing import Any


MAX_STATE_BYTES = 64 * 1024
MAX_COUNTDOWNS = 64
MAX_LABEL_CHARS = 128
MAX_DATE_CHARS = 10
MAX_FORMAT_CHARS = 16
ALLOWED_FORMATS = frozenset({"days", "percentage", "auto"})


class StateError(Exception):
    """A state path or payload failed a security boundary."""


def _string_field(value: Any, name: str, limit: int) -> str:
    if not isinstance(value, str):
        raise StateError(f"{name} must be a string")
    if len(value) > limit:
        raise StateError(f"{name} exceeds {limit} characters")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        raise StateError(f"{name} contains control characters")
    return value


def normalize_state(raw: Any) -> dict[str, Any]:
    """Return the only state shape that may cross into QML."""

    if not isinstance(raw, dict):
        raise StateError("state root must be an object")

    raw_countdowns = raw.get("countdowns", [])
    if not isinstance(raw_countdowns, list):
        raise StateError("countdowns must be an array")
    if len(raw_countdowns) > MAX_COUNTDOWNS:
        raise StateError(f"countdowns exceeds {MAX_COUNTDOWNS} records")

    countdowns: list[dict[str, str]] = []
    for index, entry in enumerate(raw_countdowns):
        if not isinstance(entry, dict):
            raise StateError(f"countdowns[{index}] must be an object")

        label = _string_field(entry.get("label", ""), f"countdowns[{index}].label", MAX_LABEL_CHARS)
        start = _string_field(entry.get("start", ""), f"countdowns[{index}].start", MAX_DATE_CHARS)
        end = _string_field(entry.get("end", ""), f"countdowns[{index}].end", MAX_DATE_CHARS)
        format_name = _string_field(
            entry.get("format", "days"),
            f"countdowns[{index}].format",
            MAX_FORMAT_CHARS,
        )
        if format_name not in ALLOWED_FORMATS:
            format_name = "days"

        countdowns.append(
            {
                "label": label,
                "start": start,
                "end": end,
                "format": format_name,
            }
        )

    raw_state = raw.get("state", {})
    if not isinstance(raw_state, dict):
        raise StateError("state must be an object")
    current_index = raw_state.get("current_index", 0)
    if isinstance(current_index, bool) or not isinstance(current_index, int):
        current_index = 0
    if current_index < 0 or current_index >= len(countdowns):
        current_index = 0

    return {"state": {"current_index": current_index}, "countdowns": countdowns}


def _open_parent(path: str, create: bool) -> tuple[int, str]:
    absolute = os.path.abspath(path)
    parent, name = os.path.split(absolute)
    if not name or name in {".", ".."}:
        raise StateError("invalid state filename")

    if create:
        try:
            os.makedirs(parent, mode=0o700, exist_ok=True)
        except OSError as error:
            raise StateError(f"cannot create state directory: {error.strerror}") from error

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        directory_fd = os.open(parent, flags)
    except OSError as error:
        if error.errno == errno.ENOENT:
            raise FileNotFoundError(parent) from error
        raise StateError(f"cannot open state directory safely: {error.strerror}") from error

    directory_stat = os.fstat(directory_fd)
    if not stat.S_ISDIR(directory_stat.st_mode) or directory_stat.st_uid != os.getuid():
        os.close(directory_fd)
        raise StateError("state directory must be an owned real directory")
    if directory_stat.st_mode & 0o022:
        os.close(directory_fd)
        raise StateError("state directory must not be group- or world-writable")
    return directory_fd, name


def _read_bounded(fd: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while total <= MAX_STATE_BYTES:
        try:
            chunk = os.read(fd, min(8192, MAX_STATE_BYTES + 1 - total))
        except BlockingIOError as error:
            raise StateError("state file would block") from error
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    data = b"".join(chunks)
    if len(data) > MAX_STATE_BYTES:
        raise StateError(f"state file exceeds {MAX_STATE_BYTES} bytes")
    return data


def read_state(path: str) -> dict[str, Any] | None:
    """Securely read and normalize state, or return None when it is absent."""

    try:
        directory_fd, name = _open_parent(path, create=False)
    except FileNotFoundError:
        return None

    file_fd = -1
    try:
        flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK
        flags |= getattr(os, "O_NOFOLLOW", 0)
        try:
            file_fd = os.open(name, flags, dir_fd=directory_fd)
        except OSError as error:
            if error.errno == errno.ENOENT:
                return None
            raise StateError(f"cannot open state file safely: {error.strerror}") from error

        file_stat = os.fstat(file_fd)
        if not stat.S_ISREG(file_stat.st_mode):
            raise StateError("state file must be a regular file")
        if file_stat.st_uid != os.getuid():
            raise StateError("state file must be owned by the current user")
        if file_stat.st_nlink != 1:
            raise StateError("state file must have exactly one hard link")
        if file_stat.st_mode & 0o022:
            raise StateError("state file must not be group- or world-writable")
        if file_stat.st_size > MAX_STATE_BYTES:
            raise StateError(f"state file exceeds {MAX_STATE_BYTES} bytes")

        payload = _read_bounded(file_fd)
    finally:
        if file_fd >= 0:
            os.close(file_fd)
        os.close(directory_fd)

    try:
        raw = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise StateError("state file is not valid UTF-8 JSON") from error
    return normalize_state(raw)


def _write_all(fd: int, payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = os.write(fd, payload[offset:])
        if written <= 0:
            raise StateError("short write while saving state")
        offset += written


def write_state(path: str, raw: Any) -> dict[str, Any]:
    """Normalize and atomically persist state without following the target."""

    normalized = normalize_state(raw)
    payload = (json.dumps(normalized, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if len(payload) > MAX_STATE_BYTES:
        raise StateError(f"normalized state exceeds {MAX_STATE_BYTES} bytes")

    directory_fd, name = _open_parent(path, create=True)
    temporary_name = f".{name}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
    temporary_fd = -1
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
        flags |= getattr(os, "O_NOFOLLOW", 0)
        temporary_fd = os.open(temporary_name, flags, 0o600, dir_fd=directory_fd)
        temporary_stat = os.fstat(temporary_fd)
        if not stat.S_ISREG(temporary_stat.st_mode) or temporary_stat.st_uid != os.getuid():
            raise StateError("temporary state file failed ownership/type checks")
        _write_all(temporary_fd, payload)
        os.fsync(temporary_fd)
        os.close(temporary_fd)
        temporary_fd = -1
        os.replace(
            temporary_name,
            name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        os.fsync(directory_fd)
    except Exception:
        if temporary_fd >= 0:
            os.close(temporary_fd)
        try:
            os.unlink(temporary_name, dir_fd=directory_fd)
        except OSError:
            pass
        raise
    finally:
        os.close(directory_fd)
    return normalized


def _emit(status: str, **values: Any) -> None:
    message = {"status": status, **values}
    print(json.dumps(message, ensure_ascii=False, separators=(",", ":")), flush=True)


def _read_stdin_payload() -> Any:
    line = sys.stdin.buffer.readline(MAX_STATE_BYTES + 2)
    if len(line) > MAX_STATE_BYTES + 1 or not line.endswith(b"\n"):
        raise StateError(f"write request exceeds {MAX_STATE_BYTES} bytes")
    try:
        return json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise StateError("write request is not valid UTF-8 JSON") from error


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in {"read", "write"}:
        _emit("error", error="usage: state_io.py read|write PATH")
        return 2

    operation, path = argv[1], argv[2]
    try:
        if operation == "read":
            state = read_state(path)
            if state is None:
                _emit("missing")
            else:
                _emit("ok", data=state)
        else:
            state = write_state(path, _read_stdin_payload())
            _emit("ok", data=state)
    except (OSError, StateError) as error:
        _emit("error", error=str(error)[:240])
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
