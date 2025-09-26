#!/usr/bin/env python3
# scripts/loggen-json.py
import json, os, random, socket, time, itertools, pathlib, sys

# --- Output file: keep same file as now, if possible ---
def detect_log_file():
    # Prefer explicit env var
    env = os.environ.get("LOG_FILE")
    if env:
        return env

    logs_dir = "/logs"
    try:
        paths = list(pathlib.Path(logs_dir).glob("*"))
        # Heuristics: prefer a single file, or something that looks json-ish
        if len(paths) == 1 and paths[0].is_file():
            return str(paths[0])
        jsonish = [p for p in paths if p.is_file() and ("json" in p.name.lower() or "log" in p.name.lower())]
        if jsonish:
            # pick most recently modified
            jsonish.sort(key=lambda p: p.stat().st_mtime, reverse=True)
            return str(jsonish[0])
    except Exception:
        pass
    # Fallback
    return "/logs/ft_transcendence.jsonl"

LOG_FILE = detect_log_file()

hostname = socket.gethostname()
pid = os.getpid()

# realistic URL mix from your sample
ROUTES = [
    ("/", 200),
    ("/css/output.css", 200),
    ("/ts/app.js", 200),
    ("/ts/gameModesRouter.js", 404),
    ("/ts/localGame.js", 200),
    ("/ts/login-register-form.js", 200),
    ("/ts/authenticate.js", 200),
    ("/ts/userProfile.js", 200),
    ("/ts/gameUtils/drawBoard.js", 200),
    ("/ts/gameUtils/websocketManager.js", 200),
    ("/ts/gameUtils/inputHandler.js", 200),
    ("/ts/gameUtils/gameRenderer.js", 200),
    ("/ts/validateInput.js", 200),
    ("/game/multiplayer", 200),
    ("/game/online", 200),
    ("/game/online-tournament", 200),
    ("/game/local-tournament", 200),
    ("/game/local", 200),
    ("/friends", 404),
    ("/profile", 200),
    ("/login", 200),
    ("/register", 200),
    ("/assets/default-avatar.svg", 200),
    ("/ws/localGame", 200),   # as GET in your sample
]

AUTH_ROUTES = [
    ("POST", "/api/auth/refresh", 401),
    ("POST", "/api/auth/login",  random.choice([200, 406])),
    ("POST", "/api/auth/register", 200),
]

# simple incrementing req ids like req-a, req-b seen in sample
def req_id_gen():
    alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    for i in itertools.count(1):
        if i <= 10:
            yield f"req-{i-1:x}"  # 0..9 -> 0..9, gives req-0 .. req-9
        else:
            # start from 'a' for 10+ (req-a, req-b, ...)
            yield f"req-{alphabet[i-1]}" if (i-1) < len(alphabet) else f"req-{i}"

reqid_iter = req_id_gen()

def now_ms():
    return int(time.time() * 1000)

def log_json(line, fh):
    fh.write(json.dumps(line, separators=(",", ":")) + "\n")
    fh.flush()

def mk_server_listening_entries():
    t = now_ms()
    host_msgs = [
        f"Server listening at https://[::1]:3000",
        f"Server listening at https://127.0.0.1:3000",
        f"ft_transcendence running at https://[::1]:3000",
    ]
    for m in host_msgs:
        yield {
            "level": 30,
            "time": t,
            "pid": pid,
            "hostname": hostname,
            "msg": m
        }

def mk_incoming_request(method, url, host, remote_port):
    rid = next(reqid_iter)
    t0 = now_ms()
    entry = {
        "level": 30,
        "time": t0,
        "pid": pid,
        "hostname": hostname,
        "reqId": rid,
        "req": {
            "method": method,
            "url": url,
            "host": host,
            "remoteAddress": "::1",
            "remotePort": remote_port
        },
        "msg": "incoming request"
    }
    return entry, rid, t0

def mk_request_completed(rid, status_code, started_ms):
    # realistic small response times
    rt = random.uniform(0.8, 40.0) if status_code == 200 else random.uniform(0.8, 300.0)
    return {
        "level": 30,
        "time": started_ms + int(rt),
        "pid": pid,
        "hostname": hostname,
        "reqId": rid,
        "res": {"statusCode": status_code},
        "responseTime": rt,
        "msg": "request completed"
    }

def main():
    random.seed()
    host = "localhost:3000"

    # ensure dir exists
    pathlib.Path(LOG_FILE).parent.mkdir(parents=True, exist_ok=True)
    with open(LOG_FILE, "a", buffering=1) as fh:
        # initial server lines (JSON only; we do NOT emit the plain-text "Created game session..." lines)
        for e in mk_server_listening_entries():
            log_json(e, fh)

        # steady state traffic
        while True:
            # pick between normal GET or auth call
            if random.random() < 0.8:
                method = "GET"
                url, status = random.choice(ROUTES)
            else:
                method, url, status = random.choice(AUTH_ROUTES)

            remote_port = random.randint(53000, 53350)
            inc, rid, t0 = mk_incoming_request(method, url, host, remote_port)
            log_json(inc, fh)
            time.sleep(random.uniform(0.01, 0.05))
            done = mk_request_completed(rid, status, t0)
            log_json(done, fh)

            # pacing
            time.sleep(random.uniform(0.02, 0.15))

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
