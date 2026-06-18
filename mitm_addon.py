"""mitmproxy addon: intercept Codex API calls and route model requests to llm-proxy."""

import mitmproxy.http
from mitmproxy import ctx

LLM_PROXY = "http://127.0.0.1:8765"

# Codex Framework uses ab.chatgpt.com; older builds and third-party tools use api.openai.com
INTERCEPT_HOSTS = {"api.openai.com", "ab.chatgpt.com"}

MODEL_PATHS = [
    "/v1/chat/completions",
    "/v1/responses",
    "/v1/models",
]


def request(flow: mitmproxy.http.HTTPFlow) -> None:
    host = flow.request.pretty_host
    path = flow.request.path

    if host not in INTERCEPT_HOSTS:
        return

    is_model = any(path.startswith(p) for p in MODEL_PATHS)

    if is_model:
        ctx.log.info(f"→ ROUTE TO LLM-PROXY: {flow.request.method} {path}")
        flow.request.scheme = "http"
        flow.request.host = "127.0.0.1"
        flow.request.port = 8765
    else:
        ctx.log.info(f"→ PASS THROUGH: {flow.request.method} {path}")
