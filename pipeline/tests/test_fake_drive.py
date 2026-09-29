"""scripts/fake_drive.py, the stand-in for Google Drive: it stays on this machine and in its store."""

import http.client
import importlib.util
import json
import threading
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "fake_drive.py"


@pytest.fixture
def drive(tmp_path, monkeypatch):
    spec = importlib.util.spec_from_file_location("fake_drive", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, "STORE", tmp_path)
    server = ThreadingHTTPServer(("127.0.0.1", 0), module.Drive)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield module, server.server_port
    server.shutdown()
    server.server_close()


def _request(port: int, method: str, path: str, host: str | None = None, body: bytes = b""):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    headers = {"Host": host} if host else {}
    connection.request(method, path, body=body, headers=headers)
    response = connection.getresponse()
    return response.status, response.read()


def test_requests_for_other_host_names_are_refused(drive):
    """A web page using DNS rebinding reaches 127.0.0.1 under its own host name; it gets nothing."""
    _, port = drive
    assert _request(port, "GET", "/drive/v3/files", host="evil.example")[0] == 403
    assert _request(port, "GET", "/drive/v3/files", host=f"127.0.0.1:{port}")[0] == 200
    assert _request(port, "GET", "/drive/v3/files", host=f"localhost:{port}")[0] == 200


def test_file_ids_never_leave_the_store(drive, tmp_path):
    module, port = drive
    assert not module.valid_id("../../etc/passwd") and not module.valid_id("index.json")
    assert module.valid_id("0a1b2c3d4e5f")
    status, _ = _request(port, "GET", "/drive/v3/files/..%2F..%2Fetc%2Fpasswd", host="127.0.0.1")
    assert status == 404
    status, _ = _request(
        port, "POST", "/upload/drive/v3/files", host="127.0.0.1", body=json.dumps({"name": "b"}).encode()
    )
    assert status == 200 and len(list(tmp_path.iterdir())) == 0


def test_a_tampered_index_cannot_point_outside_the_store(drive, tmp_path):
    module, _ = drive
    (tmp_path / "index.json").write_text(json.dumps({"../../secret": {"name": "x", "md5": "", "size": 1}}))
    module.load_index()
    assert module.FILES == {}
