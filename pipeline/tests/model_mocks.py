"""Stand-ins for the AI services NeuralLoop talks to, run on 127.0.0.1 so the real provider classes (and the
real SDKs) can be tested end to end without a key or the internet.

`MockServer(flavor)` speaks the OpenAI Chat Completions API ("openai", "openrouter", "lmstudio",
"compatible"), the Anthropic Messages API with streaming ("anthropic"), or Ollama's native API ("ollama").
Each flavor copies the quirks of the real service that matter to us (see `_openai_quirk`). Every answer is
the practice model's canned JSON for the prompt it was sent, so every item converts. `fake_cli` writes an
opencode or Hermes Agent stand-in that answers the same way.
"""

import asyncio
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from neuralloop_books.models.fake import FakeModel

# How each prompt starts (prompts.py), so the server can tell which item it's being asked for.
KINDS = (
    ('Reply with {"ok": true}', "check"),
    ("Prepare study material for the chapter", "study"),
    ("Build a concept graph of the chapter", "graph"),
    ("Write a multiple-choice quiz", "quiz"),
    ("Write flashcards", "cards"),
    ("Make a mind map", "mindmap"),
    ("Write a two-host podcast script", "audio"),
    ("Write a narrated slide explainer", "video"),
    ("of a long chapter. Write dense study notes", "condense"),
    ('Idea: "', "recall"),
)
LMSTUDIO_MODELS = ("qwen/qwen3-8b", "google/gemma-3-4b")


def kind_of(text: str) -> str:
    return next((kind for marker, kind in KINDS if marker in text), "unknown")


def answer(text: str) -> str:
    """The practice model's answer to one prompt (the prompt is the last part of `text`)."""
    kind = kind_of(text)
    if kind == "unknown":
        return "I'm not sure what you're asking."
    # The task prompt comes after the chapter; the title regex must not match chapter text.
    prompt = text.rsplit("</chapter>", 1)[-1]
    return asyncio.run(FakeModel().complete(kind, "", text, prompt))


class MockServer:
    def __init__(
        self,
        flavor: str,
        *,
        models: tuple[str, ...] = (),
        keys: dict[str, int] | None = None,
        post_keys: dict[str, int] | None = None,
    ):
        """`keys`: an API key -> the HTTP status every request with it gets (401, 402, 429…);
        `post_keys`: the same for requests that ask the model something (lookups still work)."""
        self.flavor = flavor
        self.models = models or (LMSTUDIO_MODELS if flavor == "lmstudio" else ("model-a", "vendor/model-b"))
        self.keys = keys or {}
        self.post_keys = post_keys or {}
        self.requests: list[dict] = []
        server = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):  # quiet
                pass

            def do_GET(self):
                server._handle(self, "GET", None)

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                server._handle(self, "POST", json.loads(self.rfile.read(length) or b"{}"))

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()

    def posts(self, path_end: str) -> list[dict]:
        return [r for r in self.requests if r["method"] == "POST" and r["path"].endswith(path_end)]

    # ---- request handling ----

    def _handle(self, handler, method: str, body: dict | None) -> None:
        path = handler.path.split("?", 1)[0]
        headers = {k.lower(): v for k, v in handler.headers.items()}
        self.requests.append({"method": method, "path": path, "headers": headers, "body": body})
        key = headers.get("x-api-key") or headers.get("authorization", "").removeprefix("Bearer ")
        if key in self.keys:
            return self._error(handler, self.keys[key], f"mock error {self.keys[key]}")
        if method == "POST" and key in self.post_keys:
            return self._error(handler, self.post_keys[key], f"mock error {self.post_keys[key]}")
        route = getattr(self, f"_{self.flavor}" if self.flavor in ("anthropic", "ollama") else "_openai")
        route(handler, method, path, body or {})

    def _send(self, handler, status: int, data, content_type: str = "application/json") -> None:
        raw = data if isinstance(data, bytes) else json.dumps(data).encode()
        handler.send_response(status)
        handler.send_header("Content-Type", content_type)
        handler.send_header("Content-Length", str(len(raw)))
        handler.send_header("x-should-retry", "false")  # the SDKs would otherwise retry and slow tests down
        handler.end_headers()
        handler.wfile.write(raw)

    def _error(self, handler, status: int, message: str) -> None:
        if self.flavor == "anthropic":
            kinds = {401: "authentication_error", 404: "not_found_error", 429: "rate_limit_error"}
            body = {
                "type": "error",
                "error": {"type": kinds.get(status, "invalid_request_error"), "message": message},
            }
        else:
            body = {"error": {"message": message, "type": "invalid_request_error", "code": status}}
        self._send(handler, status, body)

    # OpenAI and friends

    def _openai(self, handler, method, path, body) -> None:
        if not path.startswith("/v1/"):
            return self._error(handler, 404, f"Unexpected endpoint {path}")
        if method == "GET" and path == "/v1/models":
            data = [{"id": m, "object": "model", "created": 0, "owned_by": "me"} for m in self.models]
            return self._send(handler, 200, {"object": "list", "data": data})
        if method == "GET" and path.startswith("/v1/models/"):
            name = path.removeprefix("/v1/models/")
            if self.flavor in ("lmstudio", "openrouter") or name not in self.models:
                # LM Studio (and OpenRouter) have no single-model lookup.
                return self._error(handler, 404, f"Unexpected endpoint or method. ({method} {path})")
            return self._send(handler, 200, {"id": name, "object": "model", "created": 0, "owned_by": "me"})
        if method == "POST" and path == "/v1/chat/completions":
            problem = self._openai_quirk(body)
            if problem:
                return self._error(handler, *problem)
            text = "\n\n".join(str(m.get("content", "")) for m in body["messages"])
            return self._send(
                handler,
                200,
                {
                    "id": "chatcmpl-1",
                    "object": "chat.completion",
                    "created": 0,
                    "model": body["model"],
                    "choices": [
                        {
                            "index": 0,
                            "message": {"role": "assistant", "content": answer(text)},
                            "finish_reason": "stop",
                        }
                    ],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
                },
            )
        return self._error(handler, 404, f"Unexpected endpoint {path}")

    def _openai_quirk(self, body: dict) -> tuple[int, str] | None:
        """What the real service would refuse."""
        if not body.get("model"):
            return 400, "you must provide a model parameter"
        if self.flavor in ("openai", "lmstudio") and body["model"] not in self.models:
            return 404, f"The model `{body['model']}` does not exist"
        response_format = (body.get("response_format") or {}).get("type")
        if self.flavor == "openai" and "max_tokens" in body:
            # OpenAI's reasoning models (gpt-5 and later).
            return (
                400,
                "Unsupported parameter: 'max_tokens' is not supported with this model. "
                "Use 'max_completion_tokens' instead.",
            )
        if self.flavor == "lmstudio" and response_format == "json_object":
            return 400, "'response_format.type' must be 'json_schema' or 'text'"
        if response_format == "json_schema" and "schema" not in body["response_format"].get(
            "json_schema", {}
        ):
            return 400, "json_schema needs a schema"
        return None

    # Anthropic Messages API

    def _anthropic(self, handler, method, path, body) -> None:
        if method == "GET" and path.startswith("/v1/models/"):
            name = path.removeprefix("/v1/models/")
            if name not in self.models:
                return self._error(handler, 404, f"model: {name}")
            return self._send(
                handler,
                200,
                {"type": "model", "id": name, "display_name": name, "created_at": "2026-01-01T00:00:00Z"},
            )
        if method == "POST" and path == "/v1/messages":
            if body.get("model") not in self.models:
                return self._error(handler, 404, f"model: {body.get('model')}")
            thinking = (body.get("thinking") or {}).get("type")
            if thinking == "adaptive" and body["model"].startswith("claude-haiku-4"):
                return self._error(handler, 400, "adaptive thinking is not supported on this model")
            if "fallbacks" in body and body["model"].startswith("claude-haiku-4"):
                return self._error(handler, 400, "fallbacks: Extra inputs are not permitted")
            if not all(block.get("text") for m in body["messages"] for block in m["content"]):
                return self._error(handler, 400, "text content blocks must be non-empty")
            text = "\n\n".join(block["text"] for m in body["messages"] for block in m["content"])
            return self._send(handler, 200, _sse(body["model"], answer(text)), "text/event-stream")
        return self._error(handler, 404, f"Unexpected endpoint {path}")

    # Ollama's native API

    def _ollama(self, handler, method, path, body) -> None:
        if path == "/api/version":
            return self._send(handler, 200, {"version": "0.12.0"})
        if path == "/api/tags":
            return self._send(handler, 200, {"models": [{"name": m} for m in self.models]})
        if method == "POST" and path == "/api/chat":
            if body.get("model") not in self.models:
                return self._error(handler, 404, f"model '{body.get('model')}' not found")
            text = "\n\n".join(m["content"] for m in body["messages"])
            return self._send(
                handler,
                200,
                {
                    "model": body["model"],
                    "message": {"role": "assistant", "content": answer(text)},
                    "done": True,
                },
            )
        return self._error(handler, 404, "404 page not found")


def _sse(model: str, text: str) -> bytes:
    events = [
        (
            "message_start",
            {
                "type": "message_start",
                "message": {
                    "id": "msg_1",
                    "type": "message",
                    "role": "assistant",
                    "model": model,
                    "content": [],
                    "stop_reason": None,
                    "stop_sequence": None,
                    "usage": {"input_tokens": 1, "output_tokens": 1},
                },
            },
        ),
        (
            "content_block_start",
            {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
        ),
        (
            "content_block_delta",
            {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}},
        ),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        (
            "message_delta",
            {
                "type": "message_delta",
                "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                "usage": {"output_tokens": 1},
            },
        ),
        ("message_stop", {"type": "message_stop"}),
    ]
    return "".join(f"event: {name}\ndata: {json.dumps(data)}\n\n" for name, data in events).encode()


def fake_cli(folder: Path, name: str, log: Path) -> Path:
    """An `opencode` or `hermes` stand-in on PATH: answers like the practice model, logs its argv and env."""
    pipeline = Path(__file__).resolve().parent.parent
    script = folder / name
    script.write_text(
        f"""#!{sys.executable}
import json, os, sys
sys.path[:0] = [{str(pipeline)!r}, {str(Path(__file__).resolve().parent)!r}]
args = sys.argv[1:]
with open({str(log)!r}, "a") as f:
    f.write(json.dumps({{"argv": args, "env": sorted(os.environ), "cwd": os.getcwd()}}) + "\\n")
if args[:2] == ["run", "--help"]:
    print("opencode run [message..]\\n  --standalone  run on a private server")
    sys.exit(0)
from model_mocks import answer
message = args[args.index("-z") + 1] if "-z" in args else args[-1]
print(answer(message))
"""
    )
    script.chmod(0o755)
    return script
