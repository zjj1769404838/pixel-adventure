#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 / 校验《像素冒险》的 OTA 版本发布清单 dist/latest.json。

这个脚本是发布链路的"真相之源"：它把 build/pixel-adventure.apk 的真实字节信息
（SHA-256、字节大小）和 aapt2 解析出的真实包信息（package / versionCode /
versionName）固化成一份游戏端可以直接解析的 JSON 清单。

三个子命令：

    build   从 APK 生成 / 更新 dist/latest.json（旧的 latest 自动压进 history）
    verify  重新计算 APK 的 sha256 / size，与清单里的 latest 比对
    show    把清单内容打成人类可读的摘要

用法（在工程根目录执行）：

    D:/apps/Python313/python.exe scripts/release_manifest.py build \\
        --apk build/pixel-adventure.apk \\
        --version-name 1.0.1 --version-code 2 \\
        --changelog "修复跳跃卡墙角" --changelog "新增 OTA 更新检查" \\
        --repo https://github.com/<owner>/<repo> --tag v1.0.1 \\
        --out dist/latest.json

    D:/apps/Python313/python.exe scripts/release_manifest.py verify \\
        --manifest dist/latest.json --apk build/pixel-adventure.apk

    D:/apps/Python313/python.exe scripts/release_manifest.py show \\
        --manifest dist/latest.json

设计要点：
  * 只用标准库（hashlib / json / argparse / subprocess），不引入任何第三方依赖；
  * APK 分块读取（64KB）算 SHA-256，避免 30MB 文件一次性读进内存；
  * 版本号以命令行传入为准（发布时可能先改 export_presets.cfg 再导出，此时
    aapt2 读到的才是真相）；两者不一致时只打印 WARNING，不擅自改用户输入；
  * 本模块的 build_manifest() 可被 publish_release.py 直接 import 复用，
    保证"一条命令发版"与"手动发版"走的是同一份实现。
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

SCHEMA_VERSION = 1                     # 清单结构版本，游戏端据此判断能否解析
DEFAULT_GAME = "像素冒险"               # 缺省游戏名（可用 --game 覆盖）
DEFAULT_PACKAGE = "com.pixelstudio.pixeladventure"   # 缺省包名（可用 --package 覆盖）
DEFAULT_OUT = os.path.join("dist", "latest.json")
DEFAULT_MIN_VERSION_CODE = 1

CHUNK_SIZE = 64 * 1024                 # 64KB，分块读算摘要
HISTORY_LIMIT = 10                     # history 最多保留条数

# Android SDK 的常见位置（本机实测 D:/apps/android-sdk 有 35.0.0 / 36.1.0 两套）
ANDROID_SDK_CANDIDATES = (
    "D:/apps/android-sdk",
    "D:\\apps\\android-sdk",
    os.path.join(os.environ.get("LOCALAPPDATA", ""), "Android", "Sdk"),
)

# aapt2 dump badging 的关键行形如：
#   package: name='com.x.y' versionCode='1' versionName='1.0.0' platformBuild...
RE_PACKAGE_LINE = re.compile(r"package:\s+name='([^']*)'")
RE_VERSION_CODE = re.compile(r"versionCode='([^']*)'")
RE_VERSION_NAME = re.compile(r"versionName='([^']*)'")
RE_APP_LABEL = re.compile(r"^application-label:'([^']*)'", re.MULTILINE)


# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

def sha256_of(path, chunk_size=CHUNK_SIZE):
    """分块计算文件 SHA-256，返回 64 位小写 hex 字符串。"""
    h = hashlib.sha256()
    with open(path, "rb") as fp:
        while True:
            block = fp.read(chunk_size)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def file_size(path):
    """返回文件字节大小。"""
    return os.path.getsize(path)


def human_size(num_bytes):
    """把字节数转成人能读的形式，例如 30332907 -> '28.9 MB'。"""
    value = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024.0 or unit == "TB":
            if unit == "B":
                return "%d %s" % (int(value), unit)
            return "%.1f %s" % (value, unit)
        value /= 1024.0
    return "%.1f TB" % value


def utc_now_iso():
    """当前 UTC 时间，格式 YYYY-MM-DDTHH:MM:SSZ（秒级，不带小数）。"""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_repo(repo):
    """把仓库地址规范成不带尾斜杠、不带 .git 的形式。"""
    text = (repo or "").strip()
    while text.endswith("/"):
        text = text[:-1]
    if text.endswith(".git"):
        text = text[:-4]
    return text


def _decode(raw):
    """aapt2 在 Windows 上的输出可能是 utf-8 也可能是 gbk，逐个尝试解码。"""
    for enc in ("utf-8", "gbk", "cp936"):
        try:
            return raw.decode(enc)
        except (UnicodeDecodeError, LookupError):
            continue
    return raw.decode("utf-8", "replace")


# ---------------------------------------------------------------------------
# aapt2：读取 APK 真实包信息
# ---------------------------------------------------------------------------

def find_aapt2():
    """定位 aapt2 可执行文件；找不到返回 None（此时退化为只用命令行参数）。"""
    env_path = os.environ.get("AAPT2")
    if env_path and os.path.isfile(env_path):
        return env_path

    for sdk in ANDROID_SDK_CANDIDATES:
        if not sdk:
            continue
        build_tools = os.path.join(sdk, "build-tools")
        if not os.path.isdir(build_tools):
            continue
        # 按版本号从高到低挑（36.1.0 优先于 35.0.0）
        try:
            versions = sorted(os.listdir(build_tools), reverse=True)
        except OSError:
            continue
        for ver in versions:
            for exe in ("aapt2.exe", "aapt2"):
                candidate = os.path.join(build_tools, ver, exe)
                if os.path.isfile(candidate):
                    return candidate

    found = shutil.which("aapt2")
    return found


def read_apk_badging(apk_path, aapt2_path=None):
    """用 aapt2 dump badging 读取 APK 元信息。

    返回 dict：{"package", "version_code", "version_name", "label"}，
    读不到（没有 aapt2 / 命令失败 / 输出不含 package 行）时返回空 dict。
    """
    aapt2_path = aapt2_path or find_aapt2()
    if not aapt2_path:
        return {}

    try:
        proc = subprocess.run(
            [aapt2_path, "dump", "badging", apk_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError:
        return {}

    text = _decode(proc.stdout or b"")
    if proc.returncode != 0 or "package:" not in text:
        return {}

    info = {}
    m = RE_PACKAGE_LINE.search(text)
    if m:
        info["package"] = m.group(1)
    m = RE_VERSION_CODE.search(text)
    if m:
        try:
            info["version_code"] = int(m.group(1))
        except ValueError:
            info["version_code"] = m.group(1)
    m = RE_VERSION_NAME.search(text)
    if m:
        info["version_name"] = m.group(1)
    m = RE_APP_LABEL.search(text)
    if m:
        info["label"] = m.group(1)
    return info


# ---------------------------------------------------------------------------
# 清单读写
# ---------------------------------------------------------------------------

def load_manifest(path):
    """读取已有清单；文件不存在或解析失败返回 None。"""
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as fp:
            data = json.load(fp)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def save_manifest(manifest, path):
    """写清单：UTF-8、indent=2、ensure_ascii=False、末尾换行。"""
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fp:
        json.dump(manifest, fp, ensure_ascii=False, indent=2)
        fp.write("\n")


def make_release_entry(version_name, version_code, published_at, size_bytes,
                       sha256, min_version_code, mandatory, changelog,
                       download_url, release_page):
    """构造 latest / history 里的一条版本条目（字段顺序与文档一致）。"""
    return {
        "version_name": version_name,
        "version_code": int(version_code),
        "published_at": published_at,
        "size_bytes": int(size_bytes),
        "sha256": sha256,
        "min_supported_version_code": int(min_version_code),
        "mandatory": bool(mandatory),
        "changelog": list(changelog),
        "download_url": download_url,
        "release_page": release_page,
    }


# ---------------------------------------------------------------------------
# 核心：生成清单（供 publish_release.py 复用）
# ---------------------------------------------------------------------------

def build_manifest(apk_path,
                   version_name,
                   version_code,
                   changelog,
                   repo,
                   tag,
                   published_at=None,
                   mandatory=False,
                   min_version_code=DEFAULT_MIN_VERSION_CODE,
                   out_path=DEFAULT_OUT,
                   game=None,
                   package=None,
                   quiet=False):
    """从 APK 生成 / 更新发布清单，返回写好的 manifest dict。

    参数与 CLI 一一对应；out_path 已存在时，旧的 latest 会被压进 history 头部。
    异常：APK 不存在时抛 FileNotFoundError。
    """
    if not os.path.isfile(apk_path):
        raise FileNotFoundError("找不到 APK 文件: %s" % apk_path)

    def say(msg):
        if not quiet:
            print(msg)

    # 1) APK 真实字节信息
    digest = sha256_of(apk_path)
    size_bytes = file_size(apk_path)

    # 2) aapt2 读真实包信息，与命令行传入的比对
    badging = read_apk_badging(apk_path)
    if badging:
        real_code = badging.get("version_code")
        real_name = badging.get("version_name")
        real_pkg = badging.get("package")
        mismatch = []
        if real_code is not None and str(real_code) != str(version_code):
            mismatch.append("versionCode: APK 内为 %s，命令行传入 %s" % (real_code, version_code))
        if real_name is not None and str(real_name) != str(version_name):
            mismatch.append("versionName: APK 内为 %s，命令行传入 %s" % (real_name, version_name))
        if mismatch:
            say("WARNING: APK 内的版本号与命令行传入不一致，将以命令行传入为准：")
            for line in mismatch:
                say("         - %s" % line)
            say("         请核对 godot/export_presets.cfg 里的 "
                "version/code 与 version/name 是否已经改过，")
            say("         否则清单里的版本号会和真实 APK 对不上，OTA 会反复提示更新。")
    else:
        say("WARNING: 未能用 aapt2 解析 APK 包信息（aapt2 缺失或解析失败），"
            "本次只用命令行参数。")
        real_pkg = None

    # 3) 旧清单 → history
    old = load_manifest(out_path)
    history = []
    if old:
        old_latest = old.get("latest")
        if isinstance(old_latest, dict):
            history.append(old_latest)
        old_history = old.get("history")
        if isinstance(old_history, list):
            history.extend([item for item in old_history if isinstance(item, dict)])
        history = history[:HISTORY_LIMIT]

    # 4) game / package：命令行 > 旧清单 > aapt2 > 内置缺省
    final_game = game or (old or {}).get("game") or DEFAULT_GAME
    final_package = (package
                     or (old or {}).get("package")
                     or real_pkg
                     or DEFAULT_PACKAGE)

    # 5) 链接
    repo_norm = normalize_repo(repo)
    tag_norm = (tag or "").strip()
    apk_name = os.path.basename(apk_path)
    download_url = "%s/releases/download/%s/%s" % (repo_norm, tag_norm, apk_name)
    release_page = "%s/releases/tag/%s" % (repo_norm, tag_norm)

    entry = make_release_entry(
        version_name=version_name,
        version_code=version_code,
        published_at=published_at or utc_now_iso(),
        size_bytes=size_bytes,
        sha256=digest,
        min_version_code=min_version_code,
        mandatory=mandatory,
        changelog=changelog,
        download_url=download_url,
        release_page=release_page,
    )

    manifest = {
        "schema": SCHEMA_VERSION,
        "game": final_game,
        "package": final_package,
        "latest": entry,
        "history": history,
    }
    save_manifest(manifest, out_path)

    # 6) 摘要
    say("=" * 62)
    say("发布清单已生成: %s" % out_path)
    say("-" * 62)
    say("  游戏        : %s" % final_game)
    say("  包名        : %s" % final_package)
    say("  版本        : %s (code %s)" % (entry["version_name"], entry["version_code"]))
    say("  发布时间    : %s" % entry["published_at"])
    say("  APK 大小    : %d 字节 (%s)" % (size_bytes, human_size(size_bytes)))
    say("  SHA-256     : %s…（前 12 位）" % digest[:12])
    say("  下载地址    : %s" % download_url)
    say("  发布页      : %s" % release_page)
    say("  更新说明    : %d 条" % len(entry["changelog"]))
    for line in entry["changelog"]:
        say("                - %s" % line)
    say("  历史版本    : %d 条" % len(history))
    say("=" * 62)
    return manifest


# ---------------------------------------------------------------------------
# 子命令：build
# ---------------------------------------------------------------------------

def cmd_build(args):
    try:
        build_manifest(
            apk_path=args.apk,
            version_name=args.version_name,
            version_code=args.version_code,
            changelog=args.changelog or [],
            repo=args.repo,
            tag=args.tag,
            published_at=args.published_at,
            mandatory=args.mandatory,
            min_version_code=args.min_version_code,
            out_path=args.out,
            game=args.game,
            package=args.package,
        )
    except FileNotFoundError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 1
    return 0


# ---------------------------------------------------------------------------
# 子命令：verify
# ---------------------------------------------------------------------------

def cmd_verify(args):
    if not os.path.isfile(args.manifest):
        print("ERROR: 找不到清单文件: %s" % args.manifest, file=sys.stderr)
        return 1
    if not os.path.isfile(args.apk):
        print("ERROR: 找不到 APK 文件: %s" % args.apk, file=sys.stderr)
        return 1

    try:
        with open(args.manifest, "r", encoding="utf-8") as fp:
            manifest = json.load(fp)
    except (OSError, ValueError) as exc:
        print("ERROR: 清单读取失败: %s" % exc, file=sys.stderr)
        return 1

    latest = manifest.get("latest") if isinstance(manifest, dict) else None
    if not isinstance(latest, dict):
        print("ERROR: 清单里没有 latest 段，结构不对", file=sys.stderr)
        return 1

    expect_sha = latest.get("sha256")
    expect_size = latest.get("size_bytes")

    actual_sha = sha256_of(args.apk)
    actual_size = file_size(args.apk)

    problems = []
    if str(expect_sha) != actual_sha:
        problems.append("sha256 不符: 期望 %s，实际 %s" % (expect_sha, actual_sha))
    if int(expect_size) != int(actual_size):
        problems.append("size_bytes 不符: 期望 %s，实际 %s" % (expect_size, actual_size))

    if problems:
        print("[FAIL] 清单校验不通过（%s）" % args.manifest)
        print("-" * 62)
        for line in problems:
            print("  %s" % line)
        print("-" * 62)
        print("提示：APK 被重新导出过？重新跑一次 build 更新清单，再上传到 Release。")
        return 1

    print("[PASS] APK 与清单一致")
    print("-" * 62)
    print("  清单     : %s" % args.manifest)
    print("  APK      : %s" % args.apk)
    print("  版本     : %s (code %s)" % (latest.get("version_name"), latest.get("version_code")))
    print("  sha256   : %s" % actual_sha)
    print("  size     : %d 字节 (%s)" % (actual_size, human_size(actual_size)))
    print("-" * 62)
    return 0


# ---------------------------------------------------------------------------
# 子命令：show
# ---------------------------------------------------------------------------

def _print_entry(title, entry):
    """打印一条版本条目。"""
    print("[%s]" % title)
    print("  版本号      : %s (code %s)" % (entry.get("version_name"), entry.get("version_code")))
    print("  发布时间    : %s" % entry.get("published_at"))
    size = entry.get("size_bytes") or 0
    print("  文件大小    : %d 字节 (%s)" % (size, human_size(size)))
    print("  SHA-256     : %s" % entry.get("sha256"))
    print("  最低支持    : code %s" % entry.get("min_supported_version_code"))
    print("  强制更新    : %s" % ("是" if entry.get("mandatory") else "否"))
    print("  下载地址    : %s" % entry.get("download_url"))
    print("  发布页      : %s" % entry.get("release_page"))
    print("  更新说明    :")
    for line in entry.get("changelog") or []:
        print("                - %s" % line)


def cmd_show(args):
    if not os.path.isfile(args.manifest):
        print("ERROR: 找不到清单文件: %s" % args.manifest, file=sys.stderr)
        return 1
    try:
        with open(args.manifest, "r", encoding="utf-8") as fp:
            manifest = json.load(fp)
    except (OSError, ValueError) as exc:
        print("ERROR: 清单读取失败: %s" % exc, file=sys.stderr)
        return 1

    print("=" * 62)
    print("清单文件: %s" % args.manifest)
    print("  schema  : %s" % manifest.get("schema"))
    print("  游戏    : %s" % manifest.get("game"))
    print("  包名    : %s" % manifest.get("package"))
    print("=" * 62)

    latest = manifest.get("latest")
    if isinstance(latest, dict):
        _print_entry("latest 当前版本", latest)

    history = manifest.get("history") or []
    print("=" * 62)
    print("history 历史版本: %d 条" % len(history))
    for idx, entry in enumerate(history, 1):
        if not isinstance(entry, dict):
            continue
        print("  %d) %s (code %s)  %s" % (
            idx, entry.get("version_name"), entry.get("version_code"),
            entry.get("published_at")))
    print("=" * 62)
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        prog="release_manifest.py",
        description="生成 / 校验《像素冒险》的 OTA 版本发布清单 dist/latest.json",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例：\n"
               "  python scripts/release_manifest.py build --apk build/pixel-adventure.apk \\\n"
               "      --version-name 1.0.1 --version-code 2 --changelog \"修复跳跃卡墙角\" \\\n"
               "      --repo https://github.com/owner/repo --tag v1.0.1 --out dist/latest.json\n"
               "  python scripts/release_manifest.py verify --manifest dist/latest.json \\\n"
               "      --apk build/pixel-adventure.apk\n"
               "  python scripts/release_manifest.py show --manifest dist/latest.json\n",
    )
    sub = parser.add_subparsers(dest="command", metavar="{build,verify,show}")

    # ---- build ----
    p_build = sub.add_parser(
        "build", help="从 APK 生成 / 更新发布清单",
        description="计算 APK 的 SHA-256 与大小，用 aapt2 校验版本号，写出 dist/latest.json")
    p_build.add_argument("--apk", default=os.path.join("build", "pixel-adventure.apk"),
                         help="APK 路径（缺省 build/pixel-adventure.apk）")
    p_build.add_argument("--version-name", required=True, help="版本名，如 1.0.1")
    p_build.add_argument("--version-code", required=True, type=int, help="版本号（整数），如 2")
    p_build.add_argument("--changelog", action="append", default=[],
                         help="更新说明，可重复传入多次，每条一行")
    p_build.add_argument("--repo", required=True, help="GitHub 仓库地址，如 https://github.com/owner/repo")
    p_build.add_argument("--tag", required=True, help="Release tag，如 v1.0.1")
    p_build.add_argument("--published-at", default=None,
                         help="发布时间（UTC，YYYY-MM-DDTHH:MM:SSZ），缺省取当前时间")
    p_build.add_argument("--mandatory", action="store_true", help="标记为强制更新")
    p_build.add_argument("--min-version-code", type=int, default=DEFAULT_MIN_VERSION_CODE,
                         help="最低可运行的 versionCode（缺省 1）")
    p_build.add_argument("--game", default=None, help="游戏名（缺省 %s）" % DEFAULT_GAME)
    p_build.add_argument("--package", default=None, help="包名（缺省取 APK 内真实包名，再退到 %s）" % DEFAULT_PACKAGE)
    p_build.add_argument("--out", default=DEFAULT_OUT, help="清单输出路径（缺省 dist/latest.json）")
    p_build.set_defaults(func=cmd_build)

    # ---- verify ----
    p_verify = sub.add_parser(
        "verify", help="校验 APK 与清单是否一致",
        description="重新计算 APK 的 sha256 / size，与清单 latest 比对，一致返回 0，不一致返回 1")
    p_verify.add_argument("--manifest", default=DEFAULT_OUT, help="清单路径（缺省 dist/latest.json）")
    p_verify.add_argument("--apk", default=os.path.join("build", "pixel-adventure.apk"),
                          help="APK 路径（缺省 build/pixel-adventure.apk）")
    p_verify.set_defaults(func=cmd_verify)

    # ---- show ----
    p_show = sub.add_parser("show", help="打印清单摘要",
                            description="把 dist/latest.json 打成人类可读的摘要")
    p_show.add_argument("--manifest", default=DEFAULT_OUT, help="清单路径（缺省 dist/latest.json）")
    p_show.set_defaults(func=cmd_show)

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "command", None):
        parser.print_help()
        return 1
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
