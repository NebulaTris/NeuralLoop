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


def _upload(port: int, data: bytes, headers: dict | None = None) -> tuple[int, bytes]:
    """Start a session, then PUT `data` with `headers` (a Content-Length there replaces the real one)."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request(
        "POST", "/upload/drive/v3/files", body=b'{"name": "book"}', headers={"Host": "127.0.0.1"}
    )
    location = connection.getresponse().getheader("Location")
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.putrequest("PUT", location.split(str(port), 1)[1], skip_host=True, skip_accept_encoding=True)
    connection.putheader("Host", "127.0.0.1")
    for key, value in (headers if headers is not None else {"Content-Length": str(len(data))}).items():
        connection.putheader(key, value)
    connection.endheaders(data)
    response = connection.getresponse()
    return response.status, response.read()


def test_uploads_are_stored_and_listed(drive, tmp_path):
    _, port = drive
    status, body = _upload(port, b"hello book")
    assert status == 200
    file_id = json.loads(body)["id"]
    assert (tmp_path / file_id).read_bytes() == b"hello book"
    assert not list(tmp_path.glob("*.part"))
    assert _request(port, "GET", f"/drive/v3/files/{file_id}", host="127.0.0.1") == (200, b"hello book")


def test_uploads_must_say_how_big_they_are(drive, tmp_path, monkeypatch):
    module, port = drive
    assert _upload(port, b"", headers={})[0] == 411
    assert _upload(port, b"", headers={"Content-Length": "-5"})[0] == 400
    assert _upload(port, b"", headers={"Content-Length": "lots"})[0] == 400
    monkeypatch.setattr(module, "MAX_UPLOAD", 4)
    assert _upload(port, b"too big")[0] == 413
    assert module.FILES == {} and not [p for p in tmp_path.iterdir() if p.name != "index.json"]


def test_files_are_never_read_or_written_through_symlinks(drive, tmp_path):
    module, port = drive
    secret = tmp_path.parent / "secret.txt"
    secret.write_text("private")
    (tmp_path / "abc123").symlink_to(secret)
    module.FILES["abc123"] = {"name": "x", "md5": "", "size": 7}
    assert _request(port, "GET", "/drive/v3/files/abc123", host="127.0.0.1")[0] == 404
    (tmp_path / "index.json").symlink_to(secret)
    with pytest.raises(OSError):
        module.load_index()
    assert secret.read_text() == "private"


def test_the_store_is_private_and_must_be_yours(tmp_path, monkeypatch):
    spec = importlib.util.spec_from_file_location("fake_drive", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    store = module.prepare_store(tmp_path / "store")
    assert store.is_dir() and (store.stat().st_mode & 0o777) == 0o700
    (tmp_path / "open").mkdir(mode=0o755)
    assert (module.prepare_store(tmp_path / "open").stat().st_mode & 0o777) == 0o700
    (tmp_path / "link").symlink_to(store)
    with pytest.raises(module.StoreError):
        module.prepare_store(tmp_path / "link")
    real_uid = module.os.getuid()
    monkeypatch.setattr(module.os, "getuid", lambda: real_uid + 1)
    with pytest.raises(module.StoreError):
        module.prepare_store(store)
    assert Path("/tmp/fake-drive") != module.DEFAULT_STORE
