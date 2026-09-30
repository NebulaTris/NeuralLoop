#!/usr/bin/env python3
"""A local stand-in for the Google Drive API calls NeuralLoop makes, for testing Mac ↔ iPad sync without a
Google account.

    python scripts/fake_drive.py [--port 8765] [--store DIR]

Then launch development builds with `-NLFakeDrive http://127.0.0.1:8765`. Implements: list (appDataFolder),
download (?alt=media), resumable upload (POST/PATCH to start a session, PUT the bytes), and delete.

Files are kept in --store (default ~/.cache/neuralloop-fake-drive), a folder only you can open
(0700); a store that belongs to someone else, or is a symlink, is refused.

Development only: no authentication, localhost only. Requests must name this machine as their Host,
so a web page can't reach the store through DNS rebinding. File ids are checked, so none can point
outside the store. Files are opened without following symlinks, and uploads must say how big they
are (at most MAX_UPLOAD bytes).
"""

import argparse
import contextlib
import hashlib
import json
import os
import re
import stat
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

FILES: dict[str, dict] = {}  # id -> {name, md5, size}
SESSIONS: dict[str, dict] = {}  # upload session -> {id or None, name}
DEFAULT_STORE = Path.home() / ".cache" / "neuralloop-fake-drive"
STORE = DEFAULT_STORE
MAX_UPLOAD = 3 * 1024**3  # bytes in one PUT (books with their media stay well under this)
MAX_METADATA = 64 * 1024  # bytes of JSON when starting an upload session
_CHUNK = 1024 * 1024
_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
_LOCAL_HOSTS = {"127.0.0.1", "localhost", "[::1]"}
_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


class StoreError(Exception):
    """The store folder can't be used safely."""


def valid_id(file_id: str) -> bool:
    return bool(_ID.fullmatch(file_id))


def prepare_store(path: Path) -> Path:
    """Create the store as a private folder (0700), or check an existing one: it must be a real folder (not a
    symlink) owned by this user. Its permissions are tightened to 0700."""
    path = Path(path).expanduser().absolute()
    path.parent.mkdir(parents=True, exist_ok=True)
    with contextlib.suppress(FileExistsError):  # an existing store is checked below
        path.mkdir(mode=0o700)
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise StoreError(f"{path} isn't a folder (a symlink or a file); choose another --store.")
    if info.st_uid != os.getuid():
        raise StoreError(f"{path} belongs to another user; choose a folder of your own with --store.")
    if stat.S_IMODE(info.st_mode) != 0o700:
        path.chmod(0o700)
    return path


def _open(path: Path, flags: int, mode: int = 0o600) -> int:
    """os.open that never follows a symlink at `path` (it fails with OSError instead)."""
    return os.open(path, flags | _NOFOLLOW, mode)


def read_file(path: Path) -> bytes:
    fd = _open(path, os.O_RDONLY)
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise OSError(f"{path.name} isn't a regular file")
        return f.read()


def write_file(path: Path, data: bytes) -> None:
    fd = _open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    with os.fdopen(fd, "wb") as f:
        f.write(data)


def load_index() -> None:
    """Files from an earlier session; an id that isn't one this server would make (say "../x") is ignored."""
    try:
        index = json.loads(read_file(STORE / "index.json"))
    except FileNotFoundError:
        return
    FILES.update({k: v for k, v in index.items() if valid_id(k)})


def save_index() -> None:
    temporary = STORE / f"index.{uuid.uuid4().hex}.part"
    write_file(temporary, json.dumps(FILES, indent=1).encode())
    os.replace(temporary, STORE / "index.json")


class Drive(BaseHTTPRequestHandler):
    def parse_request(self) -> bool:
        if not super().parse_request():
            return False
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].lower()
        if host not in _LOCAL_HOSTS:
            self.send_error(403, "Fake Drive only answers requests for 127.0.0.1")
            return False
        return True

    def reply(self, status: int, body: dict | bytes = b"", headers: dict | None = None) -> None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def length(self, limit: int) -> int | None:
        """The request's Content-Length, or None after replying with the reason it can't be used."""
        raw = self.headers.get("Content-Length")
        if raw is None:
            self.reply(411, {"error": {"message": "Content-Length is required"}})
            return None
        try:
            size = int(raw)
        except ValueError:
            size = -1
        if size < 0:
            self.reply(400, {"error": {"message": "Content-Length must be a whole number of bytes"}})
            return None
        if size > limit:
            self.reply(413, {"error": {"message": f"Too big: at most {limit} bytes"}})
            return None
        return size

    def resource(self, file_id: str) -> dict:
        f = FILES[file_id]
        return {"id": file_id, "name": f["name"], "md5Checksum": f["md5"], "size": str(f["size"])}

    def do_GET(self) -> None:
        url = urlparse(self.path)
        if url.path == "/drive/v3/files":
            return self.reply(200, {"files": [self.resource(i) for i in sorted(FILES)]})
        file_id = url.path.rsplit("/", 1)[-1]
        if url.path.startswith("/drive/v3/files/") and file_id in FILES:
            try:
                return self.reply(200, read_file(STORE / file_id))
            except OSError:  # missing, or replaced by a symlink: never follow it
                pass
        self.reply(404, {"error": {"message": "File not found"}})

    def start_session(self, file_id: str | None) -> None:
        size = self.length(MAX_METADATA) if "Content-Length" in self.headers else 0
        if size is None:
            return
        try:
            meta = json.loads(self.rfile.read(size) or b"{}")
        except ValueError:
            return self.reply(400, {"error": {"message": "The metadata isn't JSON"}})
        session = uuid.uuid4().hex
        SESSIONS[session] = {
            "id": file_id,
            "name": meta.get("name") or (FILES[file_id]["name"] if file_id else ""),
        }
        location = f"http://127.0.0.1:{self.server.server_port}/upload/session/{session}"
        self.reply(200, headers={"Location": location})

    def do_POST(self) -> None:
        if urlparse(self.path).path == "/upload/drive/v3/files":
            return self.start_session(None)
        self.reply(404, {"error": {"message": "Not found"}})

    def do_PATCH(self) -> None:
        file_id = urlparse(self.path).path.rsplit("/", 1)[-1]
        if file_id in FILES:
            return self.start_session(file_id)
        self.reply(404, {"error": {"message": "File not found"}})

    def do_PUT(self) -> None:
        session_id = urlparse(self.path).path.rsplit("/", 1)[-1]
        if session_id not in SESSIONS:
            return self.reply(404, {"error": {"message": "No such upload"}})
        size = self.length(MAX_UPLOAD)
        if size is None:
            return
        session = SESSIONS.pop(session_id)
        file_id = session["id"] or uuid.uuid4().hex[:12]
        # Stream to a new file next to it (never a symlink: O_EXCL and O_NOFOLLOW), then rename it into place.
        temporary = STORE / f"{file_id}.{uuid.uuid4().hex}.part"
        md5 = hashlib.md5()
        try:
            fd = _open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
            with os.fdopen(fd, "wb") as f:
                left = size
                while left:
                    chunk = self.rfile.read(min(_CHUNK, left))
                    if not chunk:
                        raise ConnectionError("the upload ended early")
                    f.write(chunk)
                    md5.update(chunk)
                    left -= len(chunk)
            os.replace(temporary, STORE / file_id)
        except (OSError, ConnectionError) as error:
            temporary.unlink(missing_ok=True)
            return self.reply(400, {"error": {"message": f"Upload failed: {error}"}})
        FILES[file_id] = {"name": session["name"], "md5": md5.hexdigest(), "size": size}
        save_index()
        self.reply(200, self.resource(file_id))

    def do_DELETE(self) -> None:
        file_id = urlparse(self.path).path.rsplit("/", 1)[-1]
        if FILES.pop(file_id, None) is not None:
            (STORE / file_id).unlink(missing_ok=True)  # removes a symlink itself, never what it points at
            save_index()
        self.reply(204)

    def log_message(self, format: str, *args) -> None:
        print(f"{self.command} {urlparse(self.path).path} -> {args[1] if len(args) > 1 else ''}", flush=True)


def main() -> None:
    global STORE
    parser = argparse.ArgumentParser(description="A local stand-in for Google Drive (development only).")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--store", default=str(DEFAULT_STORE), help="a private folder for the files (0700)")
    args = parser.parse_args()
    try:
        STORE = prepare_store(Path(args.store))
        load_index()
    except (StoreError, OSError, ValueError) as error:
        raise SystemExit(f"Fake Drive can't use its store: {error}") from None
    print(f"Fake Drive on http://127.0.0.1:{args.port} (files in {STORE})", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Drive).serve_forever()


if __name__ == "__main__":
    main()
