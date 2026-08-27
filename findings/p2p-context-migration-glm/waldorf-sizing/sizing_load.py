#!/usr/bin/env python3
"""Mixed-load P-short sizing workload: native shorts vs migrated follow-ups.

Runs inside the cluster. Streams:
  long:     1 worker, back-to-back cold 32K prompts (keeps the gate open)
  short:    4 workers, paced 1.5K-token cold prompts (the native short class)
  followup: 1 worker, cycles seeded sessions with fresh 1K tails (migrate+pull)

Usage: sizing_load.py <epp_url> <arm_label> <seed|run> [duration_s] [direct_url]
Seeds print SESSION_SEEDED lines; run prints one JSON line per request.
Streams (run): direct-long x2 (capacity pressure, bypasses admission),
trigger x1 (EPP-visible gate pressure, sessions 0-1), short x1 (native class),
followup x1 (migration candidates, sessions 2-3). All EPP workers back off 2s
on non-200.
"""
import json
import random
import sys
import threading
import time
import urllib.error
import urllib.request

MODEL = "meta-llama/Llama-3.1-8B-Instruct"
SEED_TOKENS = 102_400
TAIL_TOKENS = 1_024
SHORT_TOKENS = 1_500
LONG_TOKENS = 32_768
SESSIONS = 4
SALT_BASE = 8270000
TOKEN_MIN, TOKEN_MAX = 1_000, 11_000

def seed_prompt(salt):
    payload = random.Random(0x4C4C4D53 + salt)  # per-session full prompt
    return [payload.randrange(TOKEN_MIN, TOKEN_MAX) for _ in range(SEED_TOKENS)]

def post(url, prompt, session=None, timeout=180):
    body = json.dumps({"model": MODEL, "prompt": prompt, "max_tokens": 1,
                       "temperature": 0}).encode()
    headers = {"Content-Type": "application/json"}
    if session:
        headers["X-Session-Id"] = session
    req = urllib.request.Request(url.rstrip("/") + "/v1/completions",
                                 data=body, headers=headers, method="POST")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            r.read()
            return r.status, time.time() - t0
    except urllib.error.HTTPError as e:
        e.read()
        return e.code, time.time() - t0
    except Exception:
        return -1, time.time() - t0

def main():
    url, arm, mode = sys.argv[1], sys.argv[2], sys.argv[3]
    if mode == "seed":
        for i in range(SESSIONS):
            st, dt = post(url, seed_prompt(SALT_BASE + i), session=f"sz-{i}", timeout=300)
            print(f"SESSION_SEEDED {i} status={st} ttft={dt:.2f}", flush=True)
        return

    duration = float(sys.argv[4]) if len(sys.argv) > 4 else 480.0
    direct_url = sys.argv[5] if len(sys.argv) > 5 else None
    out = []
    lock = threading.Lock()
    stop = time.time() + duration

    def emit(stream, st, dt):
        rec = {"arm": arm, "stream": stream, "status": st,
               "ttft": round(dt, 3), "t": round(time.time(), 1)}
        with lock:
            out.append(rec)
        print(json.dumps(rec), flush=True)

    def direct_long_worker(wid):
        n = 0
        while time.time() < stop:
            rng = random.Random(910_000 + wid * 100_000 + n); n += 1
            p = [rng.randrange(TOKEN_MIN, TOKEN_MAX) for _ in range(LONG_TOKENS)]
            st, dt = post(direct_url, p, timeout=120)
            emit("direct-long", st, dt)
            if st != 200:
                time.sleep(2.0)

    def trigger_worker():
        n = 0
        while time.time() < stop:
            i = n % 2
            rng = random.Random(940_000 + n); n += 1
            p = seed_prompt(SALT_BASE + i) + \
                [rng.randrange(TOKEN_MIN, TOKEN_MAX) for _ in range(8_192)]
            st, dt = post(url, p, session=f"sz-{i}")
            emit("trigger", st, dt)
            if st != 200:
                time.sleep(2.0)

    def short_worker(wid):
        n = 0
        while time.time() < stop:
            rng = random.Random(920_000 + wid * 100_000 + n); n += 1
            p = [rng.randrange(TOKEN_MIN, TOKEN_MAX) for _ in range(SHORT_TOKENS)]
            st, dt = post(url, p, timeout=120)
            emit("short", st, dt)
            time.sleep(2.0 if st != 200 else max(0.2, 1.0 - dt))

    def followup_worker():
        n = 0
        while time.time() < stop:
            i = 2 + (n % 2)
            rng = random.Random(930_000 + n); n += 1
            p = seed_prompt(SALT_BASE + i) + \
                [rng.randrange(TOKEN_MIN, TOKEN_MAX) for _ in range(TAIL_TOKENS)]
            st, dt = post(url, p, session=f"sz-{i}")
            emit("followup", st, dt)
            time.sleep(8.0 if st != 200 else 4.0)

    threads = [threading.Thread(target=direct_long_worker, args=(w,)) for w in range(2)]
    threads.append(threading.Thread(target=trigger_worker))
    threads.append(threading.Thread(target=short_worker, args=(0,)))
    threads.append(threading.Thread(target=followup_worker))
    for t in threads: t.start()
    for t in threads: t.join()

    def pct(xs, p):
        xs = sorted(xs)
        return xs[int(p / 100 * (len(xs) - 1))] if xs else None
    summary = {}
    for stream in ("short", "followup", "trigger", "direct-long"):
        vals = [r["ttft"] for r in out if r["stream"] == stream and r["status"] == 200]
        errs = sum(1 for r in out if r["stream"] == stream and r["status"] != 200)
        summary[stream] = {"n": len(vals), "errs": errs,
                           "p50": pct(vals, 50), "p90": pct(vals, 90)}
    print("SUMMARY " + json.dumps({"arm": arm, **summary}), flush=True)

main()
