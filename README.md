# gemini-web2api-proxy-pool

[gemini-web2api](https://github.com/Sophomoresty/gemini-web2api)(Gemini Web → OpenAI 兼容 API,零成本、免鉴权可选)与
[easy_proxies](https://github.com/jasonwong1991/easy_proxies)(sing-box 内核免费节点代理池)打包进**单个 Docker 镜像**,
适配 [Render](https://render.com) 单端口部署,通过 Caddy 前缀路由聚合两份服务与代理池面板。

## 架构

```
客户端 ──► Render $PORT ──► Caddy(唯一公网出口)
                             ├─ /healthz  → 200(容器存活探针,规避启动期 503)
                             ├─ /v1/*     → gemini-web2api :8080   (OpenAI 兼容 API)
                             ├─ /v1beta/* → gemini-web2api :8080   (Gemini CLI 原生命令)
                             ├─ /pool/*   → easy_proxies :9091   (代理池面板 + 管理 API)
                             └─ /*        → 门户页
gemini-web2api 出站 ──► http://pool:***@127.0.0.1:2323(easy_proxies 池入口,随机口令每次启动生成)
easy_proxies 出站 ──► 订阅/节点(VLESS/VMess/Trojan/SS/Hysteria2...)
```

进程管理:supervisord(进程崩溃独立重启);两个上游仓库 pin 到固定 commit 后构建。
gemini-web2api 无 WebUI(纯 API + `/` JSON 状态),无需 WebUI 前缀补丁;easy_proxies 面板在构建期
打补丁把根绝对路径 `/api/*` 改为 `/pool/api/*`,实现同源前缀共存。

## 环境变量

| 变量 | 必填 | 说明 |
|---|---|---|
| `SERVER_KEYS` | 建议 | Gemini API 鉴权密钥,逗号分隔;留空则 `/v1/*` 匿名开放(不推荐公网) |
| `PROXY_SUBSCRIPTIONS` | 建议 | 代理池订阅链接,逗号分隔(URL 内含 token 属敏感信息) |
| `MGMT_PASSWORD` | **必设** | `/pool/` 面板登录密码;留空会随机生成且无法找回 |
| `GEMINI_COOKIE` | 可选 | Gemini Advanced 账户 cookie(单行 `SID=...; HSID=...; ...`);留空匿名访问(Pro 回落 Flash) |
| `AUTH_USER` | 可选 | 账户下标(登录页 `/u/<index>/` 的 index) |
| `XSRF_TOKEN` | 可选 | 登录后页面源码里的 `SNlM0e`(XSRF)token;认证请求 400 时刷新 |
| `GEMINI_DEFAULT_MODEL` | 可选 | 默认模型,默认 `gemini-3.6-flash` |
| `SUB_REFRESH_INTERVAL` | 可选 | 订阅定时刷新间隔,默认 `30m` |
| `EXTRA_NODES` | 可选 | 手工节点(逗号分隔的 URI),**inline 持久保留**,不受订阅刷新删除 |
| `NODE_FINDER_SOURCES` | 可选 | 自动发现源:逗号分隔的 `owner/repo`,扫描其仓库最新 dated 节点文件(如 `clash20260827.yml`)并自动并入代理池;留空则不自动发现 |
| `NODE_FINDER_INTERVAL` | 可选 | 自动发现/配置收敛周期,默认 `1h`(支持 `30m`/`2h` 等) |

所有密钥只通过 Render Dashboard 注入(render.yaml 中均为 `sync: false`),运行时写入容器内 `/run/app`,
不进镜像层、不打日志。未提供订阅时启动会注入一个占位节点保证进程可引导。

## 客户端配置

任意 OpenAI 兼容客户端:

| 字段 | 值 |
|---|---|
| Base URL | `https://<your-app>.onrender.com/v1` |
| API Key | `SERVER_KEYS` 中的任意一个;未配置则任意/留空 |
| Model | `gemini-3.5-flash-thinking`(或 `gemini-3.6-flash` / `@think=N` 后缀) |

curl:

```bash
curl https://<your-app>.onrender.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-your-key" \
  -d '{"model":"gemini-3.5-flash","messages":[{"role":"user","content":"Hello!"}]}'
```

Gemini CLI 原生协议(零鉴权时):

```bash
export GEMINI_API_KEY=none
export GOOGLE_GEMINI_BASE_URL=https://<your-app>.onrender.com
gemini
```

支持: `/v1/models`、`/v1/chat/completions`(流式 SSE)、`/v1/responses`(Codex CLI)、`/v1beta/models`(Gemini CLI)、工具调用、内置联网。

## 配置持久化模型(免费实例必读)

Render 免费实例 15 分钟无流量会休眠,唤醒时**冷启动新容器**,`/run/app` 被 `start.sh` 重新生成——
因此在 `/pool/` 面板里做的任何修改(节点、设置、订阅)**都是临时的,实例回收即丢失**。
本镜像的"持久配置"只来自环境变量:

- `start.sh` 每次启动把环境变量渲染成基线配置(`config.json` + `easy_proxies.yaml` + `finder.json`);
- 常驻 sidecar `node_finder`(见下)按 `NODE_FINDER_INTERVAL` **周期性把基线配置收敛回管理 API**:
  免费实例上即使你/上游把面板配置改乱,也会在下一个周期回到环境变量定义的状态;
- 手工节点请用 `EXTRA_NODES`(inline 持久),而不是在面板"添加节点";
- Gemini 认证凭据请用 `GEMINI_COOKIE`/`AUTH_USER`/`XSRF_TOKEN`(env),而不是在容器里手动写文件。

### Render 免费部署步骤

1. 打开本仓库 → **Deploy to Render** / 新建 Blueprint 指向该仓库;
2. 在 Render Dashboard 里向下滚动到 **Environment**,逐个填入 `SERVER_KEYS`、`MGMT_PASSWORD`、`PROXY_SUBSCRIPTIONS`(可选 `GEMINI_COOKIE` 等);
3. 部署完成后访问 `<app>.onrender.com/pool/` 用 `MGMT_PASSWORD` 登录代理池面板,`/v1` 即为 API 端点。

免费套餐 512MB:已裁剪 sing-box 编译标签(去 wireguard/gvisor/clash_api)、关闭 GeoIP;
冷启动含订阅抓取 + 首次请求预热,首次就绪约需 20-60s。

## 安全说明

- 公网仅暴露 Caddy 的 `$PORT`,代理池入口(2323)与面板后端全部 loopback 监听
- 池入口带随机认证(`pool:<random>`),即使被探测也无法直连
- gemini-web2api 出站的代理口令只在 `start.sh` 运行时生成并注入 `/run/app/config.json`,不落镜像
- 未设置 `SERVER_KEYS` 时 API 匿名开放(上游默认行为)——公网实例请务必配置

## 目录结构

```
├── Dockerfile          多阶段构建 + 构建期 easy_proxies 面板前缀补丁 + pin commit
├── start.sh            运行时从环境变量生成配置(config.json / easy_proxies.yaml / finder.json)
├── supervisord.conf    caddy / proxy_pool / gemini_api / node_finder 四 program
├── Caddyfile           $PORT 单端口前缀路由
├── web/index.html      门户页
├── config.example.json 镜像内兜底 gemini 配置(启动即会被 start.sh 覆盖)
├── scripts/
│   └── node_finder.py  自动发现器 + 配置收敛:GitHub API 扫最新 dated 节点订阅 → 经 Management API 热载入池
└── render.yaml         Render Blueprint
```