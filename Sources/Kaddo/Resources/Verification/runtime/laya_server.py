#!/usr/bin/env python3
"""Loopback-only Laya-MLX decision service for Codex local workflows."""
from __future__ import annotations

import hmac
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
import traceback

MODEL = os.environ.get("CODEX_LAYA_MODEL", "aac6fef/laya-multilingual-mlx")
REVISION = os.environ.get(
    "CODEX_LAYA_REVISION", "f2b4faf51023039425946074e2cf1361d2db11d5"
)
TOKEN_FILE = Path(os.environ.get(
    "CODEX_LAYA_TOKEN_FILE", str(Path.home() / ".config/codex-local-laya/token")
))
HOST = "127.0.0.1"
PORT = int(os.environ.get("CODEX_LAYA_PORT", "8765"))
MAX_BODY = 8 * 1024 * 1024
MODEL_LOCK = threading.RLock()
AGENT = None


def complete_input_metadata(agent, state, instructions, criteria):
    """Strict verification must never classify a silently truncated question or proof."""
    from laya_mlx.common import build_prefix, serialize_state, render_options
    q = agent._to_internal({"type": "choice", "instructions": instructions, "criteria": criteria})
    tok = agent.tok
    options = [tok(" " + option.replace(tok.mask_token, " "), add_special_tokens=False)["input_ids"] for option in render_options(q)]
    if any(len(option) > 48 for option in options):
        raise ValueError("Verification criteria exceed the model option budget; no classification performed")
    head = tok(f"{q['t']} question: {instructions.replace(tok.mask_token, ' ')}", add_special_tokens=False)["input_ids"]
    head_limit = agent.cfg.get("head_max_len", 192) - sum(1 + len(option) for option in options)
    if len(head) > head_limit:
        raise ValueError(f"Verification instructions exceed model budget ({len(head)} > {head_limit}); no classification performed")
    prefix, _ = build_prefix(tok, q, agent.cfg.get("head_max_len", 192))
    count = len(tok(serialize_state(state).replace(tok.mask_token, " "), add_special_tokens=False)["input_ids"])
    limit = agent.cfg.get("max_len", 512) - len(prefix) - 1
    if count > limit:
        raise ValueError(f"Verification input exceeds model budget ({count} > {limit} tokens). Submit concise complete task/check evidence; retain full proof in files. No classification performed.")
    return {"input_tokens": count, "input_token_limit": limit, "input_truncated": False}


def load_agent():
    global AGENT
    if AGENT is None:
        import laya_mlx as laya
        AGENT = laya.load(MODEL, revision=REVISION)
    return AGENT


class Handler(BaseHTTPRequestHandler):
    server_version = "CodexLocalLaya/1"

    def log_message(self, fmt, *args):
        # Do not log request bodies or potentially sensitive user text.
        return

    def send_json(self, status, value):
        raw = json.dumps(value, ensure_ascii=False, allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path != "/health":
            self.send_json(404, {"error": "not found"})
            return
        self.send_json(200, {"ok": True, "model": MODEL, "revision": REVISION, "verification_input_attestation": True})

    def do_POST(self):
        if self.path not in ("/v1/classify", "/v1/systemone"):
            self.send_json(404, {"error": "not found"})
            return
        try:
            expected = TOKEN_FILE.read_text().strip()
        except OSError:
            self.send_json(503, {"error": "local model token is unavailable"})
            return
        supplied = self.headers.get("Authorization", "")
        if not expected or not hmac.compare_digest(supplied, f"Bearer {expected}"):
            self.send_json(401, {"error": "unauthorized"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 2 or length > MAX_BODY:
                raise ValueError("request body size is invalid")
            payload = json.loads(self.rfile.read(length))
            if not isinstance(payload, dict):
                raise ValueError("request body must be an object")
            with MODEL_LOCK:
                result = self.handle_payload(payload)
            self.send_json(200, result)
        except (ValueError, TypeError, KeyError) as exc:
            self.send_json(400, {"error": str(exc)})
        except Exception as exc:  # keep request text out of logs and responses
            print(f"local Laya request failed: {type(exc).__name__}: {exc}", flush=True)
            self.send_json(500, {"error": "local Laya inference failed"})

    def handle_payload(self, payload):
        if self.path == "/v1/systemone":
            state, questions = payload.get("state"), payload.get("questions")
            if state is None or not isinstance(questions, dict) or not questions:
                raise ValueError("state and non-empty questions are required")
            if len(questions) > 32:
                raise ValueError("at most 32 questions are allowed per request")
            result = load_agent().predict(state, questions)
            if not isinstance(result, dict) or not isinstance(result.get("answers"), dict):
                raise RuntimeError("Laya returned an invalid response")
            return result

        mode = payload.get("mode", "single")
        inputs, labels = payload.get("inputs"), payload.get("labels")
        instructions = payload.get("instructions", "Classify the input using the supplied labels.")
        if not isinstance(inputs, list) or not 1 <= len(inputs) <= 1000:
            raise ValueError("inputs must contain 1 to 1000 items")
        if any(not isinstance(item, (str, dict, list)) for item in inputs):
            raise ValueError("each input must be text, a JSON object, or a message list")
        if not isinstance(instructions, str) or not instructions.strip():
            raise ValueError("instructions must be non-empty text")

        agent = load_agent()
        if mode in ("single", "count", "review"):
            if not isinstance(labels, (list, dict)) or not 2 <= len(labels) <= 100:
                raise ValueError("labels must contain 2 to 100 options")
            criteria = labels if isinstance(labels, dict) else {str(label): str(label) for label in labels}
            results = []
            for item in inputs:
                coverage = complete_input_metadata(agent, item, instructions, criteria) if payload.get("require_full_input") is True else {}
                result = agent.predict(item, {"classification": {
                    "type": "choice", "instructions": instructions, "criteria": criteria
                }})["answers"]["classification"]
                results.append({
                    "label": result.get("choice"),
                    "confidence": result.get("confidence"),
                    "scores": result.get("probabilities"),
                    **coverage,
                })
            response = {"model": f"laya-mlx:{MODEL}@{REVISION}", "results": results}
            if mode == "count":
                threshold = _threshold(payload.get("unsure_below", 0.8))
                counts = {label: 0 for label in criteria}
                unsure = 0
                for result in results:
                    if result["confidence"] is None or result["confidence"] < threshold:
                        unsure += 1
                    elif result["label"] in counts:
                        counts[result["label"]] += 1
                response.update({"counts": counts, "total": len(results), "unsure": unsure,
                                 "unsure_below": threshold})
            elif mode == "review":
                threshold = _threshold(payload.get("below", 0.8))
                response["uncertain"] = [
                    {"index": i, "label": r["label"], "confidence": r["confidence"],
                     "runner_up": _runner_up(r.get("scores"), r.get("label")), "text": inputs[i]}
                    for i, r in enumerate(results)
                    if r["confidence"] is None or r["confidence"] < threshold
                ]
                response["below"] = threshold
            return response

        if mode == "multi":
            if not isinstance(labels, (list, dict)) or not 1 <= len(labels) <= 100:
                raise ValueError("multi-label mode needs 1 to 100 labels")
            criteria = labels if isinstance(labels, dict) else {str(label): str(label) for label in labels}
            results = []
            for item in inputs:
                scores = {}
                for label, description in criteria.items():
                    result = agent.predict(item, {"match": {
                        "type": "noul",
                        "instructions": f"{instructions}\nDoes this input match {label}: {description}?",
                    }})["answers"]["match"]
                    scores[label] = float(result["noul"])
                threshold = _threshold(payload.get("threshold", 0.7))
                results.append({"labels": [k for k, v in scores.items() if v >= threshold],
                                "scores": scores, "threshold": threshold})
            return {"model": f"laya-mlx:{MODEL}@{REVISION}", "results": results}

        if mode == "dimensions":
            dimensions = payload.get("dimensions")
            if not isinstance(dimensions, dict) or not dimensions:
                raise ValueError("dimensions must be a non-empty object")
            if len(inputs) * len(dimensions) > 1000:
                raise ValueError("at most 1000 item-by-dimension decisions are allowed")
            results = []
            for item in inputs:
                answers = {}
                for name, options in dimensions.items():
                    if isinstance(options, dict):
                        criteria = options
                    elif isinstance(options, list) and 2 <= len(options) <= 100:
                        criteria = {str(option): str(option) for option in options}
                    else:
                        raise ValueError(f"dimension {name} must contain 2 to 100 options")
                    answer = agent.predict(item, {str(name): {
                        "type": "choice", "instructions": instructions, "criteria": criteria
                    }})["answers"][str(name)]
                    answers[name] = {"label": answer.get("choice"),
                                     "confidence": answer.get("confidence"),
                                     "scores": answer.get("probabilities")}
                results.append(answers)
            return {"model": f"laya-mlx:{MODEL}@{REVISION}", "results": results}
        raise ValueError("mode must be single, multi, dimensions, count, or review")


def _threshold(value):
    if isinstance(value, bool) or not isinstance(value, (float, int)) or not 0 <= value <= 1:
        raise ValueError("threshold must be between 0 and 1")
    return float(value)


def _runner_up(scores, chosen):
    if not isinstance(scores, dict):
        return None
    ranked = sorted(((float(v), k) for k, v in scores.items() if k != chosen), reverse=True)
    return ranked[0][1] if ranked else None


def main():
    # Load before binding so a failed/missing model never appears ready.
    agent = load_agent()
    name = getattr(agent, "name", type(agent).__name__)
    print(f"Local Laya ready: {MODEL}@{REVISION} ({name}) on {HOST}:{PORT}", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
