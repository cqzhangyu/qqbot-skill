#!/usr/bin/env bash
# 启动 dsh web（带 QQ 机器人所需的环境修补），并附带一个“给别的会话发消息”的 RPC 小工具。
#
# 一、启动时的修补（原先的两个 headless 补丁已移除）：
#   1) NODE_USE_ENV_PROXY=1 —— qqbot 插件用 node:https 直连 q.qq.com 申请扫码任务，
#      Node 默认不读 HTTP(S)_PROXY，直连会被墙掉（表现为“获取绑定任务失败: ”）。
#      该变量让 Node 内置 http/https 模块走环境代理。
#   2) ws 补丁 —— QQ 网关（wss://api.sgroup.qq.com）由 ws 库连接，ws 强制设置
#      createConnection，绕过 Node 的环境代理 → 握手卡在 SYN-SENT，12s 后
#      "Opening handshake has timed out"，机器人永远不上线，手机扫码页一直“连接中”。
#      这里给 ws 打幂等补丁。
#   3) qqbot 主动消息降级 —— 插件只走「被动回复」（带 inbound 的 msg_id），而 QQ 规定
#      msg_id 5 分钟过期、同一 msg_id 最多回 5 条。所以由 GUI / 跨会话注入触发的 turn，
#      回复用的是隔夜 msg_id，平台直接拒收，插件只 logger.error → 手机上静默收不到。
#      补丁新增 dist/transport/send-fallback.js：被动被拒后降级为主动消息（去 msgId，
#      markdown 不行再退回纯文本），并同时改 outbound.js 的 send() 与
#      outbound-buffer.js 的 flush()（流式降级路径也走这里）。
#   4) qqbot 主动发文本 —— 新增 qqbot_send_text 工具（dist/media/send-text-tool.js +
#      gateway/bootstrap.js 注册）：显式 target（c2c:openid / group:openid）时走**主动消息**
#      （不带 msg_id），不受 5 分钟被动回复窗口限制；不传 target 则沿用当前会话记录做被动回复。
#      ⚠️ 在 GUI 里安装/升级插件会触发 pnpm install（nodeLinker=hoisted），把插件文件
#      从 pnpm store 重新硬链回来，补丁会丢 → 再跑一次本脚本（--patch-only 即可）。
#
# 二、跨会话发消息（替代已删除的 dsh-headless preset 补丁）：
#   dsh web 没有“给别的会话投递消息”的 CLI，但它的 HTTP RPC 可以：
#     GET  /?token=<launch token>   换取浏览器认证 cookie（Host 必须是 127.0.0.1:3080，
#                                   否则被 browser-trust fence 直接 403）
#     POST /api/session/prompt      envelope:
#       {"type":"client-request","rpcId":"<uuid>","method":"session/prompt",
#        "payload":{"args":{"request":{"requestId":"<uuid>","sessionId":"<id>",
#                                      "mode":"queue",
#                                      "content":[{"type":"text","text":"..."}],
#                                      "clientTimeZone":"Asia/Shanghai"}}}}
#   launch token 每个进程随机生成、只出现在启动时打印的 URL 里，所以本脚本启动后会把输出
#   tee 到 ~/.dsh/.web-start.log，并由后台块把 token 落到 ~/.dsh/.web.token（0600）。
#   token 丢了也有兜底：从 screen 会话的 scrollback 里抓。
#
#   用法：
#     bash dsh-web-start.sh --send <session-id> "<消息>"
#
#   注意：被归档（archived）的会话会被 archived-session-gate 在 pre-step 拒掉，
#   turn 直接 end 成 blocked —— 换一个未归档的会话即可。
#
# 用法（启动）：
#   先停掉正在跑的 dsh（screen 里 Ctrl-C），然后
#     bash <skill-dir>/scripts/dsh-web-start.sh
#     bash <skill-dir>/scripts/dsh-web-start.sh --patch-only

set -uo pipefail

export NODE_USE_ENV_PROXY=1
export NO_PROXY="localhost,127.0.0.1,::1${NO_PROXY:+,$NO_PROXY}"


# 公开 npm 包标识（不是内部信息；可用环境变量覆盖）
DSH_NPM_PKG="${DSH_NPM_PKG:-@deepseek-ai/dsh@next}"
QQBOT_PKG="${QQBOT_PKG:-@tencent-connect/dsh-qqbot}"
export QQBOT_PKG
DSH_HOME_DIR="${HOME}/.dsh"
WEB_LOG="${DSH_HOME_DIR}/.web-start.log"
TOKEN_FILE="${DSH_HOME_DIR}/.web.token"

patch_ws() {
python3 - <<'PY'
import glob, os, re, shutil

pat = re.compile(
    r"^(?P<ind>[ \t]*)opts\.createConnection[ \t]*=[ \t]*\n"
    r"[ \t]*opts\.createConnection[ \t]*\|\|[ \t]*\(?isSecure \? tlsConnect : netConnect\)?[ \t]*;",
    re.M,
)

MARK = '[dsh-local-patch]'

def patched(ind):
    return (
        f"{ind}// {MARK} NODE_USE_ENV_PROXY：让 ws 走 Node 的环境代理（否则强制直连，\n"
        f"{ind}// 在只能经 HTTP 代理出网的环境里无法连上 QQ 网关）。未设置该变量时行为不变。\n"
        f"{ind}opts.createConnection =\n"
        f"{ind}  opts.createConnection || (process.env.NODE_USE_ENV_PROXY ? undefined : (isSecure ? tlsConnect : netConnect));"
    )

patterns = [
    '~/.dsh/profiles/*/node_modules/ws/lib/websocket.js',
    '~/.dsh/profiles/node_modules/ws/lib/websocket.js',
    '~/.dsh/profiles/*/node_modules/.pnpm/ws@*/node_modules/ws/lib/websocket.js',
]

paths = []
for p in patterns:
    paths += glob.glob(os.path.expanduser(p))
paths = sorted(set(paths))

if not paths:
    print('[ws patch] 没找到 ws（profile 可能还没装好），跳过')

for path in paths:
    try:
        text = open(path, encoding='utf-8').read()
    except OSError as exc:
        print(f'[ws patch] 读取失败，跳过：{path}（{exc}）')
        continue
    if MARK in text:
        print(f'[ws patch] 已打过补丁：{path}')
        continue
    m = pat.search(text)
    if m is None:
        print(f'[ws patch] 跳过（ws 版本变了，锚点不存在）：{path}')
        continue
    shutil.copy2(path, path + '.orig')
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        fh.write(text[:m.start()] + patched(m.group('ind')) + text[m.end():])
    os.unlink(path)          # 断开 pnpm store 硬链接，避免污染共享 store
    os.replace(tmp, path)
    print(f'[ws patch] 已修补：{path}')
PY
}

# ── 跨会话发消息：POST /api/session/prompt ──────────────────────────────────
send_prompt() {
  local sid="$1"; shift
  local msg="$*"
  if [[ -z "$sid" || -z "$msg" ]]; then
    echo "用法: bash $0 --send <session-id> \"<消息>\"" >&2
    return 2
  fi
  DSH_SEND_SID="$sid" DSH_SEND_MSG="$msg" DSH_SEND_TOKEN_FILE="$TOKEN_FILE" \
  DSH_SEND_WEB_LOG="$WEB_LOG" python3 - <<'PY'
import http.cookiejar, json, os, re, subprocess, sys, time, urllib.request, uuid

SID = os.environ['DSH_SEND_SID']
MSG = os.environ['DSH_SEND_MSG']
BASE = 'http://127.0.0.1:3080'
TOKEN_FILE = os.environ['DSH_SEND_TOKEN_FILE']
WEB_LOG = os.environ['DSH_SEND_WEB_LOG']

def launch_token():
    for path in (TOKEN_FILE, WEB_LOG):
        try:
            text = open(path, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        hits = re.findall(r'token=([A-Za-z0-9_-]{16,})', text)
        if hits:
            return hits[-1]
    tmp = '/tmp/.dsh-screen-buf'
    subprocess.run(['screen', '-S', 'dsh', '-X', 'hardcopy', '-h', tmp],
                   capture_output=True)
    try:
        hits = re.findall(r'token=([A-Za-z0-9_-]{16,})',
                          open(tmp, encoding='utf-8', errors='replace').read())
    except OSError:
        hits = []
    return hits[-1] if hits else None

tok = launch_token()
if not tok:
    sys.exit('拿不到 launch token：确认 dsh web 在跑，且 ~/.dsh/.web.token 或 '
             '~/.dsh/.web-start.log 里有启动时打印的 URL')

def deliver():
    jar = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    op.open(f'{BASE}/?token={tok}', timeout=10)
    body = {
        'type': 'client-request',
        'rpcId': str(uuid.uuid4()),
        'method': 'session/prompt',
        'payload': {'args': {'request': {
            'requestId': str(uuid.uuid4()),
            'sessionId': SID,
            'mode': 'queue',
            'content': [{'type': 'text', 'text': MSG}],
            'clientTimeZone': 'Asia/Shanghai',
        }}},
    }
    req = urllib.request.Request(f'{BASE}/api/session/prompt',
                                 data=json.dumps(body).encode(),
                                 headers={'Content-Type': 'application/json'})
    with op.open(req, timeout=30) as resp:
        return json.loads(resp.read().decode())

payload, err = None, None
for _attempt in range(3):
    try:
        payload = deliver()
        break
    except urllib.error.HTTPError as exc:
        err = f'HTTP {exc.code}: ' + exc.read()[:200].decode('utf-8', 'replace')
    except Exception as exc:                     # noqa: BLE001
        err = repr(exc)[:200]
    time.sleep(1)
if payload is None:
    sys.exit(f'投递失败（已重试 3 次）：{err}')
result = payload.get('result') or {}
if not result.get('ok'):
    sys.exit('投递失败: ' + json.dumps(result.get('error'), ensure_ascii=False))
t_send = time.time()
print(f'[send] accepted → {SID}', flush=True)

# 等这一轮跑完：轮询会话日志，抓新的 assistant/message
import glob
matches = glob.glob(os.path.join(os.path.expanduser('~/.dsh/sessions'), '*', SID,
                                 'session.v4.jsonl.zstd'))
log = matches[0] if matches else ''
started = time.time()
last = None
while time.time() - started < 120:
    time.sleep(1.5)
    if not log:
        break
    try:
        raw = subprocess.run(['zstd', '-dc', log], capture_output=True, timeout=20).stdout
    except Exception:
        continue
    texts = []
    for line in raw.split(b'\n'):
        if not line.strip():
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get('time', 0) < int(t_send * 1000) - 2000:
            continue
        if ev.get('type') != 'assistant/message':
            continue
        data = ev.get('data') or {}
        parts = data.get('content') or (data.get('message') or {}).get('content') or []
        txt = ' '.join(p.get('text', '') for p in parts
                       if isinstance(p, dict) and p.get('type') == 'text').strip()
        if txt:
            texts.append(txt)
    if texts and texts != last:
        last = texts
        print('[reply] ' + texts[-1][:600].replace('\n', ' '), flush=True)
        break
PY
}

patch_qqbot_proactive() {
python3 - <<'PY'
import glob, os

MARK = '[dsh-local-patch:qqbot-proactive]'
FALLBACK = '''
/**
 * [dsh-local-patch:qqbot-proactive] 被动回复失败时的降级发送。
 *
 * QQ 的被动回复（带 msg_id）只在收到消息后 5 分钟内有效、同一 msg_id 最多 5 条；
 * 过期后接口直接拒收，而插件原来只 logger.error，用户侧完全静默。
 * 这里降级为「主动消息」（不带 msg_id），markdown 再失败就退回纯文本。
 * 注意：本身就带 msgId=undefined 的主动消息也要试纯文本——QQ 可能拒 markdown
 * （msg_type=2 需要模板/白名单）而允许纯文本。
 */

function describe(err) {
    return err instanceof Error ? err.message : String(err);
}

/**
 * 发送一段文本：先被动回复，被拒则降级为主动消息（markdown → 纯文本）。
 * @param bot qqbot-nodejs 的 QQBot 实例
 * @param target 会话记录里的 replyTarget（{ scope, targetId, msgId }）
 * @param text 本段文本
 * @param logger dsh logger
 * @param tag 日志标识
 * @returns 是否至少有一条通道成功
 */
export async function sendWithFallback(bot, target, text, logger, tag) {
    try {
        await bot.sendMarkdown(target, text);
        return true;
    }
    catch (err) {
        const firstError = describe(err);
        const passive = target !== undefined && target.msgId !== undefined;
        const proactive = passive ? { ...target, msgId: undefined } : target;
        if (passive) {
            try {
                await bot.sendMarkdown(proactive, text);
                logger.info?.(`im-qqbot: ${tag} passive reply rejected (${firstError}); sent as proactive markdown`);
                return true;
            }
            catch (markdownError) {
                return await sendPlainText(bot, proactive, text, logger, tag, `${firstError} | proactive-markdown=${describe(markdownError)}`);
            }
        }
        return await sendPlainText(bot, proactive, text, logger, tag, `markdown=${firstError}`);
    }
}

async function sendPlainText(bot, target, text, logger, tag, earlier) {
    try {
        await bot.sendText(target, text);
        logger.info?.(`im-qqbot: ${tag} fell back to plain text (${earlier})`);
        return true;
    }
    catch (textError) {
        logger.error(`im-qqbot: ${tag} failed: ${earlier} | text=${describe(textError)}`);
        return false;
    }
}
'''

OUTBOUND_OLD = '''        for (const chunk of chunks) {
            try {
                await this.bot.sendMarkdown(record.replyTarget, chunk);
            }
            catch (err) {
                this.logger.error(`im-qqbot: ${tag} failed: ${err instanceof Error ? err.message : String(err)}`);
            }
        }'''
OUTBOUND_NEW = '''        for (const chunk of chunks) {
            // [dsh-local-patch:qqbot-proactive] 被动回复被拒（msg_id 过期）时降级主动消息
            await sendWithFallback(this.bot, record.replyTarget, chunk, this.logger, tag);
        }'''

BUFFER_OLD = '''            const chunks = chunkMarkdownText(this.buffer, this.limit);
            for (const chunk of chunks) {
                await this.bot.sendMarkdown(this.record.replyTarget, chunk);
            }'''
BUFFER_NEW = '''            const chunks = chunkMarkdownText(this.buffer, this.limit);
            for (const chunk of chunks) {
                // [dsh-local-patch:qqbot-proactive] 同上：流式降级到静态发送时也要能改发主动消息
                await sendWithFallback(this.bot, this.record.replyTarget, chunk, this.logger, 'flush');
            }'''


def write_break_link(path, content):
    """断开 pnpm 硬链接后再写，避免污染共享 store。"""
    tmp = path + '.dshpatch.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        fh.write(content)
    os.unlink(path)
    os.replace(tmp, path)
    os.chmod(path, 0o664)


dirs = sorted(glob.glob(os.path.expanduser('~/.dsh/profiles/*/node_modules/' + os.environ['QQBOT_PKG'] + '/dist/transport')))
if not dirs:
    print('[qqbot patch] 没找到 dsh-qqbot 插件目录，跳过')

def write_break_link(path, content):
    """断开 pnpm 硬链接后再写，避免污染共享 store。"""
    tmp = path + '.dshpatch.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        fh.write(content)
    os.unlink(path)
    os.replace(tmp, path)
    os.chmod(path, 0o664)

for d in dirs:
    fb = os.path.join(d, 'send-fallback.js')
    cur = open(fb, encoding='utf-8').read() if os.path.exists(fb) else None
    if cur == FALLBACK:
        print(f'[qqbot patch] 已是最新：{fb}')
    elif cur is not None and MARK not in cur:
        print(f'[qqbot patch] {fb} 内容不是本补丁生成的，跳过')
    else:
        write_break_link(fb, FALLBACK)
        print(f'[qqbot patch] {"更新" if cur is not None else "新建"}：{fb}')

    # outbound.js
    p = os.path.join(d, 'outbound.js')
    s = open(p, encoding='utf-8').read()
    if 'send-fallback.js' in s:
        print(f'[qqbot patch] 已打过补丁：{p}')
    elif OUTBOUND_OLD in s:
        anchor = 'import { parseEvent, extractTurnError, } from "./events.js";'
        if anchor not in s:
            print(f'[qqbot patch] outbound.js 的 import 锚点变了，跳过：{p}')
            continue
        s = s.replace(anchor, anchor + '\nimport { sendWithFallback } from "./send-fallback.js";', 1)
        s = s.replace(OUTBOUND_OLD, OUTBOUND_NEW, 1)
        write_break_link(p, s)
        print(f'[qqbot patch] 已修补：{p}')
    else:
        print(f'[qqbot patch] outbound.js 的发送循环锚点变了，跳过：{p}')

    # outbound-buffer.js
    p = os.path.join(d, 'outbound-buffer.js')
    s = open(p, encoding='utf-8').read()
    if 'send-fallback.js' in s:
        print(f'[qqbot patch] 已打过补丁：{p}')
    elif BUFFER_OLD in s:
        anchor = 'import { StreamingWriter } from "./streaming-writer.js";'
        if anchor not in s:
            print(f'[qqbot patch] outbound-buffer.js 的 import 锚点变了，跳过：{p}')
            continue
        s = s.replace(anchor, anchor + '\nimport { sendWithFallback } from "./send-fallback.js";', 1)
        s = s.replace(BUFFER_OLD, BUFFER_NEW, 1)
        write_break_link(p, s)
        print(f'[qqbot patch] 已修补：{p}')
    else:
        print(f'[qqbot patch] outbound-buffer.js 的 flush 锚点变了，跳过：{p}')
PY
}

patch_qqbot_send_text() {
python3 - <<'TOOLPY'
import glob, os

MARK = '[dsh-local-patch:qqbot-send-text]'
TOOL = r"""/**
 * 内置 qqbot_send_text 工具 — [dsh-local-patch:qqbot-send-text]
 *
 * 主动/被动发送一条纯文本：
 *   - 显式 target（"c2c:openid" / "group:openid"）→ 直接走**主动消息**（不带 msg_id），
 *     不受 QQ 5 分钟被动回复窗口限制；
 *   - 省略 target → 用当前会话记录的 replyTarget（被动回复，窗口内最稳），
 *     被平台拒绝时由 sendWithFallback 自动降级为主动消息。
 */
import { sendWithFallback } from '../transport/send-fallback.js';
import { chunkMarkdownText } from '../transport/chunker.js';

export const SEND_TEXT_TOOL_NAME = 'qqbot_send_text';

const DESCRIPTION = 'Send a plain-text message to the QQ user or group. Pass `target` as '
    + '"c2c:openid" or "group:openid" to push proactively (no 5-minute passive-reply window); '
    + 'omit it to reply inside the current conversation.';

function parseTarget(input) {
    const idx = input.indexOf(':');
    if (idx <= 0)
        return undefined;
    const scope = input.slice(0, idx);
    const targetId = input.slice(idx + 1);
    if (!targetId || (scope !== 'c2c' && scope !== 'group'))
        return undefined;
    return { scope, targetId };
}

/** 掩码：日志/工具输出里不回显完整 openid */
function mask(target) {
    const tail = target.targetId.slice(-4);
    return `${target.scope}:***${tail}`;
}

export function registerSendTextTool(ctx, bot, manager, config, logger) {
    const tools = ctx.get('tools');
    if (!tools?.register) {
        logger.warn('im-qqbot: tools 服务不可用，qqbot_send_text 工具未注册');
        return;
    }
    const limit = config.textChunkLimit ?? 4500;
    const definition = {
        name: SEND_TEXT_TOOL_NAME,
        description: DESCRIPTION,
        parameters: {
            type: 'object',
            properties: {
                text: { type: 'string', description: 'Text to send (markdown allowed).' },
                target: { type: 'string', description: 'Optional "c2c:openid" or "group:openid" for a proactive push. Omit to reply in the current conversation.' },
            },
            required: ['text'],
            additionalProperties: false,
        },
        output: {
            schema: {
                type: 'object',
                properties: {
                    target: { type: 'string' },
                    chunks: { type: 'integer' },
                    sent: { type: 'integer' },
                    proactive: { type: 'boolean' },
                },
                required: ['target', 'chunks', 'sent', 'proactive'],
                additionalProperties: false,
            },
            render: (_args, value) => [{
                    type: 'text',
                    text: `已发送文本 → ${value.target}（${value.sent}/${value.chunks} 段，${value.proactive ? '主动' : '被动'}）`,
                }],
        },
        async execute(args, exec) {
            const { text, target } = args;
            if (typeof text !== 'string' || text.trim().length === 0) {
                throw new Error('qqbot_send_text: `text` must be a non-empty string');
            }
            let replyTarget;
            if (target !== undefined && target !== '') {
                replyTarget = parseTarget(target);
                if (replyTarget === undefined) {
                    throw new Error(`qqbot_send_text: target 格式错误，需要 c2c:openid 或 group:openid，收到: ${target}`);
                }
            }
            else if (exec.agent !== undefined) {
                replyTarget = manager.findByAgent(exec.agent)?.replyTarget;
            }
            if (replyTarget === undefined) {
                throw new Error('qqbot_send_text: 无法确定发送目标，请显式传 target 参数');
            }
            const chunks = chunkMarkdownText(text, limit);
            let sent = 0;
            for (const chunk of chunks) {
                if (await sendWithFallback(bot, replyTarget, chunk, logger, 'qqbot_send_text'))
                    sent += 1;
            }
            if (sent === 0) {
                throw new Error(`qqbot_send_text: 发送失败（target=${mask(replyTarget)}）`);
            }
            logger.info(`im-qqbot: qqbot_send_text 发送 ${sent}/${chunks.length} 段 → ${mask(replyTarget)}`);
            return {
                target: mask(replyTarget),
                chunks: chunks.length,
                sent,
                proactive: replyTarget.msgId === undefined,
            };
        },
    };
    tools.register(definition);
}
"""

def write_break_link(path, content):
    """断开 pnpm 硬链接后再写，避免污染共享 store。"""
    tmp = path + '.dshpatch.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        fh.write(content)
    os.unlink(path)
    os.replace(tmp, path)
    os.chmod(path, 0o664)

dirs = sorted(glob.glob(os.path.expanduser('~/.dsh/profiles/*/node_modules/' + os.environ['QQBOT_PKG'] + '/dist')))
if not dirs:
    print('[qqbot text] 没找到 dsh-qqbot 插件目录，跳过')

for d in dirs:
    p = os.path.join(d, 'media/send-text-tool.js')
    if not os.path.exists(p):
        open(p, 'w', encoding='utf-8').write(TOOL)
        os.chmod(p, 0o664)
        print(f'[qqbot text] 新建 {p}')
    elif MARK not in open(p, encoding='utf-8').read():
        print(f'[qqbot text] {p} 内容不是本补丁生成的，跳过')

    b = os.path.join(d, 'gateway/bootstrap.js')
    s = open(b, encoding='utf-8').read()
    if 'send-text-tool.js' in s:
        print(f'[qqbot text] 已打过补丁：{b}')
        continue
    a1 = 'import { registerSendFileTool } from "../media/send-file-tool.js";'
    a2 = '    registerSendFileTool(ctx, mediaSender, manager, config, logger);'
    if a1 not in s or a2 not in s:
        print(f'[qqbot text] bootstrap.js 锚点变了，跳过：{b}')
        continue
    s = s.replace(a1, a1 + '\nimport { registerSendTextTool } from "../media/send-text-tool.js";', 1)
    s = s.replace(a2, a2 + '\n    // [dsh-local-patch:qqbot-send-text] 主动/被动文本发送\n    registerSendTextTool(ctx, bot, manager, config, logger);', 1)
    write_break_link(b, s)
    print(f'[qqbot text] 已修补：{b}')
TOOLPY
}

verify_qqbot_patches() {
  local d f
  for d in "$HOME"/.dsh/profiles/*/node_modules/"$QQBOT_PKG"/dist; do
    [ -d "$d" ] || continue
    for f in transport/send-fallback.js media/send-text-tool.js transport/outbound.js \
             transport/outbound-buffer.js gateway/bootstrap.js; do
      [ -f "$d/$f" ] || continue
      if ! node --check "$d/$f" >/dev/null 2>&1; then
        echo "[qqbot verify] 语法检查失败：$d/$f" >&2
      fi
    done
  done
}

if [[ "${1:-}" == "--send" ]]; then
  shift
  send_prompt "$@"
  exit $?
fi

patch_ws
patch_qqbot_proactive
patch_qqbot_send_text
verify_qqbot_patches

if [[ "${1:-}" == "--patch-only" ]]; then
  echo '[patch-only] 补丁已应用，未启动 dsh web'
  exit 0
fi

# 会话工作目录：默认沿用调用时所在目录，可用 WORKSPACE 覆盖
cd "${WORKSPACE:-$PWD}" || exit 1

# 启动 web，并把启动输出留一份：launch token 只在这里出现一次。
: > "$WEB_LOG"
(
  for _ in $(seq 1 120); do
    tok=$(grep -aoE 'token=[A-Za-z0-9_-]{16,}' "$WEB_LOG" 2>/dev/null | tail -1 | cut -d= -f2)
    if [ -n "$tok" ]; then
      printf '%s\n' "$tok" > "$TOKEN_FILE"
      chmod 600 "$TOKEN_FILE"
      break
    fi
    sleep 1
  done
) &

npm exec -y "$DSH_NPM_PKG" web 2>&1 | tee -a "$WEB_LOG"
