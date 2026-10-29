#!/usr/bin/env python3
"""dsh_session.py — 跨会话传话工具（dsh web `/api` Remote RPC 客户端）

为什么要它：dsh 没有「切换会话」或「给别的会话发消息」的模型工具。所有会话都由同一个
`dsh web` 宿主进程持有，宿主在 `$DSH_WEB_URL` 上暴露 /api/<ns>/<method> 的 RPC，
本脚本就是那个极小客户端：拿 launch token 换 cookie，然后 POST 一条 client-request。

子命令
------
  list [--all]            列出会话：id / 标题 / 是否活着
  hub                     打印 QQ 机器人会话（hub）的 session id
  whoami                  打印自己的 id（$DSH_SESSION_ID）与 hub
  send <target> <text>    向目标会话投一条用户消息（默认 mode=queue）
                          --steer  改为插话（对方正在跑 turn 时插进当前 turn）
                          --dry-run 只打印将要发送的 JSON，不发
  call <ns/method> <args> 直接调任意 Remote 方法；args 为 JSON 文本或 @文件
  tail <target> [n]       打印目标会话最近 n 条 user/assistant 消息（默认 8）

target 写法
-----------
  hub / me / self          hub = QQ 绑定的那个会话；me = 自己
  <session id>             完整 id，或唯一前缀（可带/不带 "session-" 前缀）
  <标题子串>               不区分大小写的标题匹配；多个命中会列出来并报错

示例
----
  dsh_session.py list
  dsh_session.py send hub "构建完了，日志在 /tmp/build.log"
  dsh_session.py send "<会话标题>" "帮我看下构建日志"
  dsh_session.py tail "<会话标题>" 5

退出码：0 成功；1 RPC 失败；2 目标解析歧义/不存在；3 环境问题（拿不到 token 等）。
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import uuid

HOME = os.path.expanduser("~")
CACHE_DIR = os.path.join(HOME, ".cache", "dsh-session-rpc")
TOKEN_FILE = os.path.join(CACHE_DIR, "token")
COOKIE_FILE = os.path.join(CACHE_DIR, "cookie")
PREFS = os.path.join(HOME, ".dsh-qqbot", "model-prefs.json")
PROJCACHE = os.path.join(HOME, ".dsh", "storages", "session_projcache", "sessions")
SESSIONS_ROOT = os.path.join(HOME, ".dsh", "sessions")

CURL = ["curl", "-sS", "--noproxy", "*", "-m", "60"]


# ---------------------------------------------------------------- 基础工具
def die(code: int, msg: str) -> "NoReturn":
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def base_url() -> str:
    return (os.environ.get("DSH_WEB_URL") or "http://127.0.0.1:3080").rstrip("/")


def ensure_cache_dir() -> None:
    os.makedirs(CACHE_DIR, mode=0o700, exist_ok=True)


def read_file(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def write_private(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, 0o600)


# ---------------------------------------------------------------- 会话目录
def session_file(sid: str) -> str | None:
    hits = glob.glob(os.path.join(SESSIONS_ROOT, "*", sid, "session.v4.jsonl.zstd"))
    return hits[0] if hits else None


def titles() -> dict[str, str]:
    """id -> 标题。直接读 projcache，不需要 RPC，也不需要会话活着。"""
    out: dict[str, str] = {}
    for path in glob.glob(os.path.join(PROJCACHE, "*.json")):
        sid = os.path.basename(path)[: -len(".json")]
        try:
            with open(path, encoding="utf-8") as fh:
                rec = json.load(fh)
            title = rec.get("record", {}).get("rows", {}).get("title", {}).get("val")
        except (OSError, ValueError):
            continue
        if isinstance(title, str) and title:
            out[sid] = title
    return out


def hub_id() -> str | None:
    """QQ 机器人会话 id：优先环境变量，其次 qqbot 插件记录的 per-peer sessionId。"""
    env = os.environ.get("DSH_HUB_SESSION")
    if env:
        return env.strip()
    try:
        with open(PREFS, encoding="utf-8") as fh:
            ids = list(json.load(fh).get("sessionIds", {}).values())
    except (OSError, ValueError):
        return None
    return ids[0] if len(ids) == 1 else (ids[0] if ids else None)


def resolve(target: str) -> str:
    """把 target 解析成完整 session id。"""
    target = target.strip()
    low = target.lower()
    if low in ("me", "self", "我"):
        sid = os.environ.get("DSH_SESSION_ID")
        if not sid:
            die(3, "拿不到自己的 session id（$DSH_SESSION_ID 为空）")
        return sid
    if low == "hub":
        sid = hub_id()
        if not sid:
            die(3, "解析不到 hub 会话：$DSH_HUB_SESSION 未设置，且 ~/.dsh-qqbot/model-prefs.json 里没有 sessionIds")
        return sid

    ids = set(titles()) | {os.path.basename(p) for p in glob.glob(os.path.join(SESSIONS_ROOT, "*", "*"))}
    if target in ids:
        return target

    norm = lambda s: s[len("session-"):] if s.startswith("session-") else s  # noqa: E731
    tnorm = norm(target)
    prefixed = [i for i in ids if norm(i) == tnorm]
    if len(prefixed) == 1:
        return prefixed[0]
    prefix = sorted(i for i in ids if norm(i).startswith(tnorm))
    if len(prefix) == 1:
        return prefix[0]

    tmap = titles()
    hits = [(i, t) for i, t in tmap.items() if low in t.lower()]
    if len(hits) == 1:
        return hits[0][0]
    if len(hits) > 1 or len(prefix) > 1:
        cands = hits if hits else [(i, tmap.get(i, "")) for i in prefix]
        print(f"目标 {target!r} 有多个候选：", file=sys.stderr)
        for sid, title in cands:
            print(f"  {sid}  {title}", file=sys.stderr)
        raise SystemExit(2)
    die(2, f"找不到会话 {target!r}；跑 `dsh_session.py list` 看看")


# ---------------------------------------------------------------- 认证 / token
def screen_token() -> str | None:
    """从 screen 回滚缓冲里抓 `dsh web: http://...?token=...`。

    `dsh web` 的 launch token 每次启动都会变，只打印在它自己的终端上；
    这里用 `screen -X hardcopy` 把终端缓冲导出（只读操作），再从里面取最后一个 token。
    """
    try:
        listing = subprocess.run(["screen", "-ls"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    names = re.findall(r"^\s+\d+\.(\S+)", listing, re.M)
    for name in names:
        fd, tmp = tempfile.mkstemp(prefix="dsh-screen-", suffix=".txt")
        os.close(fd)
        try:
            subprocess.run(["screen", "-S", name, "-X", "hardcopy", "-h", tmp],
                           capture_output=True, timeout=10)
            time.sleep(0.2)
            with open(tmp, "rb") as fh:
                raw = fh.read()
        except (OSError, subprocess.SubprocessError):
            continue
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        tokens = re.findall(rb"token=([A-Za-z0-9_-]+)", raw)
        if tokens:
            return tokens[-1].decode()
    return None


def mint(token: str) -> int:
    """GET /?token=... 换 HttpOnly cookie，写进 COOKIE_FILE，返回 HTTP 状态码。"""
    ensure_cache_dir()
    out = subprocess.run(
        CURL + ["-o", "/dev/null", "-w", "%{http_code}", "-c", COOKIE_FILE,
                f"{base_url()}/?token={token}"],
        capture_output=True, text=True,
    )
    try:
        return int(out.stdout.strip()[-3:])
    except ValueError:
        return 0


def rpc(method: str, args: dict) -> dict:
    """POST /api/<ns>/<method>；自动处理 401（token 过期/换进程 → 重新抓）。"""
    token = read_file(TOKEN_FILE) or screen_token()
    if token:
        mint(token)

    def post() -> tuple[int, str]:
        body = {
            "type": "client-request",
            "rpcId": str(uuid.uuid4()),
            "method": method,
            "payload": {"args": args},
        }
        out = subprocess.run(
            CURL + ["-o", "-", "-w", "\n%{http_code}", "-b", COOKIE_FILE,
                    "-H", "content-type: application/json", "-X", "POST",
                    f"{base_url()}/api/{method}", "--data-binary", "@-"],
            input=json.dumps(body, ensure_ascii=False), capture_output=True, text=True,
        )
        raw, _, code = out.stdout.rpartition("\n")
        return (int(code) if code.isdigit() else 0), raw

    status, raw = post()
    if status == 401:
        token = screen_token()
        if not token:
            die(3, "认证失败且抓不到 launch token：确认 `dsh web` 正在某个 screen 里跑，"
                   "或手动 export DSH_WEB_TOKEN=<token>")
        if mint(token) != 303:
            die(3, "launch token 无效（可能不是当前进程的 token）")
        write_private(TOKEN_FILE, token)
        status, raw = post()
    if status != 200:
        die(1, f"HTTP {status}: {raw[:400] or '(空响应)'}")

    try:
        env = json.loads(raw)
    except ValueError:
        die(1, f"响应不是 JSON：{raw[:400]}")
    result = env.get("result", {})
    if result.get("ok") is not True:
        err = result.get("error", {})
        die(1, f"{method} 失败：{err.get('code')}: {err.get('message')} {err.get('details')}")
    return result.get("value")


# ---------------------------------------------------------------- 子命令
def cmd_list(as_json: bool) -> None:
    items = rpc("session/list", {"_request": {}})
    live = {i["sessionId"]: i for i in items.get("items", [])}
    tmap = titles()
    rows = []
    for sid in sorted(set(live) | set(tmap)):
        meta = live.get(sid, {})
        rows.append({
            "id": sid,
            "title": tmap.get(sid, ""),
            "running": meta.get("running"),
            "agent": meta.get("agentAvailable"),
            "updatedAt": meta.get("updatedAt"),
            "hub": sid == hub_id(),
        })
    rows.sort(key=lambda r: r["updatedAt"] or 0, reverse=True)
    if as_json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return
    print(f"{'':2} {'session id':38} {'running':7} {'agent':5}  title")
    for r in rows:
        mark = "★" if r["hub"] else " "
        print(f"{mark:2} {r['id']:38} {str(r['running']):7} {str(r['agent']):5}  {r['title']}")


def cmd_whoami() -> None:
    me = os.environ.get("DSH_SESSION_ID") or "(未知)"
    hub = hub_id() or "(未知)"
    tmap = titles()
    print(f"self: {me}  {tmap.get(me, '')}")
    print(f"hub : {hub}  {tmap.get(hub, '')}")


def cmd_hub() -> None:
    sid = hub_id()
    if not sid:
        die(3, "解析不到 hub 会话")
    print(sid)


def cmd_send(target: str, text: str, mode: str, dry_run: bool) -> None:
    sid = resolve(target)
    request = {
        "requestId": str(uuid.uuid4()),
        "sessionId": sid,
        "mode": mode,
        "content": [{"type": "text", "text": text}],
    }
    # clientTimeZone 是可选字段：不写死时区，需要就显式给 DSH_CLIENT_TZ / TZ
    tz = os.environ.get("DSH_CLIENT_TZ") or os.environ.get("TZ")
    if tz:
        request["clientTimeZone"] = tz
    args = {"request": request}
    if dry_run:
        print(f"# 目标：{sid}  {titles().get(sid, '')}", file=sys.stderr, flush=True)
        print(json.dumps({"method": "session/prompt", "payload": {"args": args}},
                         ensure_ascii=False, indent=2))
        return
    value = rpc("session/prompt", args)
    if value.get("accepted") is not True:
        die(1, f"未确认投递：{value}")
    print(f"✅ 已投递到 {sid}  {titles().get(sid, '')}  (mode={mode})")


def cmd_tail(target: str, n: int) -> None:
    sid = resolve(target)
    path = session_file(sid)
    if not path:
        die(2, f"找不到会话日志 {sid}")
    out = subprocess.run(["zstd", "-dcq", path], capture_output=True)
    msgs = []
    for line in out.stdout.decode("utf-8", "replace").splitlines():
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        kind = rec.get("type")
        if kind not in ("user/message", "assistant/message"):
            continue
        data = rec.get("data") or {}
        msg = data if kind == "user/message" else (data.get("message") or {})
        source = (msg.get("source") or {}).get("kind")
        # 时间上下文、运行时上下文、审批回执等也是 user/message，但它们不是人说的话
        if kind == "user/message" and source != "user":
            continue
        parts = [b.get("text", "") for b in (msg.get("content") or [])
                 if isinstance(b, dict) and b.get("type") == "text"]
        text = "\n".join(p for p in parts if p).strip()
        if text:
            msgs.append(("👤" if kind.startswith("user") else "🤖", rec.get("seq"), text))
    print(f"# {sid}  {titles().get(sid, '')}  — 最近 {min(n, len(msgs))}/{len(msgs)} 条")
    for flag, seq, text in msgs[-n:]:
        text = " ".join(text.split())
        print(f"{flag} [{seq}] {text[:400]}")


def cmd_call(method: str, args_text: str) -> None:
    if args_text.startswith("@"):
        args_text = read_file(args_text[1:])
    args = json.loads(args_text) if args_text.strip() else {}
    print(json.dumps(rpc(method, args), ensure_ascii=False, indent=2))


# ---------------------------------------------------------------- 入口
def main() -> None:
    ap = argparse.ArgumentParser(prog="dsh_session.py", description="dsh 跨会话传话")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("list", help="列出会话")
    p.add_argument("--json", action="store_true")

    sub.add_parser("hub", help="打印 hub 会话 id")
    sub.add_parser("whoami", help="打印自己与 hub")

    p = sub.add_parser("send", help="向目标会话投一条消息")
    p.add_argument("target")
    p.add_argument("text")
    p.add_argument("--steer", action="store_true", help="插话而不是排队")
    p.add_argument("--dry-run", action="store_true")

    p = sub.add_parser("tail", help="看目标会话最近的消息")
    p.add_argument("target")
    p.add_argument("n", nargs="?", type=int, default=8)

    p = sub.add_parser("call", help="直接调 Remote 方法")
    p.add_argument("method", help="如 session/list")
    p.add_argument("args", nargs="?", default="{}", help="JSON 或 @文件")

    a = ap.parse_args()
    if a.cmd == "list":
        cmd_list(a.json)
    elif a.cmd == "hub":
        cmd_hub()
    elif a.cmd == "whoami":
        cmd_whoami()
    elif a.cmd == "send":
        cmd_send(a.target, a.text, "steer" if a.steer else "queue", a.dry_run)
    elif a.cmd == "tail":
        cmd_tail(a.target, a.n)
    elif a.cmd == "call":
        cmd_call(a.method, a.args)


if __name__ == "__main__":
    main()
