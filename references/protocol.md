# /api Remote RPC 线格式与相关机制

环境：`dsh` 的 web profile（本项目用 npx 渠道安装），宿主地址取 `$DSH_WEB_URL`（默认
`http://127.0.0.1:3080`）。下文结论均在 web profile 上实测过；标「未验证」的为读代码推断。
文中不写任何真实 token / session id / openid / 摘要值，需要时按下面的方法现取。

## 1. 认证：launch token → cookie

`dsh web` 启动时在 stdout 打印

```
dsh web: http://127.0.0.1:3080/?token=<launch-token>
```

token 每个宿主进程一套，只存在内存里（不落盘、不在 `environ`、不在 argv）。换 cookie：

```bash
curl -sS --noproxy '*' -c /tmp/c.txt -o /dev/null -w '%{http_code}\n' \
     "http://127.0.0.1:3080/?token=$TOKEN"      # → 303，Set-Cookie: dsh-auth-<hash>=v1.<b64>.<hmac>
curl -sS --noproxy '*' -b /tmp/c.txt ...            # 之后用这个 jar
```

- cookie 名 `dsh-auth-<16位>`，`HttpOnly; SameSite=Strict`，默认 30 天，绑定 authority（host:port）。
- 取 token 的可靠办法：宿主跑在 screen 里，`screen -S <name> -X hardcopy -h /tmp/x` 导出终端缓冲，
  再 `grep -o 'token=[A-Za-z0-9_-]*' | tail -1`（脚本自动做，注意会闪一下屏）。
  不是 screen 起的就 `export DSH_WEB_TOKEN=...`。
- 代理坑：环境里有全局 `http_proxy` 时，访问 loopback 必须 `--noproxy '*'`（或保证 `NO_PROXY` 命中）。

## 2. 请求 / 响应

`POST /api/<ns>/<method>`，`content-type: application/json`：

```json
{"type": "client-request", "rpcId": "<任意 uuid>", "method": "<ns>/<method>", "payload": {"args": {...}}}
```

- `payload` 必须**恰好**有一个 `args` 字段（plain object），否则
  `Remote payload must contain exactly one plain-object args field`。
- `args` 的键是**wire 字段名**，必须与 descriptor 完全一致（多一个、少一个都报
  `gateway/arguments-invalid`）。字段名来自生成的 `typert.host.js`，见第 4 节。
- 响应体：

```json
{"type": "server-response", "rpcId": "...", "result": {"ok": true, "value": {...}}}
{"type": "server-response", "rpcId": "...", "result": {"ok": false, "error": {"code": "...", "message": "...", "details": {}}}}
```

- HTTP 状态：200 正常（业务失败也是 200，看 `result.ok`）、401 未认证、403 Host/Origin 不在信任集、
  404 端点未注册。
- 非 owner 的 peer 还要过 `remoteAccess` 策略；用 launch token 换来的 peer 是 `owner`，不拦。
- origin 校验只认 loopback/`--trusted-host` 声明的 authority，所以打 `127.0.0.1` 或
  `localhost`，别用网卡 IP。

## 3. `session/prompt`（投递消息的唯一入口）

```json
{
  "request": {
    "requestId": "<uuid，会写进日志的 user-rpc rpcId>",
    "sessionId": "<目标 session id>",
    "mode": "queue",                       // "queue" 排到当前 turn 之后 | "steer" 插进当前 turn
    "clientTimeZone": "<IANA 时区，可选>",
    "content": [{"type": "text", "text": "..."}]
  }
}
```

- `content` 是 part 数组：`text` / `image`(`mediaType`+`data` base64) / `file`(`receiptId`)；
  至少一个非空白 part。
- 返回值 `{"accepted": true}` 只表示进了目标 agent 的 inbox；**不**表示对方已处理完。
- `mode=queue` 在对方 turn 运行中会把消息排到下一 turn，不打断；`steer` 立即插话。
- 已停止/被 idle 回收的会话也可以投——宿主会 resume 它。

## 4. 其它常用方法（namespace 都是 `session`）

| 方法 | args 键 | 干嘛 |
|---|---|---|
| `session/list` | `_request: {}` | 列出会话（**注意是 `_request`**） |
| `session/page` | `request: {address:{kind:"session",sessionId}, throughSeq, beforeSeq?, maxMessages?}` | 读历史页 |
| `session/rename` | `request: {sessionId, title}` | 改标题（`send` 里用标题定位很方便） |
| `session/fork` | `request: {sessionId, atSeq?}` | fork 出新会话 |
| `session/cancel` | `request: {sessionId}` | 取消当前 turn |
| `session/search` | `request: {query}` | 全文本搜索 |
| `session/selectModel` | `request: {sessionId, provider, model}` | 换模型 |

`session/list` 返回 `{items:[{sessionId, running, agentAvailable, updatedAt, blank, cwd, ...}]}`，
**没有标题**：标题在 projcache（第 6 节）或 `session/page` 的 projections 里。

`args` 键名不统一是硬坑：`session/list` 的形参叫 `_request`，`session/prompt`/`session/page`
的形参叫 `request`。判断依据是生成的 descriptor 里该端点的 `parameters[].name`：

```bash
# dsh 安装目录里的 node_modules（npx 缓存 / 全局装都适用）
DSH_NM=$(dirname "$(readlink -f "$(command -v dsh)")")
while [ "$(basename "$DSH_NM")" != node_modules ]; do DSH_NM=$(dirname "$DSH_NM"); done
grep -n "'session/prompt'" -A 12 "$DSH_NM"/@*/dsh-api-session-controller/lib/typert.host.js
```

（包名随端点所属服务变，例如 `session/*` 在 `dsh-api-session-controller`。）

## 5. 单写租约、headless 接管

- 每条会话有自己的 `session.lock`，宿主对**打开中/活跃**的会话持有 `flock`（`dsh-session-persistence-jsonl`
  的非阻塞独占租约，文件 `~/.dsh/sessions/<slug>/<id>/session.lock`）。所以 GUI 里开着的会话，
  另一个进程接管会失败：这就是"两个 agent 不会同时写一份日志"的保护。
- `dsh headless --session-id <id> "..."` 本可追加一轮，但有两个额外门槛：租约（上面）和
  `assertAdoptable()` 的 preset 门禁（某些部署会给 `dsh-headless` 打补丁拆掉门禁；但 `npm exec`
  的完整性校验会把补丁还原，需要重新打）。用之前先确认这两道门都存在：`exec 8<> 锁文件` 试
  `flock -n`，以及 grep 一下 `dsh-headless/lib/index.js` 里有没有本地补丁标记。
- RPC 投递不受租约影响：消息进入的是**同一个宿主进程内**的 agent，写者唯一。

## 6. 会话文件与标题

```
~/.dsh/sessions/<cwd-slug>/<session-id>/session.v4.jsonl.zstd   # 追加式 JSONL，zstd 分帧
~/.dsh/storages/session_projcache/sessions/<session-id>.json    # 折叠后的标题/用量/权限等
```

- 日志每行一个事件：`user/message`、`assistant/message`、`turn/start|end`、`tool/call|result`、
  `session/title`、`agent/inbox/spliced`（投递先进 inbox，再被 consume 成 `user/message`）。
- `user/message` 的 `data.content` 直接是 parts，`source.kind` 可能是 `user` / `time-context` /
  `runtime-context` / `user-approval` —— 只有 `kind=="user"` 才是人/别的会话说的话。
- `assistant/message` 的内容在 `data.message.content`（多一层 `message`，和 user 不对称）。
- 标题：`projcache` 的 `record.rows.title.val`，文件按会话 id 命名，可离线查。

## 7. QQ 侧：会话映射与出口

- 映射：`~/.dsh-qqbot/model-prefs.json` 的 `sessionIds`，键是会话 key
  `qqbot:<appId>:<c2c|group>:<openid>`，值是 sessionId（fork 后更新）。形状：

  ```json
  {"sessionIds": {"qqbot:<appId>:<scope>:<openid>": "<session-id>"}}
  ```

  真实值直接读文件或让脚本解析，不要抄进任何文档：

  ```bash
  python3 <skill-dir>/scripts/dsh_session.py hub       # 只打印 hub 的 session id
  python3 -c 'import json,os;d=json.load(open(os.path.expanduser("~/.dsh-qqbot/model-prefs.json")));print(*d["sessionIds"], sep="\n")'
  ```

- 本地补丁（部署相关，插件升级后会被 pnpm 重链覆盖，重跑启动脚本可恢复）：

  | 文件 | 作用 |
  |---|---|
  | `dist/transport/send-fallback.js` | `sendWithFallback()`：被动 markdown → 主动 markdown → 主动纯文本，三路都失败才报错 |
  | `dist/transport/outbound.js` | `send()` 改走 `sendWithFallback` |
  | `dist/transport/outbound-buffer.js` | 流式降级到静态发送也走 `sendWithFallback`（`streaming=true` 时的实际路径） |
  | `dist/media/send-text-tool.js` | 新增 `qqbot_send_text` 工具：显式 target → 主动消息（无 msg_id） |
  | `dist/gateway/bootstrap.js` | 注册该工具 |

  启动脚本（`scripts/dsh-web-start.sh`）里对应的幂等函数是 `patch_qqbot_proactive` /
  `patch_qqbot_send_text`，跑 `--patch-only` 即可补齐；脚本末尾还会对补丁文件做一次
  `node --check`。`dsh-web-start.sh` 只做三件事：环境代理、`ws` 补丁、qqbot 补丁，
  不写任何凭据；`QQBOT_PKG` / `DSH_NPM_PKG` 可用环境变量覆盖。

- 出口：`dist/transport/outbound.js` 的 `route(session, raw)` 按 `session.header.id` 找
  `manager.findBySessionId()`，命中就把 `assistant/chunk`、`assistant/message`、`turn/end`
  按记录的 `replyTarget`（c2c/group + msgId）推送。**所以任何来源触发的 turn 都会推回 QQ**，
  不要求这条 turn 是由 QQ 消息发起的。
- 回收：`sessionIdleTimeout` 默认 30 分钟。被 `IdleEvictor` 回收后记录从 map 里删掉，
  `route()` 找不到记录 → 静默丢弃（回复只留在日志里）。这就是"别的会话通知 QQ 有时收不到"的唯一原因。

## 8. 安全

- cookie/token 等价于宿主 owner 权限：能读所有会话、能投消息。只放 `~/.cache/dsh-session-rpc/`
  （`chmod 600`），不要进 git、不要贴进消息。
- 投递消息会在目标会话里落一条**永久的用户消息**并触发 turn；对端可能据此改文件、跑命令。
- `danger-full-access` 是这个 profile 的默认权限，没有审批确认兜底。
