---
name: qqbot
description: >
  在 DSH 会话之间传话（走 dsh web 的 /api Remote RPC）：从 QQ 机器人会话指挥别的会话干活、
  读取别的会话最近说了什么，以及让别的会话主动给 QQ 用户发消息（经 hub 会话转达）。
  Use when asked to send an instruction/message into another DSH session, to check what another
  session is doing, to let a background session report back to the QQ chat, or to relay
  cross-session notices between the Web GUI and the QQ bot.
---

# QQ 机器人 / 跨会话传话

DSH 里所有会话（Web GUI 的、QQ 机器人的）都由**同一个 `dsh web` 宿主进程**持有，宿主在
`$DSH_WEB_URL`（默认 `http://127.0.0.1:3080`）上暴露 `/api/<ns>/<method>` 的 Remote RPC。会话之间没有内置的"切过去"或
"发消息"工具，但可以用这个 RPC 互相投递，本 skill 就是这套做法的说明书 + 一个脚本。

| 角色 | 是什么 | 怎么认 |
|---|---|---|
| **hub** | 绑定 QQ 的那条会话，`~/.dsh-qqbot/model-prefs.json` 里登记的那个 sessionId | `dsh_session.py hub` |
| **对端** | 任何其它会话（GUI 里开的、fork 出来的、subagent） | `dsh_session.py list` |
| **QQ 出口** | hub 会话里产生的 assistant 文本，由 qqbot 插件按 `replyTarget` 推回 QQ | 自动，不需要额外动作 |

```text
   QQ 用户 ◄──qqbot 插件── hub 会话（我）
                              ▲   │
                    send hub  │   │  send <target>
                              │   ▼
                          对端会话（GUI / 后台）
```

## 快速开始

脚本：`scripts/dsh_session.py`（无第三方依赖，python3 + curl + zstd + screen）。

```bash
# <skill-dir> = 本 SKILL.md 所在目录：工作区的 .agents/skills/<name>/，或全局的 ~/.dsh/skills/<name>/
S=<skill-dir>/scripts/dsh_session.py

python3 $S whoami                 # 自己是谁、hub 是谁
python3 $S list                   # ★ 标出 hub；running/agent 说明是否活着
python3 $S send hub "构建完了，产物在 /tmp/build.log"      # 往 hub 投一句话（会推到 QQ）
python3 $S send "<会话标题>" "帮我看下这个报错"              # 用标题子串选会话
python3 $S tail "<会话标题>" 6                              # 看对端最近说了什么
python3 $S call session/list '{"_request":{}}'             # 需要时直接打任意 Remote 方法
```

**验收投递**：`send` 成功只代表宿主收了（`accepted:true`），对方是否真的在动、回了什么，要看
`tail`；对端若是 GUI 会话，用户屏幕上会实时出现这条消息。

## 方向一：我在 hub，指挥别的会话

适用：QQ 里一句话，让某个 GUI 会话 / 后台会话去做事、汇报进度。

1. 选目标：`list` 里按标题认；`running=True` 表示它正有 turn 在跑（新建的 `running=False` 也正常）。
2. `send <target> "<指令>"`。默认 `mode=queue`：如果对端正忙，消息排在它当前 turn 之后处理，
   不会打断；用 `--steer` 才会插进当前 turn（对方会立刻看到这段话）。
3. 跟进：`tail <target> N` 读它最近的 user/assistant 文本（直接解压会话日志，不惊动它）。
4. 对端的回复**不会**自动回到 QQ；要它汇报，就在指令里写明，比如：
   `"做完后用 dsh_session.py send hub '完成：<一句话结论>'"`。
5. 报给用户：把 `tail` 看到的关键结论转述，或直接把对端的话作为内容 `send hub` 回来。

**指令要写成"一个人的一句话"**：它就是一条真·用户消息，对端会按自己的 preset 全套工具执行，
语气、追问、审批都按那边规则走。不要写成"系统通知"，也不要在里面编造它没有的上下文。

## 方向二：别的会话主动找我，我再转给 QQ 用户

适用：长任务在别的会话里跑（构建、训练监控、批处理），完成或出错时要主动通知手机。

在**对端会话**里执行（它自己跑 bash 时有 `$DSH_SESSION_ID`，指向它自己）：

```bash
python3 <skill-dir>/scripts/dsh_session.py send hub "【构建完成】编译通过，日志 /tmp/build.log"
```

之后：hub 会话收到一条用户消息 → 起一个 turn → 我的回复由 qqbot 插件推给 QQ 用户。

**硬前提：hub 会话在 qqbot 插件里还活着。** 插件默认 `sessionIdleTimeout = 30 min`，闲置超时后
会把记录回收；此后再往 hub 投消息，turn 照样会跑、日志照样写，但插件的
`findBySessionId()` 找不到记录 → **不会推送到 QQ**（等用户下次在 QQ 说话时才被 resume，届时
这段内容会作为历史出现在上下文里）。所以：

- hub 侧 30 分钟内有过 QQ 消息 → 通知可靠；
- 超过 30 分钟没人在 QQ 说话 → 通知大概率只落在日志里。要可靠就等用户开口后立刻发，
  或者把 hub 的 `sessionIdleTimeout` 调大（`$DSH_PROFILE_DIR/cordis.patch.yml` 的 `im-qqbot` 段）。
- 判断办法：`send hub` 后在自己的 `tail` 里看到这条消息、再等一个 turn 结束；如果 QQ 没响，
  先怀疑就是被回收了，别去改 RPC 代码。

跨会话投递是**单向、无回执**的：`accepted:true` 只说明进了 inbox。要求确认就再发一条。

## 这些值从哪来（本 skill 不记录任何实际值）

本 skill 里不放 token、session id、openid、摘要之类的真实值，一律现取：

| 需要的东西 | 怎么取 |
|---|---|
| 自己的 session id | `echo $DSH_SESSION_ID`（bash 工具里自带） |
| hub（QQ 会话）id | `dsh_session.py hub`；原理是读 `~/.dsh-qqbot/model-prefs.json` 的 `sessionIds` 值（每个 QQ peer 一条） |
| 目标会话 id | `dsh_session.py list`；或 `~/.dsh/storages/session_projcache/sessions/*.json` 的文件名（上面有标题可反查） |
| launch token | `dsh web` 启动时 stdout 打印的 `?token=`；宿主跑在 screen 里就 `screen -S <name> -X hardcopy -h /tmp/x` + `grep -o 'token=[A-Za-z0-9_-]*' /tmp/x \| tail -1`；也可 `export DSH_WEB_TOKEN=...` 手动给 |
| QQ appId / openid | appId 在 profile patch 的 `im-qqbot.appId`；openid 只出现在 `model-prefs.json` 的会话 key 里或入站事件里——需要时才去看，别抄进文档 |
| 宿主地址 / profile 路径 | `$DSH_WEB_URL`、`$DSH_PROFILE_DIR`、`$DSH_HOME` |
| 某个 Remote 方法的 args 字段名 | 查生成的 descriptor（取 `node_modules` 的 `DSH_NM` 小技巧见 `references/protocol.md` 第 4 节），在该方法所属 `dsh-api-*/lib/typert.host.js` 里搜 `'<ns>/<method>'` |

## 解析目标

| 写法 | 含义 |
|---|---|
| `hub` | QQ 绑定会话；优先 `$DSH_HUB_SESSION`，否则读 `~/.dsh-qqbot/model-prefs.json` 的 `sessionIds` |
| `me` / `self` | `$DSH_SESSION_ID`（bash 工具里就有） |
| `<完整 id>` | 原样 |
| `<id 前缀>` | 唯一前缀即可；带不带 `session-` 前缀都行（老会话有前缀，新会话没有） |
| `<标题子串>` | 不区分大小写；多个命中会打印候选并退出码 2 |

会话 id 两种形态并存：`session-<uuid>`（Web/API 创建的）与 `<uuid>`（QQ 会话、旧格式）。
`~/.dsh/storages/session_projcache/sessions/<id>.json` 里有标题，可按标题反查 id。

## 常见坑（都踩过）

| 现象 | 原因 / 处理 |
|---|---|
| `HTTP 401 unauthorized` | cookie 丢了或宿主换进程了。脚本会自动重抓 token；仍失败就 `export DSH_WEB_TOKEN=<token>`（token 见下） |
| `HTTP 403 forbidden` | Host/Origin 不匹配。必须打 `$DSH_WEB_URL` 里的 loopback 地址，不要用别的网卡 IP 或域名 |
| `HTTP 404 not found` | 方法名/命名空间写错，或该插件没挂。端点格式固定 `/<ns>/<method>`，如 `session/prompt` |
| `gateway/arguments-invalid: missing "_request"` | `session/list` 的参数名是 `_request` 而不是 `request`；每个方法的 wire 字段名看 `node_modules/@*/dsh-api-*/lib/typert.host.js` |
| `Remote payload must contain exactly one plain-object args field` | envelope 必须写成 `{"type":"client-request","rpcId":...,"method":...,"payload":{"args":{...}}}` |
| `gateway/definition-unavailable` | 会话对应的服务没起来（例如 web profile 未加载 session-controller） |
| 抓不到 token | token 只打印在 `dsh web` 自己的终端上；脚本用 `screen -X hardcopy` 从 screen 缓冲里取最后一个。不是 screen 起的就手动给 `DSH_WEB_TOKEN` |
| `session.lock` 被占用 / `dsh headless --session-id` 报错 | 单写租约：GUI 里开着的会话被 web 宿主持有，别的进程不能接管。见 `references/protocol.md` |

## 红线

- **投递 = 真的让那边的 agent 动手**，不是贴便签。目标会话有 `danger-full-access` 时等于给它
  开新任务，措辞要清楚、范围要小。
- 别往不认识/不相关的会话乱投；`list` 里会话很多，按标题确认后再发。
- 别把凭证（token、cookie）写进消息、日志、skill；脚本把 cookie 放 `~/.cache/dsh-session-rpc/`
  且 `chmod 600`，token 只缓存同一处。
- 一次投一条，等对方 turn 结束再投下一条；连发会把 inbox 堆成串行任务。
- 用户说"发一条试试"这类验证，**只发一条**，别刷屏。

## 参考

- `references/protocol.md`：/api 的线格式、`session/prompt` 字段、错误码、token/cookie 机制、
  单写租约与 headless 接管失败的原因、会话文件布局。
- 现成实现可对照：`$DSH_PROFILE_DIR/node_modules/@*/dsh-qqbot`
  （`dist/session/session-manager.js` 看 QQ peer ↔ session 映射，`dist/transport/outbound.js`
  看 assistant 文本如何按 `replyTarget` 推回 QQ）。
