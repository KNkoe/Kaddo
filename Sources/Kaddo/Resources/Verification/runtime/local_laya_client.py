"""Private loopback transport for the local Laya-MLX service."""
import json
import math
import os
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def call_local(payload, route="classify"):
    if not isinstance(payload, dict):
        raise ValueError("input must be a JSON object")
    route = route.strip("/")
    if route not in ("classify", "systemone"):
        raise ValueError("unsupported local route")
    if route == "classify":
        _validate_classification(payload)
    url = os.environ.get("LOCAL_LAYA_URL", "http://127.0.0.1:8765").rstrip("/")
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError("LOCAL_LAYA_URL must use loopback HTTP")
    timeout = float(os.environ.get("LOCAL_LAYA_TIMEOUT", "120"))
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("LOCAL_LAYA_TIMEOUT must be positive and finite")
    token_path = Path(os.environ.get(
        "LOCAL_LAYA_TOKEN_FILE", str(Path.home() / ".config/codex-local-laya/token")
    ))
    try:
        token = token_path.read_text().strip()
    except OSError as exc:
        raise RuntimeError("local Laya token is unavailable") from exc
    if len(token) < 32:
        raise RuntimeError("local Laya token is invalid")
    body = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode()
    request = urllib.request.Request(
        f"{url}/v1/{route}", data=body,
        headers={"Content-Type": "application/json", "Accept": "application/json",
                 "Authorization": f"Bearer {token}", "Cache-Control": "no-store"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read(2048).decode(errors="replace")
        raise RuntimeError(f"local Laya returned HTTP {exc.code}: {detail}") from exc
    if not isinstance(result, dict):
        raise RuntimeError("local Laya returned a non-object response")
    if route == "systemone":
        if not isinstance(result.get("answers"), dict):
            raise RuntimeError("local Laya returned no answers")
        return result
    results = result.get("results")
    expected = len(payload.get("inputs", [])) if isinstance(payload.get("inputs"), list) else -1
    if not isinstance(results, list) or len(results) != expected:
        raise RuntimeError("local Laya returned an invalid result count")
    mode = payload.get("mode", "single")
    labels = payload.get("labels")
    if mode in ("single", "count", "review"):
        allowed = set(labels if isinstance(labels, list) else labels.keys() if isinstance(labels, dict) else [])
        for item in results:
            if not isinstance(item, dict) or item.get("label") not in allowed:
                raise RuntimeError("local Laya returned an unknown label")
            _validate_probability(item.get("confidence"), nullable=True)
            scores = item.get("scores")
            if not isinstance(scores, dict) or set(scores) != allowed:
                raise RuntimeError("local Laya returned incomplete scores")
            for value in scores.values():
                _validate_probability(value)
    return result


def _validate_probability(value, nullable=False):
    if value is None and nullable:
        return
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not 0 <= value <= 1:
        raise RuntimeError("local Laya returned an invalid probability")


def _validate_classification(payload):
    mode = payload.get("mode", "single")
    inputs = payload.get("inputs")
    if not isinstance(inputs, list) or not 1 <= len(inputs) <= 1000:
        raise ValueError("inputs must contain 1 to 1000 items")
    if any(not isinstance(item, (str, dict, list)) or (isinstance(item, str) and not item.strip()) for item in inputs):
        raise ValueError("inputs must be non-empty text, JSON objects, or message lists")
    if mode in ("single", "count", "review", "multi"):
        labels = payload.get("labels")
        valid_len = (1 <= len(labels) <= 100) if mode == "multi" and isinstance(labels, (list, dict)) else (2 <= len(labels) <= 100) if isinstance(labels, (list, dict)) else False
        if not valid_len:
            count = "1 to 100" if mode == "multi" else "2 to 100"
            raise ValueError(f"labels must contain {count} options")
        keys = list(labels.keys()) if isinstance(labels, dict) else labels
        if len(set(keys)) != len(keys) or any(not isinstance(label, str) or not label.strip() for label in keys):
            raise ValueError("labels must be distinct non-empty strings")
    elif mode == "dimensions":
        dimensions = payload.get("dimensions")
        if not isinstance(dimensions, dict) or not dimensions or len(inputs) * len(dimensions) > 1000:
            raise ValueError("dimensions must be non-empty and contain at most 1000 decisions")
    else:
        raise ValueError("mode must be single, multi, dimensions, count, or review")
    instructions = payload.get("instructions", "Classify the input using the supplied labels.")
    if not isinstance(instructions, (str, dict)) or (isinstance(instructions, str) and not instructions.strip()):
        raise ValueError("instructions must be non-empty text or a dimension map")
    if mode == "multi":
        _validate_probability(payload.get("threshold", .7))
    if mode == "count":
        _validate_probability(payload.get("unsure_below", .8))
    if mode == "review":
        _validate_probability(payload.get("below", .8))
