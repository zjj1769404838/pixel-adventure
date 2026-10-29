#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把版本发布信息 + APK 附件用 SMTP 发到指定邮箱。

所有敏感配置只从环境变量读取，绝不硬编码、绝不写进仓库：

    OTA_SMTP_HOST              SMTP 主机（必填）
    OTA_SMTP_PORT              端口（缺省 587）
    OTA_SMTP_SECURITY          starttls（默认）/ ssl / none
    OTA_SMTP_USER              认证用户名（为空则跳过登录，便于本地测试）
    OTA_SMTP_PASS              认证密码
    OTA_SMTP_FROM              发件人（缺省 = OTA_SMTP_USER）
    OTA_SMTP_TO                收件人，逗号分隔多收件人（必填）
    OTA_MAIL_MAX_ATTACHMENT_MB 附件大小上限（缺省 20，单位 MB）

用法（在工程根目录执行）：

    D:/apps/Python313/python.exe scripts/send_release_email.py \\
        --manifest dist/latest.json --apk build/pixel-adventure.apk

    # 只发链接不带附件
    D:/apps/Python313/python.exe scripts/send_release_email.py \\
        --manifest dist/latest.json --no-attachment

    # 演练：不连服务器，只打印会发什么
    D:/apps/Python313/python.exe scripts/send_release_email.py \\
        --manifest dist/latest.json --dry-run

退出码：
    0  发送成功（含"附件超限降级为只发链接"）
    2  认证失败（不重试）
    3  连接 / 发送最终失败（重试耗尽）
    4  配置缺失或清单不可读

日志：JSON Lines 追加写到 build/logs/mail-YYYYMMDD.jsonl，
每行 {"ts","event","detail"}；日志里绝不出现密码，收件人邮箱做脱敏。
"""

import argparse
import json
import os
import smtplib
import socket
import sys
import time
from datetime import datetime, timezone
from email.header import Header
from email.mime.application import MIMEApplication
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import formataddr, formatdate

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

DEFAULT_MANIFEST = os.path.join("dist", "latest.json")
DEFAULT_APK = os.path.join("build", "pixel-adventure.apk")
LOG_DIR = os.path.join("build", "logs")

DEFAULT_PORT = 587
DEFAULT_MAX_ATTACHMENT_MB = 20
DEFAULT_RETRIES = 2
RETRY_BASE_DELAY = 1.5        # 指数退避基数（秒）：1.5, 3.0, 6.0 …

# 退出码
EXIT_OK = 0
EXIT_AUTH_FAILED = 2
EXIT_SEND_FAILED = 3
EXIT_CONFIG_ERROR = 4

# 事件名
EV_SENT = "SENT"
EV_ATTACHMENT_TOO_LARGE = "ATTACHMENT_TOO_LARGE"
EV_CONNECT_FAILED = "CONNECT_FAILED"
EV_AUTH_FAILED = "AUTH_FAILED"
EV_SEND_FAILED = "SEND_FAILED"
EV_CONFIG_ERROR = "CONFIG_ERROR"


# ---------------------------------------------------------------------------
# 日志（JSON Lines）
# ---------------------------------------------------------------------------

def mask_email(addr):
    """收件人脱敏：alice@example.com -> a***@example.com。"""
    text = (addr or "").strip()
    if "@" not in text:
        return "***"
    local, _, domain = text.partition("@")
    if not local:
        return "***@%s" % domain
    return "%s***@%s" % (local[0], domain)


def mask_email_list(addrs):
    """逗号分隔的收件人列表整体脱敏。"""
    parts = [mask_email(item) for item in (addrs or []) if item.strip()]
    return ", ".join(parts)


def log_path_for_today(log_dir=None):
    """当天日志文件路径 build/logs/mail-YYYYMMDD.jsonl。

    注意：log_dir 必须用 None 作缺省值再在函数体内回退到模块级 LOG_DIR，
    否则默认参数会在定义时就把 LOG_DIR 绑死，测试里 patch 模块变量会失效。
    """
    log_dir = log_dir or LOG_DIR
    stamp = datetime.now().strftime("%Y%m%d")
    return os.path.join(log_dir, "mail-%s.jsonl" % stamp)


def write_log(event, detail, log_dir=None, secrets=()):
    """追加一行 JSON 日志。detail 里若混入任何 secrets 值会被替换成 ***。"""
    log_dir = log_dir or LOG_DIR
    safe_detail = str(detail)
    for secret in secrets:
        if secret:
            safe_detail = safe_detail.replace(str(secret), "***")

    record = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "event": event,
        "detail": safe_detail,
    }
    try:
        os.makedirs(log_dir, exist_ok=True)
        with open(log_path_for_today(log_dir), "a", encoding="utf-8", newline="\n") as fp:
            fp.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError as exc:
        print("WARNING: 写日志失败: %s" % exc, file=sys.stderr)
    return record


# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------

def load_config(environ=None):
    """从环境变量组装配置。返回 (config dict, 错误信息 or None)。"""
    env = os.environ if environ is None else environ

    host = (env.get("OTA_SMTP_HOST") or "").strip()
    to_raw = (env.get("OTA_SMTP_TO") or "").strip()
    user = (env.get("OTA_SMTP_USER") or "").strip()
    password = env.get("OTA_SMTP_PASS") or ""
    from_addr = (env.get("OTA_SMTP_FROM") or "").strip() or user
    security = (env.get("OTA_SMTP_SECURITY") or "starttls").strip().lower()

    missing = []
    if not host:
        missing.append("OTA_SMTP_HOST")
    if not to_raw:
        missing.append("OTA_SMTP_TO")
    if not from_addr:
        missing.append("OTA_SMTP_FROM（且 OTA_SMTP_USER 也为空）")
    if missing:
        return None, "缺少必填环境变量: %s" % ", ".join(missing)

    if security not in ("starttls", "ssl", "none"):
        return None, "OTA_SMTP_SECURITY 只能是 starttls / ssl / none，当前为 %r" % security

    try:
        port = int((env.get("OTA_SMTP_PORT") or "").strip() or DEFAULT_PORT)
    except ValueError:
        return None, "OTA_SMTP_PORT 不是整数: %r" % env.get("OTA_SMTP_PORT")

    try:
        max_mb = float((env.get("OTA_MAIL_MAX_ATTACHMENT_MB") or "").strip()
                       or DEFAULT_MAX_ATTACHMENT_MB)
    except ValueError:
        return None, "OTA_MAIL_MAX_ATTACHMENT_MB 不是数字: %r" % env.get("OTA_MAIL_MAX_ATTACHMENT_MB")

    recipients = [item.strip() for item in to_raw.split(",") if item.strip()]

    return {
        "host": host,
        "port": port,
        "security": security,
        "user": user,
        "password": password,
        "from_addr": from_addr,
        "recipients": recipients,
        "max_attachment_mb": max_mb,
    }, None


# ---------------------------------------------------------------------------
# 清单读取与内容渲染
# ---------------------------------------------------------------------------

def human_size(num_bytes):
    """字节数转人类可读，例如 30332907 -> '28.9 MB'。"""
    value = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024.0 or unit == "TB":
            if unit == "B":
                return "%d %s" % (int(value), unit)
            return "%.1f %s" % (value, unit)
        value /= 1024.0
    return "%.1f TB" % value


def load_latest(manifest_path):
    """读取清单的 latest 段。失败抛 ValueError。"""
    if not os.path.isfile(manifest_path):
        raise ValueError("找不到清单文件: %s" % manifest_path)
    try:
        with open(manifest_path, "r", encoding="utf-8") as fp:
            data = json.load(fp)
    except (OSError, ValueError) as exc:
        raise ValueError("清单读取失败: %s" % exc)
    latest = data.get("latest") if isinstance(data, dict) else None
    if not isinstance(latest, dict):
        raise ValueError("清单里没有 latest 段")
    return data, latest


def render_subject(game, latest):
    return "【%s】新版本 v%s 已发布" % (game, latest.get("version_name"))


def render_text(game, package, latest, attach_note):
    """纯文本正文。"""
    lines = []
    lines.append("《%s》新版本已发布" % game)
    lines.append("=" * 40)
    lines.append("游戏名称 : %s" % game)
    lines.append("包名     : %s" % package)
    lines.append("版本号   : %s (versionCode %s)" % (
        latest.get("version_name"), latest.get("version_code")))
    lines.append("更新时间 : %s" % latest.get("published_at"))
    lines.append("文件大小 : %s" % human_size(latest.get("size_bytes") or 0))
    lines.append("SHA-256  : %s" % latest.get("sha256"))
    lines.append("")
    lines.append("更新说明：")
    for idx, item in enumerate(latest.get("changelog") or [], 1):
        lines.append("  %d. %s" % (idx, item))
    if not (latest.get("changelog") or []):
        lines.append("  （本次未填写更新说明）")
    lines.append("")
    lines.append("APK 下载 : %s" % latest.get("download_url"))
    lines.append("发布页面 : %s" % latest.get("release_page"))
    if latest.get("mandatory"):
        lines.append("")
        lines.append("注意：本次为强制更新。")
    lines.append("")
    lines.append(attach_note)
    lines.append("")
    lines.append("-- ")
    lines.append("本邮件由 scripts/send_release_email.py 自动发送，请勿直接回复。")
    return "\n".join(lines)


def render_html(game, package, latest, attach_note):
    """简单 HTML 正文（内联样式，避免邮件客户端剥离样式表）。"""
    rows = [
        ("游戏名称", game),
        ("包名", package),
        ("版本号", "%s (versionCode %s)" % (
            latest.get("version_name"), latest.get("version_code"))),
        ("更新时间", latest.get("published_at")),
        ("文件大小", human_size(latest.get("size_bytes") or 0)),
        ("SHA-256", latest.get("sha256")),
    ]
    tr_html = "".join(
        '<tr><td style="padding:6px 12px;color:#666;white-space:nowrap;">%s</td>'
        '<td style="padding:6px 12px;font-family:Consolas,monospace;">%s</td></tr>'
        % (key, value) for key, value in rows)

    changelog = latest.get("changelog") or []
    if changelog:
        cl_html = "<ul style=\"margin:8px 0;padding-left:22px;\">%s</ul>" % "".join(
            "<li>%s</li>" % item for item in changelog)
    else:
        cl_html = "<p style=\"color:#888;\">（本次未填写更新说明）</p>"

    mandatory_html = ""
    if latest.get("mandatory"):
        mandatory_html = ('<p style="padding:8px 12px;background:#fff4e5;'
                          'border-left:3px solid #e6a23c;">注意：本次为强制更新。</p>')

    download_url = latest.get("download_url") or ""
    release_page = latest.get("release_page") or ""

    return """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"></head>
<body style="margin:0;padding:20px;background:#f5f6f8;font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;">
  <div style="max-width:640px;margin:0 auto;background:#fff;border-radius:8px;overflow:hidden;">
    <div style="padding:18px 24px;background:#2b3a55;color:#fff;">
      <h2 style="margin:0;font-size:18px;">《{game}》新版本 v{version} 已发布</h2>
    </div>
    <div style="padding:20px 24px;">
      <table style="border-collapse:collapse;font-size:14px;">{rows}</table>
      <h3 style="margin:20px 0 6px;font-size:15px;">更新说明</h3>
      {changelog}
      {mandatory}
      <p style="margin:18px 0 6px;">
        <a href="{download_url}" style="display:inline-block;padding:10px 18px;background:#3d7eff;color:#fff;text-decoration:none;border-radius:6px;">下载 APK</a>
        <a href="{release_page}" style="display:inline-block;margin-left:10px;padding:10px 18px;color:#3d7eff;text-decoration:none;border:1px solid #3d7eff;border-radius:6px;">查看发布页</a>
      </p>
      <p style="font-size:13px;color:#666;">{attach_note}</p>
      <p style="font-size:12px;color:#999;word-break:break-all;">{download_url}</p>
    </div>
    <div style="padding:14px 24px;background:#fafbfc;font-size:12px;color:#999;">
      本邮件由 scripts/send_release_email.py 自动发送，请勿直接回复。
    </div>
  </div>
</body></html>""".format(
        game=game,
        version=latest.get("version_name"),
        rows=tr_html,
        changelog=cl_html,
        mandatory=mandatory_html,
        download_url=download_url,
        release_page=release_page,
        attach_note=attach_note,
    )


def build_message(config, game, package, latest, attach_path, attach_note):
    """组装 MIMEMultipart 邮件对象。attach_path 为 None 时只发正文。"""
    msg = MIMEMultipart()
    msg["Subject"] = Header(render_subject(game, latest), "utf-8")
    msg["From"] = formataddr((str(Header(game, "utf-8")), config["from_addr"]))
    msg["To"] = ", ".join(config["recipients"])
    msg["Date"] = formatdate(localtime=True)

    msg.attach(MIMEText(render_text(game, package, latest, attach_note), "plain", "utf-8"))
    msg.attach(MIMEText(render_html(game, package, latest, attach_note), "html", "utf-8"))

    if attach_path:
        with open(attach_path, "rb") as fp:
            payload = fp.read()
        part = MIMEApplication(payload, _subtype="vnd.android.package-archive")
        filename = os.path.basename(attach_path)
        part.add_header("Content-Disposition", "attachment",
                        filename=("utf-8", "", filename))
        msg.attach(part)
    return msg


# ---------------------------------------------------------------------------
# SMTP 发送
# ---------------------------------------------------------------------------

def open_smtp(config):
    """按 security 建立连接。返回已连接的 SMTP 对象（未登录）。"""
    host = config["host"]
    port = config["port"]
    security = config["security"]
    timeout = 30

    if security == "ssl":
        client = smtplib.SMTP_SSL(host, port, timeout=timeout)
    else:
        client = smtplib.SMTP(host, port, timeout=timeout)

    if security == "starttls":
        client.starttls()
    return client


def send_once(config, msg, dry_run=False):
    """尝试发送一次。返回 (ok, error_kind, error_message)。

    error_kind: None / "auth" / "connect" / "send"
    """
    if dry_run:
        return True, None, "dry-run"

    client = None
    try:
        client = open_smtp(config)
        if config["user"]:
            client.login(config["user"], config["password"])
        client.sendmail(config["from_addr"], config["recipients"], msg.as_string())
        return True, None, ""

    except smtplib.SMTPAuthenticationError as exc:
        return False, "auth", "认证失败: %s" % exc
    except (smtplib.SMTPException, OSError, socket.timeout) as exc:
        # 连接阶段的失败（含超时、DNS、拒绝连接）与发送阶段的失败都在这里
        kind = "connect" if client is None else "send"
        return False, kind, "%s: %s" % (type(exc).__name__, exc)
    finally:
        if client is not None:
            try:
                client.quit()
            except Exception:      # noqa: BLE001  关闭连接失败不影响结果
                try:
                    client.close()
                except Exception:  # noqa: BLE001
                    pass


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        prog="send_release_email.py",
        description="把版本发布信息 + APK 附件用 SMTP 发到指定邮箱（凭据只从环境变量读）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="环境变量：OTA_SMTP_HOST / OTA_SMTP_PORT / OTA_SMTP_SECURITY /\n"
               "          OTA_SMTP_USER / OTA_SMTP_PASS / OTA_SMTP_FROM / OTA_SMTP_TO /\n"
               "          OTA_MAIL_MAX_ATTACHMENT_MB\n"
               "退出码：0 成功 / 2 认证失败 / 3 连接或发送失败 / 4 配置缺失\n",
    )
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST,
                        help="清单路径（缺省 %s）" % DEFAULT_MANIFEST)
    parser.add_argument("--apk", default=DEFAULT_APK,
                        help="APK 路径（缺省 %s）" % DEFAULT_APK)
    parser.add_argument("--no-attachment", action="store_true",
                        help="不发送附件，正文只放下载链接")
    parser.add_argument("--retries", type=int, default=DEFAULT_RETRIES,
                        help="连接/发送失败的重试次数（缺省 %d）" % DEFAULT_RETRIES)
    parser.add_argument("--dry-run", action="store_true",
                        help="不连服务器、不发邮件，只打印将要发送的内容（配置错误/附件超限事件仍写日志）")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    # ---- 配置 ----
    config, err = load_config()
    if err:
        print("ERROR: %s" % err, file=sys.stderr)
        print("       请参照 .env.example 配置环境变量。", file=sys.stderr)
        write_log(EV_CONFIG_ERROR, err)
        return EXIT_CONFIG_ERROR

    secrets = [config["password"]]

    # ---- 清单 ----
    try:
        manifest, latest = load_latest(args.manifest)
    except ValueError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        write_log(EV_CONFIG_ERROR, str(exc), secrets=secrets)
        return EXIT_CONFIG_ERROR

    game = manifest.get("game") or "未知游戏"
    package = manifest.get("package") or ""

    # ---- 附件判定 ----
    attach_path = None
    attach_note = ""
    if args.no_attachment:
        attach_note = "本次邮件按 --no-attachment 要求不附带 APK，请使用上面的下载链接获取安装包。"
        print("附件     : 已按 --no-attachment 跳过")
    elif not os.path.isfile(args.apk):
        attach_note = "本地未找到 APK 文件，本次只发送下载链接。"
        print("附件     : APK 不存在（%s），降级为只发链接" % args.apk)
        write_log(EV_CONFIG_ERROR, "APK 不存在，降级为只发链接: %s" % args.apk,
                  secrets=secrets)
    else:
        size_bytes = os.path.getsize(args.apk)
        limit_bytes = int(config["max_attachment_mb"] * 1024 * 1024)
        if size_bytes > limit_bytes:
            attach_note = ("APK 大小 %s 超过邮件附件上限 %s，本次只发送下载链接，"
                           "请通过上面的链接获取安装包。"
                           % (human_size(size_bytes), human_size(limit_bytes)))
            print("附件     : 超限（%s > %s），降级为只发链接"
                  % (human_size(size_bytes), human_size(limit_bytes)))
            write_log(EV_ATTACHMENT_TOO_LARGE,
                      "APK %s 超过上限 %s，已降级为只发下载链接"
                      % (human_size(size_bytes), human_size(limit_bytes)),
                      secrets=secrets)
        else:
            attach_path = args.apk
            attach_note = "APK 已作为附件随信附上，大小 %s。" % human_size(size_bytes)
            print("附件     : %s（%s）" % (args.apk, human_size(size_bytes)))

    # ---- 组装 ----
    try:
        msg = build_message(config, game, package, latest, attach_path, attach_note)
    except OSError as exc:
        print("ERROR: 读取附件失败: %s" % exc, file=sys.stderr)
        write_log(EV_CONFIG_ERROR, "读取附件失败: %s" % exc, secrets=secrets)
        return EXIT_CONFIG_ERROR

    print("=" * 62)
    print("邮件准备就绪")
    print("  SMTP     : %s:%s (%s)" % (config["host"], config["port"], config["security"]))
    print("  发件人   : %s" % mask_email(config["from_addr"]))
    print("  收件人   : %s" % mask_email_list(config["recipients"]))
    print("  主题     : %s" % render_subject(game, latest))
    print("  版本     : %s (code %s)" % (latest.get("version_name"), latest.get("version_code")))
    print("  下载地址 : %s" % latest.get("download_url"))
    print("=" * 62)

    if args.dry_run:
        print("[dry-run] 不连接 SMTP、不发送邮件。正文预览：")
        print("          （配置错误/附件超限等事件仍会写入 build/logs/ 便于排查）")
        print("-" * 62)
        print(render_text(game, package, latest, attach_note))
        print("-" * 62)
        return EXIT_OK

    # ---- 发送（带重试）----
    attempts = max(0, int(args.retries)) + 1     # retries 是"重试次数"，总尝试 = retries + 1
    last_kind = None
    last_error = ""

    for attempt in range(1, attempts + 1):
        ok, kind, error = send_once(config, msg)
        if ok:
            detail = "已发送给 %s（第 %d 次尝试），版本 v%s (code %s)" % (
                mask_email_list(config["recipients"]), attempt,
                latest.get("version_name"), latest.get("version_code"))
            write_log(EV_SENT, detail, secrets=secrets)
            print("[SENT] %s" % detail)
            return EXIT_OK

        last_kind = kind
        last_error = error

        if kind == "auth":
            # 认证失败重试没有意义，直接退出
            write_log(EV_AUTH_FAILED, error, secrets=secrets)
            print("[AUTH_FAILED] %s" % error, file=sys.stderr)
            print("认证失败不重试。请检查 OTA_SMTP_USER / OTA_SMTP_PASS 与应用专用密码设置。",
                  file=sys.stderr)
            return EXIT_AUTH_FAILED

        event = EV_CONNECT_FAILED if kind == "connect" else EV_SEND_FAILED
        write_log(event, "第 %d/%d 次尝试失败: %s" % (attempt, attempts, error), secrets=secrets)
        print("[%s] 第 %d/%d 次尝试失败: %s" % (event, attempt, attempts, error),
              file=sys.stderr)

        if attempt < attempts:
            delay = RETRY_BASE_DELAY * (2 ** (attempt - 1))
            print("  %.1f 秒后重试…" % delay, file=sys.stderr)
            time.sleep(delay)

    # 重试耗尽
    final_event = EV_CONNECT_FAILED if last_kind == "connect" else EV_SEND_FAILED
    write_log(final_event, "重试 %d 次后仍失败: %s" % (attempts, last_error), secrets=secrets)
    print("[FAIL] 重试 %d 次后仍失败，放弃。" % attempts, file=sys.stderr)
    return EXIT_SEND_FAILED


if __name__ == "__main__":
    sys.exit(main())
