#!/usr/bin/env python3
"""A local stand-in for the Google Drive API calls NeuralLoop makes, for testing Mac ↔ iPad sync without a Google account.

    python scripts/fake_drive.py [--port 8765] [--store /tmp/fake-drive]

Then launch development builds with `-NLFakeDrive http://127.0.0.1:8765`. Implements: list (appDataFolder), download
(?alt=media), resumable upload (POST/PATCH to start a session, PUT the bytes), and delete. Files are kept in --store.
Development only: no authentication, localhost only. Requests must name this machine as their Host, so a web page
can't reach the store through DNS rebinding, and file ids are checked, so none can point outside --store.
"""

import argparse
import hashlib
import json
import re
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

FILES: dict[str, dict] = {}  # id -> {name, md5, size}
SESSIONS: dict[str, dict] = {}  # upload session -> {id or None, name}
STORE = Path("/tmp/fake-drive")
_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
_LOCAL_HOSTS = {"127.0.0.1", "localhost", "[::1]"}


def valid_id(file_id: str) -> bool:
    return bool(_ID.fullmatch(file_id))


def load_index() -> None:
    """Files from an earlier session; an id that isn't one this server would make (say "../x") is ignored."""
    if (STORE / "index.json").exists():
        FILES.update({k: v for k, v in json.loads((STORE / "index.json").read_text()).items() if valid_id(k)})


def save_index() -> None:
    (STORE / "index.json").write_text(json.dumps(FILES, indent=1))


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

    def body(self) -> bytes:
        return self.rfile.read(int(self.headers.get("Content-Length") or 0))

    def resource(self, file_id: str) -> dict:
        f = FILES[file_id]
        return {"id": file_id, "name": f["name"], "md5Checksum": f["md5"], "size": str(f["size"])}

    def do_GET(self) -> None:
        url = urlparse(self.path)
        if url.path == "/drive/v3/files":
            return self.reply(200, {"files": [self.resource(i) for i in sorted(FILES)]})
        file_id = url.path.rsplit("/", 1)[-1]
        if url.path.startswith("/drive/v3/files/") and file_id in FILES:
            return self.reply(200, (STORE / file_id).read_bytes())
        self.reply(404, {"error": {"message": "File not found"}})

    def start_session(self, file_id: str | None) -> None:
        meta = json.loads(self.body() or b"{}")
        session = uuid.uuid4().hex
        SESSIONS[session] = {"id": file_id, "name": meta.get("name") or (FILES[file_id]["name"] if file_id else "")}
        self.reply(200, headers={"Location": f"http://127.0.0.1:{self.server.server_port}/upload/session/{session}"})

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
        session = SESSIONS.pop(urlparse(self.path).path.rsplit("/", 1)[-1], None)
        if session is None:
            return self.reply(404, {"error": {"message": "No such upload"}})
        data = self.body()
        file_id = session["id"] or uuid.uuid4().hex[:12]
        (STORE / file_id).write_bytes(data)
        FILES[file_id] = {"name": session["name"], "md5": hashlib.md5(data).hexdigest(), "size": len(data)}
        save_index()
        self.reply(200, self.resource(file_id))

    def do_DELETE(self) -> None:
        file_id = urlparse(self.path).path.rsplit("/", 1)[-1]
        if FILES.pop(file_id, None) is not None:
            (STORE / file_id).unlink(missing_ok=True)
            save_index()
        self.reply(204)

    def log_message(self, format: str, *args) -> None:
        print(f"{self.command} {urlparse(self.path).path} -> {args[1] if len(args) > 1 else ''}", flush=True)


def main() -> None:
    global STORE
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--store", default="/tmp/fake-drive")
    args = parser.parse_args()
    STORE = Path(args.store)
    STORE.mkdir(parents=True, exist_ok=True)
    load_index()
    print(f"Fake Drive on http://127.0.0.1:{args.port} (files in {STORE})", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Drive).serve_forever()


if __name__ == "__main__":
    main()
