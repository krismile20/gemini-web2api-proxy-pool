#!/usr/bin/env python3
# node_finder.py — auto-discover daily free-node subscriptions + reconcile
# baseline config, feeding both into easy_proxies via its Management API.
#
# Two jobs, one daemon:
#   1. DISCOVER: for each NODE_FINDER_SOURCES repo, pick the newest dated node
#      file (e.g. clash20260827.yml), verify the raw link is non-empty, and
#      merge it into the subscription list pushed to easy_proxies. easy_proxies
#      then runs its own health-check / blacklist / fail-over.
#   2. RECONCILE: every interval, read the baseline core settings (listener /
#      pool / sticky / management / log / geoip) written by start.sh and PUT
#      them back to /api/settings + reload if they drifted. Render free
#      instances rebuild /run/app on every cold start, and an upstream
#      subscription reload can roll UI edits back; reconciling to the
#      env-derived baseline makes the pool's durable config explicit and
#      self-healing. Also restore the baseline subscription list if it shrinks.
#
# Secrets never live in this process's environment: config (incl. the management
# password) is read from a JSON file written by start.sh at boot.
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

CONFIG_PATH = os.environ.get("FINDER_CONFIG", "/run/app/finder.json")
STATE_PATH = os.environ.get("FINDER_STATE", "/run/app/.finder_state")
API_ROOT = "https://api.github.com"
RAW_ROOT = "https://raw.githubusercontent.com"
UA = {"User-Agent": "gemini-web2api-proxy-pool/node-finder"}

# A candidate node file is one whose name embeds an 8-digit date (YYYYMMDD)
# and ends in a known proxy config extension.
DATE_FILE_RE = re.compile(r"^(.*?)(\d{8})\.(ya?ml|txt|json)$", re.IGNORECASE)


def log(msg):
    print(f"[node-finder {time.strftime('%H:%M:%S')}] {msg}", flush=True)


## -- HTTP helpers -----------------------------------------------------------

def http(req, timeout=20):
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", "replace"), resp.headers


def http_json(url, timeout=20):
    req = urllib.request.Request(url, headers=dict(UA))
    body, _ = http(req, timeout)
    return json.loads(body)


## -- Discovery --------------------------------------------------------------

def default_branch(repo):
    try:
        data = http_json(f"{API_ROOT}/repos/{repo}")
        return data.get("default_branch", "main")
    except Exception as e:  # noqa: BLE001
        log(f"default_branch for {repo} failed: {e}; assuming main")
        return "main"


def latest_node_files(repo, branch):
    url = f"{API_ROOT}/repos/{repo}/contents/?ref={branch}"
    items = http_json(url)
    dated = []
    for it in items:
        name = it.get("name", "")
        m = DATE_FILE_RE.match(name)
        if m:
            dated.append((m.group(2), name))  # (YYYYMMDD, filename)
    dated.sort(key=lambda x: x[0], reverse=True)
    return [name for _, name in dated]


def discover(sources):
    found = []
    for repo in sources:
        repo = (repo or "").strip()
        if not repo:
            continue
        try:
            branch = default_branch(repo)
            files = latest_node_files(repo, branch)
            if not files:
                log(f"no dated node files in {repo}")
                continue
            # Walk newest -> oldest until we find a non-empty node file:
            # the single newest dated file is often placeholder-empty while the
            # upstream generator is mid-update, so fall back to a recent one.
            picked = None
            for name in files:
                raw = f"{RAW_ROOT}/{repo}/{branch}/{name}"
                try:
                    body, _ = http(
                        urllib.request.Request(raw, headers=dict(UA)), timeout=25
                    )
                    if body.strip():
                        picked = raw
                        log(f"discovered {raw}")
                        break
                    log(f"{raw} is empty, trying older file");
                except Exception as e:  # noqa: BLE001
                    log(f"verify {raw} failed: {e}; trying older file")
            if picked is None:
                log(f"no non-empty node file in {repo}")
                continue
            found.append(picked)
        except Exception as e:  # noqa: BLE001
            log(f"discover {repo} error: {e}")
    return found


## -- Management API ---------------------------------------------------------

def auth(mgmt_base, password):
    if not password:
        return None
    req = urllib.request.Request(
        f"{mgmt_base}/api/auth",
        data=json.dumps({"password": password}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    body, _ = http(req)
    return json.loads(body).get("token")


def _headers(token):
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h


def api_get(mgmt_base, token, path):
    req = urllib.request.Request(f"{mgmt_base}{path}", headers=_headers(token))
    body, _ = http(req)
    return json.loads(body)


def api_put(mgmt_base, token, path, payload):
    req = urllib.request.Request(
        f"{mgmt_base}{path}",
        data=json.dumps(payload).encode(),
        headers=_headers(token),
        method="PUT",
    )
    return http(req)[0]


def api_post(mgmt_base, token, path):
    req = urllib.request.Request(
        f"{mgmt_base}{path}",
        data=b"",
        headers=_headers(token),
        method="POST",
    )
    return http(req)[0]


## -- State / dedup -----------------------------------------------------------

_STATE = {}
# Runtime config, populated once in main(); shared with cycle().
_CFG = {}


def load_state():
    try:
        with open(STATE_PATH) as f:
            _STATE.update(json.load(f))
    except Exception:  # noqa: BLE001
        pass


def save_state():
    try:
        tmp = STATE_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(_STATE, f)
        os.replace(tmp, STATE_PATH)
    except Exception as e:  # noqa: BLE001
        log(f"save state failed: {e}")


def _hash(items):
    h = hashlib.sha256()
    for it in items:
        h.update((it or "").encode("utf-8", "replace"))
        h.update(b"\n")
    return h.hexdigest()


## -- Subscription push -------------------------------------------------------


def get_current_subscriptions(mgmt_base, token):
    """Return the subscription list currently active in easy_proxies."""
    try:
        data = api_get(mgmt_base, token, "/api/subscription/config")
        return [s.strip() for s in (data.get("subscriptions") or []) if s.strip()]
    except Exception as e:  # noqa: BLE001
        log(f"get current subscriptions failed: {e}")
        return []
def push_subscriptions(mgmt_base, token, subs, refresh_interval):
    new_hash = _hash(subs)
    if _STATE.get("sub_hash") == new_hash:
        log(f"subscriptions unchanged ({len(subs)} urls) — skip push")
        return False
    resp = api_put(
        mgmt_base,
        token,
        "/api/subscription/config",
        {"subscriptions": subs, "enabled": True, "interval": refresh_interval},
    )
    _STATE["sub_hash"] = new_hash
    save_state()
    # The PUT response echoes the subscription URLs (which may contain tokens),
    # so never log it verbatim — surface only message/node_count.
    try:
        data = json.loads(resp)
        msg = data.get("message") or data.get("error") or "ok"
        nodes = data.get("node_count")
        log(f"pushed {len(subs)} subscription(s): {msg}" + (f" ({nodes} nodes)" if nodes is not None else ""))
    except Exception:  # noqa: BLE001
        log(f"pushed {len(subs)} subscription(s) (non-JSON response)")
    return True


## -- Core settings reconcile -------------------------------------------------

# Paths inside a settings block whose value is a duration string. The API
# normalizes these to Go duration format ("1h" -> "1h0m0s"), so compare them
# canonically (total seconds) to avoid a permanent, reload-forever false drift.
DURATION_PATHS = {("pool", "blacklist_duration")}


_DUR_TOKEN_RE = re.compile(r"(\d+(?:\.\d+)?)\s*(ns|us|µs|ms|s|m|h|d)?")


def _canon_dur(v):
    """Normalize a Go-style duration ('1h', '1h0m0s', '30m0s', '1m30s') to
    a canonical comparable token. Returns the stripped string when it is not
    a duration, so non-duration values still compare as themselves."""
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return int(v)
    s = (v or "").strip()
    if not s:
        return ""
    mult = {"d": 86400, "h": 3600, "m": 60, "s": 1, "ms": 1e-3, "us": 1e-6, "ns": 1e-9}
    total = None
    pos = 0
    for m in _DUR_TOKEN_RE.finditer(s):
        if m.start() != pos:
            pos = -1
            break
        n = float(m.group(1))
        unit = m.group(2) or "s"
        if unit not in mult:
            pos = -1
            break
        total = (0 if total is None else total) + n * mult[unit]
        pos = m.end()
    if pos != len(s) or total is None:
        return s  # not a duration — compare as-is
    return f"{total:.9f}".rstrip("0").rstrip(".")


def _canon(x, path=()):
    if isinstance(x, dict):
        out = {}
        for k, v in x.items():
            if v is None:
                continue
            out[k] = _canon(v, path + (k,))
        return out
    if path in DURATION_PATHS:
        return _canon_dur(x)
    return x


def _only_known(d, allowed):
    return {k: d[k] for k in allowed if k in d}


def reconcile_core(mgmt_base, token, baseline_settings):
    current = api_get(mgmt_base, token, "/api/settings")

    def _to_settings():
        out = {}
        allowed_root = {
            "external_ip", "probe_target", "skip_cert_verify",
            "mode", "listener", "multi_port", "pool", "sticky",
            "management", "log", "geoip",
        }
        for k in allowed_root:
            if k in baseline_settings:
                out[k] = baseline_settings[k]
        return out

    wanted = _to_settings()

    # Compute a comparable subset from what the API currently returns, against
    # the same model shape. mode/listener/pool/sticky/management/log/geoip are
    # echoed back by /api/settings; external_ip/probe_target/skip_cert_verify
    # are top-level.
    def _cur_subset(cur):
        cur = cur or {}
        subset = {}
        bt = cur.get("mode")
        if bt is not None and "mode" in wanted:
            subset["mode"] = bt
        for key in ("external_ip", "probe_target", "skip_cert_verify"):
            if key in wanted and cur.get(key) is not None:
                subset[key] = cur[key]
        for block in ("listener", "multi_port", "pool", "sticky", "management", "log", "geoip"):
            if block not in wanted:
                continue
            cb = cur.get(block) or {}
            wb = wanted[block]
            # For nested blocks we compare only the keys the baseline models.
            subset[block] = _only_known(cb, set(wb.keys()))
        return subset

    if _canon(_cur_subset(current)) == _canon(wanted):
        log("core settings already at baseline — no reconcile needed")
        return False

    log("core settings drifted; reconciling to baseline")
    api_put(mgmt_base, token, "/api/settings", wanted)
    # After a core settings PUT, reload so the new values take effect.
    try:
        api_post(mgmt_base, token, "/api/reload")
        log("core reconcile: applied settings + reloaded")
    except Exception as e:  # noqa: BLE001
        log(f"core reconcile: settings applied but reload failed: {e}")
    return True


## -- Main loop ---------------------------------------------------------------

def parse_interval(s):
    m = re.match(r"^\s*(\d+)\s*(h|m|s)?\s*$", (s or ""), re.IGNORECASE)
    if not m:
        return 3600
    n = int(m.group(1))
    unit = (m.group(2) or "s").lower()
    return max(60, n * {"s": 1, "m": 60, "h": 3600}[unit])


def main():
    with open(CONFIG_PATH) as f:
        _CFG.update(json.load(f))
    load_state()
    mgmt_base = f"http://{_CFG.get('mgmt_addr', '127.0.0.1:9091')}"
    password = _CFG.get("mgmt_password", "")
    interval = parse_interval(_CFG.get("interval", "1h"))
    _CFG["_mgmt_base"] = mgmt_base
    _CFG["_mgmt_password"] = password
    _CFG["_refresh_interval"] = _CFG.get("refresh_interval", "30m")
    _CFG["_sources"] = [s.strip() for s in _CFG.get("sources", []) if s.strip()]
    _CFG["_baseline"] = [s.strip() for s in _CFG.get("baseline_subscriptions", []) if s.strip()]
    _CFG["_baseline_settings"] = _CFG.get("baseline_settings") or {}

    log(f"sources={_CFG['_sources']} interval={interval}s refresh={_CFG['_refresh_interval']} reconcile={'on' if _CFG['_baseline_settings'] else 'off'}")

    # Run once immediately so a cold start converges before the first interval.
    cycle()

    while True:
        time.sleep(interval)
        cycle()


def cycle():
    mgmt_base = _CFG["_mgmt_base"]
    password = _CFG.get("_mgmt_password", "")
    refresh_interval = _CFG.get("_refresh_interval", "30m")
    sources = _CFG.get("_sources", [])
    baseline = _CFG.get("_baseline", [])
    baseline_settings = _CFG.get("_baseline_settings", {})
    try:
        token = auth(mgmt_base, password)
        if baseline_settings:
            reconcile_core(mgmt_base, token, baseline_settings)
        discovered = discover(sources) if sources else []
        # Merge baseline + auto-discovered + whatever is already active in the
        # pool (e.g. subscriptions added from the /pool/ WebUI). Union keeps
        # UI-added subscriptions instead of letting baseline convergence wipe them.
        current = get_current_subscriptions(mgmt_base, token)
        ui_added = [s for s in current if s not in set(_CFG.get("_baseline", []))]
        combined = sorted(set(baseline) | set(discovered) | set(ui_added))
        if combined:
            push_subscriptions(mgmt_base, token, combined, refresh_interval)
        else:
            log("no subscriptions to push; skipping")
    except Exception as e:  # noqa: BLE001
        log(f"cycle error: {e}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)