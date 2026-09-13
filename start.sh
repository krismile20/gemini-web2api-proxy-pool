#!/bin/sh
# Runtime entrypoint: generate configs from environment variables, then exec supervisord.
# Secrets are only read here and written to /run/app (ephemeral path). They are
# never echoed to stdout/stderr and never baked into the image.
set -eu

APP_DIR=/run/app
mkdir -p "$APP_DIR"

export GEMINI_LISTEN="${GEMINI_LISTEN:-127.0.0.1:8080}"
export EP_POOL_ADDR="${EP_POOL_ADDR:-127.0.0.1:2323}"
export EP_MGMT_ADDR="${EP_MGMT_ADDR:-127.0.0.1:9091}"
export SUB_REFRESH_INTERVAL="${SUB_REFRESH_INTERVAL:-30m}"

export NODE_FINDER_SOURCES="${NODE_FINDER_SOURCES:-}"
export NODE_FINDER_INTERVAL="${NODE_FINDER_INTERVAL:-1h}"
export EXTRA_NODES="${EXTRA_NODES:-}"
python3 <<'PYEOF'
import json
import os
import pathlib
import secrets

app = pathlib.Path("/run/app")
env = os.environ


def split_csv(value):
    return [item.strip() for item in (value or "").split(",") if item.strip()]


server_keys = split_csv(env.get("SERVER_KEYS"))
subscriptions = split_csv(env.get("PROXY_SUBSCRIPTIONS"))
extra_nodes = split_csv(env.get("EXTRA_NODES"))
mgmt_password = env.get("MGMT_PASSWORD") or secrets.token_urlsafe(18)
pool_user = "pool"
pool_pass = env.get("POOL_PASS") or secrets.token_urlsafe(12)

proxy_host, _, proxy_port = env.get("EP_POOL_ADDR", "127.0.0.1:2323").rpartition(":")

# ---- gemini-web2api config -------------------------------------------------
gemini_config = {
    "port": int(env.get("GEMINI_PORT", "8080")),
    "host": "0.0.0.0",
    "retry_attempts": int(env.get("RETRY_ATTEMPTS", "3") or 3),
    "retry_delay_sec": int(env.get("RETRY_DELAY_SEC", "2") or 2),
    "request_timeout_sec": int(env.get("REQUEST_TIMEOUT_SEC", "180") or 180),
    "gemini_bl": env.get("GEMINI_BL", "boq_assistant-bard-web-server_20260716.08_p0"),
    "auth_user": env.get("AUTH_USER") or None,
    "xsrf_token": env.get("XSRF_TOKEN") or None,
    "default_model": env.get("GEMINI_DEFAULT_MODEL", "gemini-3.6-flash"),
    "log_requests": env.get("LOG_REQUESTS", "").lower() in ("1", "true", "yes"),
    "temporary_chats": env.get("TEMPORARY_CHATS", "").lower() in ("1", "true", "yes"),
}
# api_keys: SERVER_KEYS is the single source; if empty, gemini-web2api runs
# with auth disabled (匿名). Never write a placeholder key.
gemini_config["api_keys"] = server_keys

# Gemini Advanced cookie -> single-line Netscape-ish format in /run/app/cookie.txt
cookie = env.get("GEMINI_COOKIE")
gemini_config["cookie_file"] = "/run/app/cookie.txt"
if cookie:
    (app / "cookie.txt").write_text(cookie.strip() + "\n")
else:
    # A token file with no cookie -> load_cookie() returns empty -> anonymous.
    (app / "cookie.txt").write_text("")

# Route Gemini's outbound traffic through the local proxy pool.
gemini_config["proxy"] = "http://%s:%s@%s:%s" % (pool_user, pool_pass, proxy_host, proxy_port)

(app / "config.json").write_text(json.dumps(gemini_config, indent=2))


def yq(text):
    return json.dumps(text)


# ---- easy_proxies config ----------------------------------------------------
lines = [
    "# Generated at container start by start.sh - do not edit",
    "mode: pool",
    "log_level: %s" % yq(env.get("LOG_LEVEL", "info")),
    "log:",
    "  output: stdout",
    "",
    "listener:",
    "  address: %s" % yq(proxy_host),
    "  port: %s" % proxy_port,
    "  username: %s" % yq(pool_user),
    "  password: %s" % yq(pool_pass),
    "",
    "pool:",
    "  mode: random",
    "  failure_threshold: 3",
    "  blacklist_duration: 1h",
    "  retry_enabled: true",
    "  retry_attempts: 3",
    "",
    "sticky:",
    "  enabled: false",
    "",
    "management:",
    "  enabled: true",
    "  listen: %s" % yq(env.get("EP_MGMT_ADDR", "127.0.0.1:9091")),
    "  probe_target: http://cp.cloudflare.com/generate_204",
    "  password: %s" % yq(mgmt_password),
    "",
    "dns:",
    "  server: 1.1.1.1",
    "  fallback_servers:",
    "    - 8.8.8.8",
    "  port: 53",
    "  strategy: prefer_ipv4",
    "",
    "geoip:",
    "  enabled: false",
    "",
    "subscription_refresh:",
    "  enabled: true",
    "  interval: %s" % yq(env.get("SUB_REFRESH_INTERVAL", "30m")),
]

if subscriptions:
    lines += ["", "subscriptions:"]
    lines += ["  - %s" % yq(url) for url in subscriptions]
else:
    lines += ["", "subscriptions: []"]

if extra_nodes:
    lines += ["", "nodes:"]
    lines += ["  - uri: %s" % yq(uri) for uri in extra_nodes]
elif not subscriptions:
    # No subscriptions and no extra nodes: keep the placeholder so the process
    # can boot; the user adds a real source via env (PROXY_SUBSCRIPTIONS /
    # EXTRA_NODES / NODE_FINDER_SOURCES) or, transiently, via the /pool/ UI.
    lines += [
        "",
        "nodes:",
        "  - uri: %s" % yq(
            "http://127.0.0.1:9#placeholder-add-your-subscription-in-the-webui-at-/pool/"
        ),
    ]

lines.append("")
(app / "easy_proxies.yaml").write_text("\n".join(lines))


def dur(s):
    """Normalize a Go duration (30m / 1h / 24h0m0s) to seconds or ''."""
    import re
    m = re.fullmatch(r"\s*(\d+)\s*(ns|us|μs|ms|s|m|h|d)?\s*", (s or ""))
    if not m:
        return ""
    n, unit = int(m.group(1)), (m.group(2) or "s")
    mult = {"ns": 1e-9, "us": 1e-6, "ms": 1e-3, "s": 1, "m": 60, "h": 3600, "d": 86400}[unit]
    return str(int(n * mult))


# Baseline core settings snapshot. The /pool/ management API reads/writes these
# fields; node_finder reconciles them back to these env-derived values each
# interval so a transient UI edit or an upstream subscription-reload rollback
# cannot silently change the pool's durable configuration.
baseline_settings = {
    "mode": "pool",
    "external_ip": env.get("EXTERNAL_IP", ""),
    "probe_target": env.get("PROBE_TARGET", "http://cp.cloudflare.com/generate_204"),
    "skip_cert_verify": env.get("SKIP_CERT_VERIFY", "").lower() in ("1", "true", "yes"),
    "listener": {
        "address": proxy_host,
        "port": int(proxy_port or 2323),
        "username": pool_user,
        "password": pool_pass,
    },
    "pool": {
        "mode": env.get("POOL_MODE", "random"),
        "failure_threshold": int(env.get("POOL_FAILURE_THRESHOLD", "3") or 3),
        "blacklist_duration": env.get("POOL_BLACKLIST_DURATION", "1h"),
    },
    "sticky": {
        "enabled": env.get("STICKY_ENABLED", "").lower() in ("1", "true", "yes"),
        "port": int(env.get("STICKY_PORT", "0") or 0),
    },
    "management": {
        "listen": env.get("EP_MGMT_ADDR", "127.0.0.1:9091"),
        "password": mgmt_password,
        "probe_concurrency": int(env.get("PROBE_CONCURRENCY", "32") or 32),
    },
    "log": {
        "output": env.get("LOG_OUTPUT", "stdout"),
        "max_size": int(env.get("LOG_MAX_SIZE", "50") or 50),
        "max_backups": int(env.get("LOG_MAX_BACKUPS", "3") or 3),
        "max_age": int(env.get("LOG_MAX_AGE", "7") or 7),
        "compress": env.get("LOG_COMPRESS", "").lower() in ("1", "true", "yes"),
    },
    "geoip": {
        "enabled": False,
    },
}

finder_cfg = {
    "mgmt_addr": env.get("EP_MGMT_ADDR", "127.0.0.1:9091"),
    "mgmt_password": mgmt_password,
    "interval": env.get("NODE_FINDER_INTERVAL", "1h"),
    "refresh_interval": env.get("SUB_REFRESH_INTERVAL", "30m"),
    "sources": split_csv(env.get("NODE_FINDER_SOURCES")),
    "baseline_subscriptions": subscriptions,
    "baseline_settings": baseline_settings,
}
(app / "finder.json").write_text(json.dumps(finder_cfg, indent=2))
PYEOF

unset SERVER_KEYS PROXY_SUBSCRIPTIONS MGMT_PASSWORD GEMINI_COOKIE XSRF_TOKEN POOL_PASS || true
unset NODE_FINDER_SOURCES NODE_FINDER_INTERVAL EXTRA_NODES || true


exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf