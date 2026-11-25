#!/usr/bin/env python3
"""End-to-end live benchmark for strixite (OpenAI-compatible /v1/chat/completions):
- Short decode throughput
- Multi-depth prefill + decode + 50%-depth Needle-in-a-Haystack (NIAH) recall
- Slot eviction & RAM prompt-cache resume
- 2-slot concurrent prefill + decode

Zero external dependencies (Python 3 stdlib only).
"""

from __future__ import annotations

import argparse
import json
import random
import threading
import time
import urllib.error
import urllib.request

WORDS = [
    "kernel", "scheduler", "memory", "buffer", "cache", "tensor", "matrix", "vector",
    "socket", "packet", "latency", "bandwidth", "pipeline", "thread", "mutex", "epoch",
    "gradient", "attention", "router", "expert", "checkpoint", "storage", "nvme", "page",
    "segment", "offset", "pointer", "register", "shader", "wavefront", "cluster", "node",
    "protocol", "stream", "token", "context", "window", "prefix", "delta", "snapshot",
    "metric", "counter", "gauge", "thermal", "voltage", "clock", "fabric", "aperture",
]

# Calibrated for ~1.83 tokens/word on Qwen3.8 tokenizer with synthetic prose
DEPTH_PRESETS = {
    "8k":   (4300,   "ZULU-4201-WREN"),
    "64k":  (36000,  "ALPHA-7492-FALCON"),
    "256k": (142000, "BRAVO-3819-OSPREY"),
    "450k": (245000, "CHARLIE-9054-KESTREL"),
}


def make_haystack(seed: int, target_words: int, needle_text: str, needle_frac: float = 0.5) -> str:
    rng = random.Random(seed)
    sentences = []
    words_so_far = 0
    needle_inserted = False
    needle_at = int(target_words * needle_frac)
    idx = 0
    while words_so_far < target_words:
        if not needle_inserted and words_so_far >= needle_at:
            sentences.append(f"\n[CRITICAL RECORD #{seed}]: {needle_text}\n")
            needle_inserted = True
        w = [rng.choice(WORDS) for _ in range(14)]
        sentences.append(
            f"Entry {seed}-{idx}: The {w[0]} {w[1]} updates {w[2]} {w[3]} across {w[4]} {w[5]} "
            f"with {w[6]} {w[7]} ({w[8]}/{w[9]}={rng.randint(10, 999)}) while {w[10]} {w[11]} "
            f"monitors {w[12]} {w[13]}."
        )
        words_so_far += 22
        idx += 1
    return " ".join(sentences)


def call_chat(base_url: str, model: str, messages: list[dict], max_tokens: int, thinking: bool, timeout: int) -> tuple[float, dict]:
    base = base_url.rstrip("/")
    url = base + ("/chat/completions" if base.endswith("/v1") else "/v1/chat/completions")
    body = json.dumps({
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": 0,
        "chat_template_kwargs": {"enable_thinking": thinking},
    }).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {detail}") from exc
    return time.time() - t0, data


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark strixite long-context speed, NIAH recall, cache resume, and concurrency.")
    parser.add_argument("--url", default="http://127.0.0.1:5300/v1", help="OpenAI-compatible /v1 base URL")
    parser.add_argument("--model", default="qwen3.8-flash-next", help="Model ID")
    parser.add_argument("--depths", default="64k,256k,450k", help="Comma-separated presets from: 8k,64k,256k,450k")
    parser.add_argument("--quick", action="store_true", help="Run only short decode + 8k prefill (~10s)")
    parser.add_argument("--no-resume", action="store_true", help="Skip slot-eviction + RAM cache resume test")
    parser.add_argument("--no-concurrent", action="store_true", help="Skip 2-slot concurrent prefill + decode test")
    parser.add_argument("--thinking", action="store_true", help="Enable thinking during benchmark turns")
    parser.add_argument("--timeout", type=int, default=900, help="Per-request HTTP timeout in seconds")
    args = parser.parse_args()

    rows: list[tuple[str, int, int, int, float, str]] = []

    print("=== 1. Short Decode Check (256 tokens) ===")
    dt, res = call_chat(
        args.url, args.model,
        [{"role": "user", "content": "Write a concise Python implementation of merge sort with comments explaining time and space complexity."}],
        max_tokens=256, thinking=args.thinking, timeout=args.timeout,
    )
    u = res.get("usage", {})
    rows.append(("short_decode", u.get("prompt_tokens", 0), 0, u.get("completion_tokens", 0), dt, "PASS"))
    print(f"short_decode: {dt:.2f}s, completion_tokens={u.get('completion_tokens')}")

    depths = ["8k"] if args.quick else [d.strip() for d in args.depths.split(",") if d.strip()]
    saved_last_msgs = None
    saved_last_key = None

    for idx, label in enumerate(depths):
        if label not in DEPTH_PRESETS:
            raise SystemExit(f"Unknown depth preset {label!r}. Choose from: {', '.join(DEPTH_PRESETS)}")
        n_words, passkey = DEPTH_PRESETS[label]
        seed = 40000 + idx * 101 + n_words
        hay = make_haystack(seed, n_words, f"The secret verification passkey for audit {label} is {passkey}.", 0.5)
        msgs = [
            {"role": "system", "content": "You are a precise log auditor. Answer concisely and follow instructions exactly."},
            {"role": "user", "content": hay + f"\n\nQuestion: What is the exact secret verification passkey for audit {label}? Reply with the passkey first, then write a 120-word technical explanation of how unified memory GTT paging works on GPUs."},
        ]
        print(f"=== 2. Running {label} Cold Prefill + Needle ===")
        dt, res = call_chat(args.url, args.model, msgs, max_tokens=200, thinking=args.thinking, timeout=args.timeout)
        txt = res["choices"][0]["message"]["content"]
        u = res.get("usage", {})
        cached = u.get("prompt_tokens_details", {}).get("cached_tokens", 0)
        hit = passkey in txt
        rows.append((f"niah_{label}", u.get("prompt_tokens", 0), cached, u.get("completion_tokens", 0), dt, "PASS" if hit else "FAIL"))
        print(f"niah_{label}: wall={dt:.2f}s prompt={u.get('prompt_tokens')} cached={cached} out={u.get('completion_tokens')} hit={hit}")
        saved_last_msgs = msgs + [
            {"role": "assistant", "content": txt},
            {"role": "user", "content": "Repeat only the passkey and nothing else."},
        ]
        saved_last_key = passkey

    if not args.quick and not args.no_resume and saved_last_msgs is not None:
        print("=== 3. Evicting Both Slots & Resuming Deepest State from Prompt Cache ===")
        for k in range(2):
            call_chat(args.url, args.model, [{"role": "user", "content": f"Eviction probe {k + 100}: reply OK."}], 8, False, args.timeout)
        dt_r, res_r = call_chat(args.url, args.model, saved_last_msgs, 32, False, args.timeout)
        txt_r = res_r["choices"][0]["message"]["content"]
        u_r = res_r.get("usage", {})
        cached_r = u_r.get("prompt_tokens_details", {}).get("cached_tokens", 0)
        hit_r = saved_last_key in txt_r
        rows.append(("cache_resume", u_r.get("prompt_tokens", 0), cached_r, u_r.get("completion_tokens", 0), dt_r, "PASS" if hit_r else "FAIL"))
        print(f"cache_resume: wall={dt_r:.2f}s prompt={u_r.get('prompt_tokens')} cached={cached_r} hit={hit_r}")

    if not args.quick and not args.no_concurrent:
        print("=== 4. 2-Slot Concurrent Prefill (~35k) + Decode (256 tokens) ===")
        hay32 = make_haystack(9991, 20000, "DELTA-1122-HAWK", 0.5)
        out: dict[str, tuple[float, dict]] = {}

        def _prefill() -> None:
            out["prefill"] = call_chat(args.url, args.model, [{"role": "user", "content": hay32 + "\nWhat is the passkey?"}], 32, False, args.timeout)

        def _decode() -> None:
            time.sleep(0.5)
            out["decode"] = call_chat(
                args.url, args.model,
                [{"role": "user", "content": "Write a 220-word overview of Linux virtual memory management, swappiness, and dirty page writeback."}],
                256, False, args.timeout,
            )

        t1 = threading.Thread(target=_prefill)
        t2 = threading.Thread(target=_decode)
        t1.start()
        t2.start()
        t1.join()
        t2.join()

        for key in ("prefill", "decode"):
            dt_c, res_c = out[key]
            u_c = res_c.get("usage", {})
            rows.append((f"concurrent_{key}", u_c.get("prompt_tokens", 0), 0, u_c.get("completion_tokens", 0), dt_c, "PASS"))

    print("\n### Summary")
    print("| Case | Prompt Tokens | Cached Tokens | Output Tokens | Wall (s) | Status |")
    print("|---|---:|---:|---:|---:|---|")
    for name, ptok, ctok, otok, wall, status in rows:
        print(f"| {name} | {ptok:,} | {ctok:,} | {otok:,} | {wall:.2f} | {status} |")


if __name__ == "__main__":
    main()
