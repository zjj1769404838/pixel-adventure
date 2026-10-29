#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一条命令发版：导出 APK → 生成 OTA 清单 → 打印 git 步骤。

流程（四步）：

    1. 预检   检查 Godot 可执行文件、APK 目标路径、export_presets.cfg 的 Android 预设
    2. 导出   先 --import（无头导入资源），再 --export-debug Android <apk>
    3. 清单   import 复用 release_manifest.build_manifest() 生成 dist/latest.json
    4. 打印   人工执行的 git / Release 步骤清单（本脚本绝不执行任何 git 命令）

用法（在工程根目录执行）：

    D:/apps/Python313/python.exe scripts/publish_release.py \\
        --version-name 1.0.1 --version-code 2 \\
        --repo https://github.com/<owner>/<repo> --tag v1.0.1 \\
        --changelog "修复跳跃卡墙角" --changelog "新增 OTA 更新检查"

    # 已有 APK，跳过导出，只重算清单 + 打印步骤
    D:/apps/Python313/python.exe scripts/publish_release.py \\
        --version-name 1.0.1 --version-code 2 \\
        --repo https://github.com/owner/repo --tag v1.0.1 --changelog "..." --skip-export

    # 只看会跑哪些命令，什么都不做
    D:/apps/Python313/python.exe scripts/publish_release.py \\
        --version-name 1.0.1 --version-code 2 \\
        --repo https://github.com/owner/repo --tag v1.0.1 --changelog "..." --dry-run

重要约束：
  * 绝不执行 git 命令（工程当前还不是 git 仓库），git 步骤只打印给人看；
  * 绝不写任何凭据到输出里（git 步骤里不含 token / 密码）；
  * 本脚本不修改 godot/ 下任何文件；版本号需要在 export_presets.cfg 里手工改，
    脚本只负责提示和校验（aapt2 读到的真实版本号与传入值不一致时会告警）。
"""

import argparse
import os
import subprocess
import sys

# 复用 release_manifest 的实现（同目录，直接 import）
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

import release_manifest  # noqa: E402  （必须在 sys.path 调整之后导入）

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

GODOT_EXE = "D:/apps/Godot/4.7.2/Godot_v4.7.2-stable_win64_console.exe"
GODOT_PROJECT = "godot"                                  # --path 的工程目录
EXPORT_PRESET = "Android"                                # export_presets.cfg 里的预设名
DEFAULT_APK = os.path.join("build", "pixel-adventure.apk")
DEFAULT_MANIFEST = os.path.join("dist", "latest.json")
EXPORT_PRESETS_CFG = os.path.join("godot", "export_presets.cfg")


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

def say(msg=""):
    print(msg)


def banner(title):
    say("")
    say("=" * 66)
    say("  %s" % title)
    say("=" * 66)


def run_command(cmd, dry_run=False, cwd=None):
    """执行一条命令；dry_run 时只打印。

    返回 True 表示成功（或 dry-run 跳过）。命令用列表形式传递，避免 shell 引号问题。
    """
    printable = " ".join('"%s"' % part if " " in part else part for part in cmd)
    if dry_run:
        say("  [dry-run] 将执行: %s" % printable)
        return True
    say("  $ %s" % printable)
    try:
        proc = subprocess.run(cmd, cwd=cwd, check=False)
    except OSError as exc:
        say("  ERROR: 命令启动失败: %s" % exc)
        return False
    if proc.returncode != 0:
        say("  ERROR: 命令失败，退出码 %d" % proc.returncode)
        return False
    say("  OK（退出码 0）")
    return True


def check_export_preset_version(version_code, version_name):
    """读取 export_presets.cfg，检查 Android 预设里的版本号是否已改。

    只读，不修改文件。返回 (是否一致, 提示行列表)。
    """
    hints = []
    if not os.path.isfile(EXPORT_PRESETS_CFG):
        return True, ["WARNING: 找不到 %s，跳过版本号预检" % EXPORT_PRESETS_CFG]

    try:
        with open(EXPORT_PRESETS_CFG, "r", encoding="utf-8", errors="replace") as fp:
            lines = fp.readlines()
    except OSError as exc:
        return True, ["WARNING: 读取 %s 失败: %s" % (EXPORT_PRESETS_CFG, exc)]

    cfg_code = None
    cfg_name = None
    in_android = False
    # 预设的版本号写在 [preset.N.options] 段里，而不是 [preset.N] 段，
    # 所以要记住"当前正在看第几个 preset"，两个段都要认。
    current_index = None
    android_index = None

    for raw in lines:
        line = raw.strip()
        if line.startswith("[preset."):
            # [preset.2] 或 [preset.2.options]
            body = line[len("[preset."):-1]
            index_text = body.split(".", 1)[0]
            try:
                current_index = int(index_text)
            except ValueError:
                current_index = None
            if not body.endswith(".options"):
                # 进入一个新的预设段：先把上一个候选清掉，等看它的 name
                in_android = False
            continue
        if line == 'name="%s"' % EXPORT_PRESET and current_index is not None:
            in_android = True
            android_index = current_index
            continue
        if in_android and current_index == android_index:
            if line.startswith("version/code="):
                cfg_code = line.split("=", 1)[1].strip()
            elif line.startswith("version/name="):
                cfg_name = line.split("=", 1)[1].strip().strip('"')

    consistent = True
    if cfg_code is not None and str(cfg_code) != str(version_code):
        consistent = False
        hints.append("WARNING: export_presets.cfg 里 Android 的 version/code=%s，"
                     "本次发布传的是 %s" % (cfg_code, version_code))
    if cfg_name is not None and cfg_name != str(version_name):
        consistent = False
        hints.append("WARNING: export_presets.cfg 里 Android 的 version/name=\"%s\"，"
                     "本次发布传的是 %s" % (cfg_name, version_name))
    if not consistent:
        hints.append("         请先手工把 %s 改成 version/code=%s、version/name=\"%s\"，"
                     "否则导出的 APK 版本号仍是旧的。" % (
                         EXPORT_PRESETS_CFG, version_code, version_name))
    elif cfg_code is None and cfg_name is None:
        hints.append("WARNING: 没在 %s 里找到 Android 的 version 字段，请人工确认"
                     % EXPORT_PRESETS_CFG)
    return consistent, hints


def print_git_steps(version_name, version_code, repo, tag, apk_path, manifest_path):
    """打印人工执行的 git / Release 步骤。不含任何凭据。"""
    repo_norm = release_manifest.normalize_repo(repo)
    apk_posix = apk_path.replace("\\", "/")
    manifest_posix = manifest_path.replace("\\", "/")

    banner("第 4 步：人工执行的 git / Release 步骤（本脚本不执行任何 git 命令）")
    say("下面这些命令请你自己在工程根目录手工执行。本工程当前还不是 git 仓库，")
    say("所以第一步是初始化；如果你已经有仓库了，跳过 git init 那两行。")
    say("")
    say("--- 1) 初始化仓库（仅首次需要）---")
    say("  git init")
    say("  git branch -M main")
    say("  git remote add origin %s.git" % repo_norm)
    say("")
    say("--- 2) 提交 APK 与清单 ---")
    say("  git add %s" % apk_posix)
    say("  git add %s" % manifest_posix)
    say("  git add .gitignore .env.example docs/OTA.md")
    say("  git add scripts/release_manifest.py scripts/publish_release.py scripts/send_release_email.py")
    say("  git add scripts/tests/")
    say("  git commit -m \"release: v%s (code %s)\"" % (version_name, version_code))
    say("")
    say("--- 3) 打 tag 并推送 ---")
    say("  git tag -a %s -m \"v%s (code %s)\"" % (tag, version_name, version_code))
    say("  git push -u origin main")
    say("  git push --tags")
    say("")
    say("--- 4) 建 GitHub Release 并上传 APK ---")
    say("  打开 %s/releases/new?tag=%s" % (repo_norm, tag))
    say("  Title: v%s" % version_name)
    say("  Assets: 上传 %s" % apk_posix)
    say("  发布后确认这个地址能直接下到 APK：")
    say("    %s/releases/download/%s/%s" % (
        repo_norm, tag, os.path.basename(apk_path)))
    say("")
    say("--- 5) 把清单放到游戏能拉到的地方（任选其一）---")
    say("  a) 把 %s 也作为 Release 资产上传，游戏从「最新 Release 资产」读取；" % manifest_posix)
    say("  b) 提交到 gh-pages 分支，游戏从 https://<owner>.github.io/<repo>/latest.json 读取；")
    say("  c) 放到任意 HTTPS 静态托管（对象存储 / CDN），游戏从该地址读取。")
    say("")
    say("--- 6) 发邮件通知（可选）---")
    say("  先按 .env.example 配好环境变量（.env 已在 .gitignore 里），然后：")
    say("    python scripts/send_release_email.py --manifest %s --apk %s"
        % (manifest_posix, apk_posix))
    say("")
    say("注意：以上步骤不包含任何凭据。git push 用你本机已配置的 SSH key 或")
    say("      credential helper；不要把 token 写进命令历史或脚本里。")
    say("")


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        prog="publish_release.py",
        description="一条命令发版：导出 APK → 生成 OTA 清单 → 打印 git 步骤（不执行 git）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例：\n"
               "  python scripts/publish_release.py --version-name 1.0.1 --version-code 2 \\\n"
               "      --repo https://github.com/owner/repo --tag v1.0.1 \\\n"
               "      --changelog \"修复跳跃卡墙角\" --changelog \"新增 OTA 更新检查\"\n"
               "  python scripts/publish_release.py --version-name 1.0.1 --version-code 2 \\\n"
               "      --repo https://github.com/owner/repo --tag v1.0.1 \\\n"
               "      --changelog \"...\" --skip-export --dry-run\n",
    )
    parser.add_argument("--version-name", required=True, help="版本名，如 1.0.1")
    parser.add_argument("--version-code", required=True, type=int, help="版本号（整数），如 2")
    parser.add_argument("--repo", required=True, help="GitHub 仓库地址，如 https://github.com/owner/repo")
    parser.add_argument("--tag", required=True, help="Release tag，如 v1.0.1")
    parser.add_argument("--changelog", action="append", default=[],
                        help="更新说明，可重复传入多次")
    parser.add_argument("--apk", default=DEFAULT_APK, help="APK 路径（缺省 %s）" % DEFAULT_APK)
    parser.add_argument("--out", default=DEFAULT_MANIFEST, help="清单输出路径（缺省 %s）" % DEFAULT_MANIFEST)
    parser.add_argument("--godot", default=GODOT_EXE, help="Godot 控制台版可执行文件路径")
    parser.add_argument("--preset", default=EXPORT_PRESET, help="导出预设名（缺省 Android）")
    parser.add_argument("--game", default=None, help="游戏名（缺省沿用清单/内置值）")
    parser.add_argument("--package", default=None, help="包名（缺省沿用清单/APK 真实值）")
    parser.add_argument("--min-version-code", type=int,
                        default=release_manifest.DEFAULT_MIN_VERSION_CODE,
                        help="最低可运行 versionCode（缺省 1）")
    parser.add_argument("--mandatory", action="store_true", help="标记为强制更新")
    parser.add_argument("--published-at", default=None,
                        help="发布时间（UTC，YYYY-MM-DDTHH:MM:SSZ），缺省取当前时间")
    parser.add_argument("--skip-export", action="store_true",
                        help="跳过导出，直接用现有 APK")
    parser.add_argument("--dry-run", action="store_true",
                        help="只打印将执行的命令，不真跑（也不写清单）")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if not args.changelog:
        args.changelog = []

    apk_path = args.apk
    manifest_path = args.out

    banner("像素冒险 · 发版 v%s (code %s)" % (args.version_name, args.version_code))
    say("  仓库      : %s" % release_manifest.normalize_repo(args.repo))
    say("  tag       : %s" % args.tag)
    say("  APK       : %s" % apk_path)
    say("  清单      : %s" % manifest_path)
    say("  导出      : %s" % ("跳过（--skip-export）" if args.skip_export else "执行"))
    say("  模式      : %s" % ("dry-run（只打印）" if args.dry_run else "真实执行"))
    say("  更新说明  : %d 条" % len(args.changelog))
    for line in args.changelog:
        say("              - %s" % line)

    # ---- 第 1 步：预检 ----
    banner("第 1 步：预检")
    ok = True

    if not args.skip_export:
        if os.path.isfile(args.godot):
            say("  Godot     : %s" % args.godot)
        else:
            say("  ERROR: 找不到 Godot 可执行文件: %s" % args.godot)
            say("         用 --godot 指定，或加 --skip-export 直接用现有 APK。")
            ok = False
        if not os.path.isdir(GODOT_PROJECT):
            say("  ERROR: 找不到 Godot 工程目录: %s" % GODOT_PROJECT)
            ok = False
        else:
            say("  工程目录  : %s" % GODOT_PROJECT)

    consistent, hints = check_export_preset_version(args.version_code, args.version_name)
    for line in hints:
        say("  %s" % line)
    if not consistent:
        say("  （不阻断流程：清单仍按命令行传入的版本号生成，但 APK 里的版本号可能是旧的）")

    if args.skip_export:
        if os.path.isfile(apk_path):
            say("  现有 APK  : %s（%d 字节）" % (apk_path, os.path.getsize(apk_path)))
        else:
            say("  ERROR: --skip-export 但找不到 APK: %s" % apk_path)
            ok = False

    if not ok:
        say("")
        say("预检未通过，终止。")
        return 1
    say("  预检通过")

    # ---- 第 2 步：导出 ----
    banner("第 2 步：导出 APK")
    if args.skip_export:
        say("  已指定 --skip-export，跳过导出，直接使用 %s" % apk_path)
    else:
        # 导出前必须重新导入资源，否则新加的素材不会进 pck
        import_cmd = [args.godot, "--headless", "--path", GODOT_PROJECT, "--import"]
        if not run_command(import_cmd, dry_run=args.dry_run):
            say("")
            say("资源导入失败，终止。")
            return 1

        export_cmd = [args.godot, "--headless", "--path", GODOT_PROJECT,
                      "--export-debug", args.preset, apk_path]
        if not run_command(export_cmd, dry_run=args.dry_run):
            say("")
            say("导出失败，终止。")
            return 1

        if not args.dry_run:
            if os.path.isfile(apk_path):
                say("  导出完成: %s（%d 字节）" % (apk_path, os.path.getsize(apk_path)))
            else:
                say("  ERROR: 导出命令返回成功，但没有生成 %s" % apk_path)
                return 1

    # ---- 第 3 步：生成清单 ----
    banner("第 3 步：生成 OTA 清单")
    if args.dry_run:
        say("  [dry-run] 将调用 release_manifest.build_manifest()：")
        say("            apk=%s version_name=%s version_code=%s out=%s"
            % (apk_path, args.version_name, args.version_code, manifest_path))
        say("  [dry-run] 不写任何文件。")
    else:
        try:
            release_manifest.build_manifest(
                apk_path=apk_path,
                version_name=args.version_name,
                version_code=args.version_code,
                changelog=args.changelog,
                repo=args.repo,
                tag=args.tag,
                published_at=args.published_at,
                mandatory=args.mandatory,
                min_version_code=args.min_version_code,
                out_path=manifest_path,
                game=args.game,
                package=args.package,
            )
        except FileNotFoundError as exc:
            say("  ERROR: %s" % exc)
            return 1

    # ---- 第 4 步：打印 git 步骤 ----
    print_git_steps(
        version_name=args.version_name,
        version_code=args.version_code,
        repo=args.repo,
        tag=args.tag,
        apk_path=apk_path,
        manifest_path=manifest_path,
    )

    if args.dry_run:
        say("dry-run 结束：以上命令都没有真正执行。")
    else:
        say("发版准备完成。请按上面第 4 步的人工清单操作。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
