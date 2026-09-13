# syntax=docker/dockerfile:1
#
# gemini-web2api-proxy-pool
# One image = gemini-web2api (Gemini Web -> OpenAI API) + easy_proxies
# (sing-box free-node proxy pool), glued by Caddy on Render's single $PORT.
#
#   /v1/*      -> gemini-web2api  :8080   (OpenAI-compatible API)
#   /v1beta/*  -> gemini-web2api  :8080   (Google native API for Gemini CLI)
#   /pool/*    -> easy_proxies    :9091   (proxy-pool panel + Management API)
#   /healthz   -> 200                       (Render health probe)
#
# gemini-web2api 出站 -> http://pool:***@127.0.0.1:2323 (easy_proxies 池入口)
# easy_proxies    出站 -> 订阅/节点(VLESS/VMess/Trojan/SS/Hysteria2 ...)
ARG GEMINI_REPO=https://github.com/Sophomoresty/gemini-web2api
ARG EP_REPO=https://github.com/jasonwong1991/easy_proxies
ARG GEMINI_REF=2bb988bfcbb82a7fab5d2c99aa5560ff40d64f7e
ARG EP_REF=d423519c74603f5a22a7e6f9b9545137cc705a2e
ARG CADDY_VERSION=v2.11.4

# ---- Stage 0: fetch caddy release binary ----------------------------------
FROM alpine:3.20 AS caddy-builder
ARG CADDY_VERSION
RUN apk add --no-cache curl tar \
 && mkdir -p /tmp/caddy /out \
 && curl -fsSL -o /tmp/caddy/caddy.tar.gz "https://github.com/caddyserver/caddy/releases/download/${CADDY_VERSION}/caddy_${CADDY_VERSION#v}_linux_amd64.tar.gz" \
 && tar -xzf /tmp/caddy/caddy.tar.gz -C /out caddy

# ---- Stage 1: build easy_proxies (Go) --------------------------------------
FROM golang:1.24-alpine AS ep-builder
ARG EP_REPO
ARG EP_REF
ARG GOPROXY=https://goproxy.cn,direct

RUN apk add --no-cache git ca-certificates \
 && go env -w GOPROXY="${GOPROXY}"

RUN git clone "${EP_REPO}" /src/easy_proxies \
 && git -C /src/easy_proxies checkout --detach "${EP_REF}"

# Rewrite the panel's absolute /api/* calls to /pool/api/* so it coexists
# under Caddy's /pool/ prefix.
RUN sed -i "s|'/api/|'/pool/api/|g" /src/easy_proxies/internal/monitor/assets/index.html

RUN cd /src/easy_proxies \
 && CGO_ENABLED=0 go build -trimpath -tags "with_utls with_quic with_grpc with_clash_api" -ldflags "-s -w" -o /out/easy_proxies ./cmd/easy_proxies

# ---- Stage 2: runtime -------------------------------------------------------
FROM python:3.12-slim AS runtime

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tzdata supervisor git \
 && rm -rf /var/lib/apt/lists/* \
 && apt-get clean

# gemini-web2api source (pinned), keeping its own single-file + package layout.
ARG GEMINI_REPO
ARG GEMINI_REF
RUN git clone "${GEMINI_REPO}" /src/gemini-web2api \
 && git -C /src/gemini-web2api checkout --detach "${GEMINI_REF}" \
 && mv /src/gemini-web2api/gemini_web2api /app/gemini_web2api \
 && mv /src/gemini-web2api/gemini_web2api.py /app/gemini_web2api.py \
 && rm -rf /src/gemini-web2api \
 && pip install --no-cache-dir httpx "requests>=2.25"
# httpx: true SSE streaming. requests: used by the multimodal/image path.

COPY --from=ep-builder /out/easy_proxies /usr/local/bin/easy_proxies
COPY --from=caddy-builder /out/caddy /usr/local/bin/caddy

COPY Caddyfile /etc/caddy/Caddyfile
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY start.sh /usr/local/bin/start.sh
COPY scripts/ /usr/local/bin/

COPY web/ /srv/portal/

# Copy a pre-rendered config.json so `python -m gemini_web2api` can boot from
# any directory; start.sh always regenerates it from env before exec.
COPY config.example.json /app/config.json

RUN chmod +x /usr/local/bin/start.sh \
 && useradd --system --uid 10001 --home-dir /run/app --shell /usr/sbin/nologin appuser \
 && mkdir -p /run/app \
 && chown -R appuser:appuser /run/app

USER appuser

ENV PORT=8080

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/start.sh"]