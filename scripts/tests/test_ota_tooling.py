# -*- coding: utf-8 -*-
"""OTA 发布工具链的单元测试（只用标准库 unittest / unittest.mock）。

覆盖：
  * release_manifest: 生成清单的 sha256 / size / 字段结构、verify 的 PASS 与 FAIL
  * release_manifest: history 累积
  * send_release_email: 成功路径、认证失败不重试、连接失败重试、附件超限降级
  * send_release_email: 日志不含密码、收件人脱敏

**绝不真发邮件、绝不真连网**：所有 SMTP 交互都被 mock 掉。

运行（在工程根目录执行）：
    D:/apps/Python313/python.exe -m unittest discover -s scripts/tests -v
"""

import contextlib
import hashlib
import io
import json
import os
import shutil
import smtplib
import sys
import tempfile
import unittest
from email import message_from_string
from unittest import mock

# 让测试能 import 到 scripts/ 下的模块（unittest discover 只把 scripts/tests 放进 path）
_SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import release_manifest          # noqa: E402
import send_release_email        # noqa: E402


# ---------------------------------------------------------------------------
# 公共辅助
# ---------------------------------------------------------------------------

def quiet(func, *args, **kwargs):
    """调用 func 并吞掉它的 stdout，返回 (返回值, 捕获到的输出)。"""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        result = func(*args, **kwargs)
    return result, buf.getvalue()


class TempDirTestCase(unittest.TestCase):
    """每个测试用例一个临时目录，结束后清理。"""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ota-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def path(self, *parts):
        return os.path.join(self.tmp, *parts)

    def make_fake_apk(self, name="pixel-adventure.apk", payload=b"FAKE-APK-BYTES" * 100):
        """写一个假 APK 文件，返回路径。"""
        apk = self.path(name)
        with open(apk, "wb") as fp:
            fp.write(payload)
        return apk


# ---------------------------------------------------------------------------
# release_manifest 测试
# ---------------------------------------------------------------------------

class TestReleaseManifestBuild(TempDirTestCase):

    def _build(self, apk, out, version_name="1.0.1", version_code=2,
               changelog=("修复跳跃卡墙角", "新增 OTA 更新检查")):
        argv = [
            "build",
            "--apk", apk,
            "--version-name", version_name,
            "--version-code", str(version_code),
            "--repo", "https://github.com/owner/repo",
            "--tag", "v%s" % version_name,
            "--published-at", "2026-10-29T14:00:00Z",
            "--min-version-code", "1",
            "--out", out,
        ]
        for item in changelog:
            argv.extend(["--changelog", item])
        return quiet(release_manifest.main, argv)

    def test_build_writes_correct_hash_size_and_shape(self):
        """build 生成的清单：sha256 / size 正确，字段齐全，结构符合约定。"""
        payload = b"FAKE-APK-BYTES" * 100
        apk = self.make_fake_apk(payload=payload)
        out = self.path("dist", "latest.json")

        code, output = self._build(apk, out)
        self.assertEqual(code, 0, "build 应返回 0，输出：%s" % output)
        self.assertTrue(os.path.isfile(out), "清单文件应被创建")

        with open(out, "r", encoding="utf-8") as fp:
            manifest = json.load(fp)

        # --- 顶层结构 ---
        self.assertEqual(set(manifest.keys()),
                         {"schema", "game", "package", "latest", "history"})
        self.assertEqual(manifest["schema"], 1)
        self.assertEqual(manifest["game"], "像素冒险")
        self.assertEqual(manifest["package"], "com.pixelstudio.pixeladventure")
        self.assertIsInstance(manifest["history"], list)
        self.assertEqual(manifest["history"], [], "首次生成 history 应为空")

        # --- latest 字段 ---
        latest = manifest["latest"]
        self.assertEqual(set(latest.keys()), {
            "version_name", "version_code", "published_at", "size_bytes",
            "sha256", "min_supported_version_code", "mandatory", "changelog",
            "download_url", "release_page",
        })

        expect_sha = hashlib.sha256(payload).hexdigest()
        self.assertEqual(latest["sha256"], expect_sha)
        self.assertEqual(len(latest["sha256"]), 64)
        self.assertEqual(latest["sha256"], latest["sha256"].lower(), "sha256 必须小写")
        self.assertEqual(latest["size_bytes"], len(payload))

        self.assertEqual(latest["version_name"], "1.0.1")
        self.assertEqual(latest["version_code"], 2)
        self.assertIsInstance(latest["version_code"], int)
        self.assertEqual(latest["published_at"], "2026-10-29T14:00:00Z")
        self.assertEqual(latest["min_supported_version_code"], 1)
        self.assertIs(latest["mandatory"], False)
        self.assertEqual(latest["changelog"], ["修复跳跃卡墙角", "新增 OTA 更新检查"])
        self.assertEqual(latest["download_url"],
                         "https://github.com/owner/repo/releases/download/v1.0.1/pixel-adventure.apk")
        self.assertEqual(latest["release_page"],
                         "https://github.com/owner/repo/releases/tag/v1.0.1")

    def test_build_output_is_utf8_indent2_with_trailing_newline(self):
        """清单必须是 UTF-8、indent=2、末尾换行（游戏端与 diff 都依赖这点）。"""
        apk = self.make_fake_apk()
        out = self.path("dist", "latest.json")
        self._build(apk, out)

        with open(out, "rb") as fp:
            raw = fp.read()

        self.assertTrue(raw.endswith(b"\n"), "文件末尾必须有换行")
        self.assertNotIn(b"\r\n", raw, "换行必须是 \\n，不能是 \\r\\n")
        text = raw.decode("utf-8")           # 解不出 utf-8 就会抛异常
        self.assertIn("像素冒险", text, "中文不能转义成 \\uXXXX")
        self.assertIn('\n  "schema": 1,', text, "缩进应为 2 空格")

    def test_mandatory_flag(self):
        """--mandatory 应写入 latest.mandatory = true。"""
        apk = self.make_fake_apk()
        out = self.path("dist", "latest.json")
        argv = [
            "build", "--apk", apk, "--version-name", "1.0.2", "--version-code", "3",
            "--repo", "https://github.com/owner/repo", "--tag", "v1.0.2",
            "--published-at", "2026-10-29T15:00:00Z", "--mandatory",
            "--out", out,
        ]
        code, _ = quiet(release_manifest.main, argv)
        self.assertEqual(code, 0)
        with open(out, "r", encoding="utf-8") as fp:
            manifest = json.load(fp)
        self.assertIs(manifest["latest"]["mandatory"], True)

    def test_build_missing_apk_returns_1(self):
        """APK 不存在时 build 应返回 1，且不留下半个清单。"""
        out = self.path("dist", "latest.json")
        code, _ = self._build(self.path("not-exist.apk"), out)
        self.assertEqual(code, 1)
        self.assertFalse(os.path.isfile(out))


class TestReleaseManifestVerify(TempDirTestCase):

    def _build(self, apk, out):
        argv = [
            "build", "--apk", apk, "--version-name", "1.0.1", "--version-code", "2",
            "--repo", "https://github.com/owner/repo", "--tag", "v1.0.1",
            "--published-at", "2026-10-29T14:00:00Z", "--out", out,
        ]
        return quiet(release_manifest.main, argv)

    def test_verify_pass(self):
        """未改动 APK 时 verify 返回 0 并打印 PASS。"""
        apk = self.make_fake_apk()
        out = self.path("dist", "latest.json")
        self._build(apk, out)

        code, output = quiet(release_manifest.main,
                             ["verify", "--manifest", out, "--apk", apk])
        self.assertEqual(code, 0)
        self.assertIn("[PASS]", output)

    def test_verify_fail_after_tamper(self):
        """篡改 APK 一个字节后 verify 返回 1，并指出 sha256 不符。"""
        apk = self.make_fake_apk()
        out = self.path("dist", "latest.json")
        self._build(apk, out)

        # 翻转第一个字节（保持长度不变，只破坏内容 → 只触发 sha256 不符）
        with open(apk, "r+b") as fp:
            original = fp.read(1)
            fp.seek(0)
            fp.write(bytes([original[0] ^ 0xFF]))

        code, output = quiet(release_manifest.main,
                             ["verify", "--manifest", out, "--apk", apk])
        self.assertEqual(code, 1, "篡改后必须返回 1")
        self.assertIn("[FAIL]", output)
        self.assertIn("sha256", output)

    def test_verify_fail_on_size_change(self):
        """追加字节后 size 也不符，verify 返回 1 并指出 size_bytes 不符。"""
        apk = self.make_fake_apk()
        out = self.path("dist", "latest.json")
        self._build(apk, out)

        with open(apk, "ab") as fp:
            fp.write(b"EXTRA")

        code, output = quiet(release_manifest.main,
                             ["verify", "--manifest", out, "--apk", apk])
        self.assertEqual(code, 1)
        self.assertIn("size_bytes", output)

    def test_verify_missing_manifest_returns_1(self):
        """清单不存在时 verify 返回 1。"""
        apk = self.make_fake_apk()
        code, _ = quiet(release_manifest.main,
                        ["verify", "--manifest", self.path("nope.json"), "--apk", apk])
        self.assertEqual(code, 1)


class TestReleaseManifestHistory(TempDirTestCase):

    def _build(self, apk, out, version_name, version_code):
        argv = [
            "build", "--apk", apk, "--version-name", version_name,
            "--version-code", str(version_code),
            "--repo", "https://github.com/owner/repo",
            "--tag", "v%s" % version_name,
            "--published-at", "2026-10-29T14:00:00Z",
            "--changelog", "版本 %s 的说明" % version_name,
            "--out", out,
        ]
        return quiet(release_manifest.main, argv)

    def test_history_accumulates_previous_latest(self):
        """连续生成两次：第二次的 history[0] 就是第一次的 latest。"""
        apk = self.make_fake_apk()
        out = self.path("dist", "latest.json")

        code1, _ = self._build(apk, out, "1.0.1", 2)
        self.assertEqual(code1, 0)
        with open(out, "r", encoding="utf-8") as fp:
            first = json.load(fp)

        code2, _ = self._build(apk, out, "1.0.2", 3)
        self.assertEqual(code2, 0)
        with open(out, "r", encoding="utf-8") as fp:
            second = json.load(fp)

        self.assertEqual(second["latest"]["version_name"], "1.0.2")
        self.assertEqual(len(second["history"]), 1)
        self.assertEqual(second["history"][0]["version_name"],
                         first["latest"]["version_name"])
        self.assertEqual(second["history"][0]["version_code"], 2)

    def test_history_capped_at_10(self):
        """连续生成 12 次，history 最多保留 10 条。"""
        apk = self.make_fake_apk()
        out = self.path("dist", "latest.json")

        for idx in range(12):
            code, _ = self._build(apk, out, "1.0.%d" % idx, idx + 1)
            self.assertEqual(code, 0)

        with open(out, "r", encoding="utf-8") as fp:
            manifest = json.load(fp)
        self.assertEqual(len(manifest["history"]), release_manifest.HISTORY_LIMIT)
        # 最新的一版应该排在最前
        self.assertEqual(manifest["history"][0]["version_name"], "1.0.10")


# ---------------------------------------------------------------------------
# send_release_email 测试
# ---------------------------------------------------------------------------

FAKE_PASSWORD = "super-secret-password-9f3a"


class MailTestCase(TempDirTestCase):
    """发信测试的公共脚手架：临时日志目录 + 假清单 + 干净环境变量。"""

    def setUp(self):
        super().setUp()
        self.log_dir = self.path("build", "logs")
        # 把模块级 LOG_DIR 指到临时目录，避免污染真实 build/logs
        patcher = mock.patch.object(send_release_email, "LOG_DIR", self.log_dir)
        patcher.start()
        self.addCleanup(patcher.stop)

        # 重试不真的睡
        sleep_patcher = mock.patch.object(send_release_email.time, "sleep")
        self.mock_sleep = sleep_patcher.start()
        self.addCleanup(sleep_patcher.stop)

        self.manifest = self.path("latest.json")
        self.write_manifest()

    def write_manifest(self, version_name="1.0.1", version_code=2,
                       size_bytes=1234, sha256="a" * 64, changelog=None):
        manifest = {
            "schema": 1,
            "game": "像素冒险",
            "package": "com.pixelstudio.pixeladventure",
            "latest": {
                "version_name": version_name,
                "version_code": version_code,
                "published_at": "2026-10-29T14:00:00Z",
                "size_bytes": size_bytes,
                "sha256": sha256,
                "min_supported_version_code": 1,
                "mandatory": False,
                "changelog": changelog if changelog is not None
                             else ["修复跳跃卡墙角", "新增 OTA 更新检查"],
                "download_url": ("https://github.com/owner/repo/releases/download/"
                                 "v%s/pixel-adventure.apk" % version_name),
                "release_page": ("https://github.com/owner/repo/releases/tag/v%s"
                                 % version_name),
            },
            "history": [],
        }
        with open(self.manifest, "w", encoding="utf-8") as fp:
            json.dump(manifest, fp, ensure_ascii=False, indent=2)
            fp.write("\n")
        return manifest

    def env(self, **overrides):
        """构造一份最小可用环境变量。"""
        env = {
            "OTA_SMTP_HOST": "smtp.example.com",
            "OTA_SMTP_PORT": "587",
            "OTA_SMTP_SECURITY": "starttls",
            "OTA_SMTP_USER": "sender@example.com",
            "OTA_SMTP_PASS": FAKE_PASSWORD,
            "OTA_SMTP_FROM": "sender@example.com",
            "OTA_SMTP_TO": "alice@example.com",
            "OTA_MAIL_MAX_ATTACHMENT_MB": "20",
        }
        env.update(overrides)
        return env

    def run_main(self, argv, env):
        """在指定环境变量下跑 main()，返回 (退出码, stdout, stderr)。"""
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, env, clear=True):
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = send_release_email.main(argv)
        return code, out.getvalue(), err.getvalue()

    def read_logs(self):
        """读出当天日志的所有记录。"""
        path = send_release_email.log_path_for_today()
        if not os.path.isfile(path):
            return []
        with open(path, "r", encoding="utf-8") as fp:
            return [json.loads(line) for line in fp if line.strip()]

    def log_text(self):
        path = send_release_email.log_path_for_today()
        if not os.path.isfile(path):
            return ""
        with open(path, "r", encoding="utf-8") as fp:
            return fp.read()


class TestSendReleaseEmailSuccess(MailTestCase):

    def test_success_sends_one_mail_and_logs_sent(self):
        """成功路径：发出 1 封、事件为 SENT。"""
        apk = self.make_fake_apk(payload=b"APK" * 10)

        with mock.patch("smtplib.SMTP") as mock_smtp:
            instance = mock_smtp.return_value
            code, out, err = self.run_main(
                ["--manifest", self.manifest, "--apk", apk, "--retries", "2"],
                self.env())

        self.assertEqual(code, 0, "成功应返回 0；stderr=%s" % err)
        self.assertEqual(mock_smtp.call_count, 1, "只应建立一次连接")
        self.assertEqual(instance.sendmail.call_count, 1, "只应发一封邮件")
        self.assertEqual(instance.login.call_count, 1, "有用户名时应登录一次")

        events = [rec["event"] for rec in self.read_logs()]
        self.assertIn(send_release_email.EV_SENT, events)

    def test_mail_body_contains_required_fields(self):
        """邮件正文必须含游戏名、版本号、更新时间、更新说明、下载链接、大小、SHA-256。"""
        apk = self.make_fake_apk(payload=b"APK" * 10)
        manifest = self.write_manifest(sha256="b" * 64, size_bytes=2048)

        with mock.patch("smtplib.SMTP") as mock_smtp:
            instance = mock_smtp.return_value
            code, _, _ = self.run_main(
                ["--manifest", self.manifest, "--apk", apk], self.env())

        self.assertEqual(code, 0)
        raw = instance.sendmail.call_args[0][2]
        msg = message_from_string(raw)
        bodies = []
        for part in msg.walk():
            if part.get_content_type() in ("text/plain", "text/html"):
                payload = part.get_payload(decode=True)
                bodies.append(payload.decode("utf-8"))
        joined = "\n".join(bodies)

        self.assertIn("像素冒险", joined)
        self.assertIn("1.0.1", joined)
        self.assertIn("2026-10-29T14:00:00Z", joined)
        self.assertIn("修复跳跃卡墙角", joined)
        self.assertIn(manifest["latest"]["download_url"], joined)
        self.assertIn("2.0 KB", joined)
        self.assertIn("b" * 64, joined)
        self.assertTrue(any(p.get_content_type() == "text/html" for p in msg.walk()),
                        "应有 HTML 版本正文")

    def test_no_attachment_flag_sends_link_only(self):
        """--no-attachment 时正文只有链接，没有附件。"""
        apk = self.make_fake_apk(payload=b"APK" * 10)

        with mock.patch("smtplib.SMTP") as mock_smtp:
            instance = mock_smtp.return_value
            code, _, _ = self.run_main(
                ["--manifest", self.manifest, "--apk", apk, "--no-attachment"],
                self.env())

        self.assertEqual(code, 0)
        msg = message_from_string(instance.sendmail.call_args[0][2])
        attachments = [p for p in msg.walk() if p.get_filename()]
        self.assertEqual(attachments, [], "不应有附件")


class TestSendReleaseEmailFailures(MailTestCase):

    def test_auth_failure_exits_2_and_does_not_retry(self):
        """认证失败：退出码 2，且只尝试 1 次（不重试）。"""
        apk = self.make_fake_apk()
        error = smtplib.SMTPAuthenticationError(535, b"5.7.8 auth failed")

        with mock.patch("smtplib.SMTP") as mock_smtp:
            instance = mock_smtp.return_value
            instance.login.side_effect = error
            code, _, err = self.run_main(
                ["--manifest", self.manifest, "--apk", apk, "--retries", "3"],
                self.env())

        self.assertEqual(code, send_release_email.EXIT_AUTH_FAILED)
        self.assertEqual(code, 2)
        self.assertEqual(mock_smtp.call_count, 1,
                         "认证失败只应尝试 1 次，实际 %d 次" % mock_smtp.call_count)
        self.assertEqual(instance.login.call_count, 1)
        self.assertEqual(instance.sendmail.call_count, 0, "认证失败不应发送")
        self.mock_sleep.assert_not_called()

        events = [rec["event"] for rec in self.read_logs()]
        self.assertIn(send_release_email.EV_AUTH_FAILED, events)

    def test_connect_failure_retries_then_exits_3(self):
        """连接失败：重试 --retries 次后退出码 3。"""
        apk = self.make_fake_apk()

        with mock.patch("smtplib.SMTP", side_effect=OSError("connection refused")) as mock_smtp:
            code, _, err = self.run_main(
                ["--manifest", self.manifest, "--apk", apk, "--retries", "2"],
                self.env())

        self.assertEqual(code, send_release_email.EXIT_SEND_FAILED)
        self.assertEqual(code, 3)
        # retries=2 表示首次 + 2 次重试 = 3 次尝试
        self.assertEqual(mock_smtp.call_count, 3,
                         "应尝试 3 次，实际 %d 次" % mock_smtp.call_count)
        self.assertEqual(self.mock_sleep.call_count, 2, "应退避等待 2 次")

        events = [rec["event"] for rec in self.read_logs()]
        self.assertIn(send_release_email.EV_CONNECT_FAILED, events)

    def test_send_failure_retries_then_exits_3(self):
        """发送阶段失败（收件人被拒）：重试后退出码 3。"""
        apk = self.make_fake_apk()
        refused = smtplib.SMTPRecipientsRefused(
            {"alice@example.com": (550, b"no such user")})

        with mock.patch("smtplib.SMTP") as mock_smtp:
            instance = mock_smtp.return_value
            instance.sendmail.side_effect = refused
            code, _, _ = self.run_main(
                ["--manifest", self.manifest, "--apk", apk, "--retries", "1"],
                self.env())

        self.assertEqual(code, 3)
        self.assertEqual(mock_smtp.call_count, 2, "retries=1 → 共 2 次尝试")

        events = [rec["event"] for rec in self.read_logs()]
        self.assertIn(send_release_email.EV_SEND_FAILED, events)

    def test_missing_config_exits_4(self):
        """缺少必填环境变量：退出码 4，不连 SMTP。"""
        apk = self.make_fake_apk()
        env = self.env()
        del env["OTA_SMTP_HOST"]

        with mock.patch("smtplib.SMTP") as mock_smtp:
            code, _, err = self.run_main(["--manifest", self.manifest, "--apk", apk], env)

        self.assertEqual(code, send_release_email.EXIT_CONFIG_ERROR)
        self.assertEqual(code, 4)
        mock_smtp.assert_not_called()
        self.assertIn("OTA_SMTP_HOST", err)

    def test_missing_manifest_exits_4(self):
        """清单不存在：退出码 4。"""
        apk = self.make_fake_apk()
        with mock.patch("smtplib.SMTP") as mock_smtp:
            code, _, _ = self.run_main(
                ["--manifest", self.path("nope.json"), "--apk", apk], self.env())
        self.assertEqual(code, 4)
        mock_smtp.assert_not_called()


class TestSendReleaseEmailAttachmentLimit(MailTestCase):

    def test_oversize_attachment_falls_back_to_link_only(self):
        """附件超限：不发送附件，正文含下载链接，日志记 ATTACHMENT_TOO_LARGE。"""
        # 1MB 的假 APK，把上限设成 0.001MB（约 1KB）→ 必然超限
        apk = self.make_fake_apk(payload=b"X" * (1024 * 1024))
        manifest = self.write_manifest()

        with mock.patch("smtplib.SMTP") as mock_smtp:
            instance = mock_smtp.return_value
            code, out, _ = self.run_main(
                ["--manifest", self.manifest, "--apk", apk],
                self.env(OTA_MAIL_MAX_ATTACHMENT_MB="0.001"))

        self.assertEqual(code, 0, "降级后仍算发送成功")
        self.assertEqual(instance.sendmail.call_count, 1)

        msg = message_from_string(instance.sendmail.call_args[0][2])
        attachments = [p for p in msg.walk() if p.get_filename()]
        self.assertEqual(attachments, [], "超限时不应带附件")

        bodies = []
        for part in msg.walk():
            if part.get_content_type() in ("text/plain", "text/html"):
                bodies.append(part.get_payload(decode=True).decode("utf-8"))
        joined = "\n".join(bodies)
        self.assertIn(manifest["latest"]["download_url"], joined,
                      "降级后正文必须包含下载链接")

        events = [rec["event"] for rec in self.read_logs()]
        self.assertIn(send_release_email.EV_ATTACHMENT_TOO_LARGE, events)


class TestSendReleaseEmailLogging(MailTestCase):

    def test_log_never_contains_password(self):
        """日志文件里绝不能出现 OTA_SMTP_PASS 的值。"""
        apk = self.make_fake_apk()
        error = smtplib.SMTPAuthenticationError(535, b"bad credentials")

        with mock.patch("smtplib.SMTP") as mock_smtp:
            mock_smtp.return_value.login.side_effect = error
            code, _, _ = self.run_main(
                ["--manifest", self.manifest, "--apk", apk], self.env())

        self.assertEqual(code, 2)
        text = self.log_text()
        self.assertTrue(text, "应写出日志")
        self.assertNotIn(FAKE_PASSWORD, text, "日志里出现了密码！")

    def test_log_masks_recipient_email(self):
        """日志里的收件人必须脱敏成 a***@example.com。"""
        apk = self.make_fake_apk()

        with mock.patch("smtplib.SMTP") as mock_smtp:
            code, _, _ = self.run_main(
                ["--manifest", self.manifest, "--apk", apk], self.env())
        self.assertEqual(code, 0)

        text = self.log_text()
        self.assertIn("a***@example.com", text, "应有脱敏后的收件人")
        self.assertNotIn("alice@example.com", text, "完整收件人邮箱不应出现在日志里")

    def test_log_is_json_lines_with_required_keys(self):
        """日志每行必须是 {"ts","event","detail"} 的 JSON。"""
        apk = self.make_fake_apk()
        with mock.patch("smtplib.SMTP"):
            self.run_main(["--manifest", self.manifest, "--apk", apk], self.env())

        records = self.read_logs()
        self.assertTrue(records)
        for rec in records:
            self.assertEqual(set(rec.keys()), {"ts", "event", "detail"})
            self.assertRegex(rec["ts"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_log_path_uses_mail_yyyymmdd_name(self):
        """日志文件名必须是 mail-YYYYMMDD.jsonl。"""
        path = send_release_email.log_path_for_today()
        name = os.path.basename(path)
        self.assertRegex(name, r"^mail-\d{8}\.jsonl$")

    def test_mask_email_helper(self):
        """mask_email 的边界：正常邮箱、无 @、空字符串。"""
        self.assertEqual(send_release_email.mask_email("alice@example.com"),
                         "a***@example.com")
        self.assertEqual(send_release_email.mask_email("bob@mail.cn"), "b***@mail.cn")
        self.assertEqual(send_release_email.mask_email("no-at-sign"), "***")
        self.assertEqual(send_release_email.mask_email(""), "***")


class TestSendReleaseEmailDryRun(MailTestCase):

    def test_dry_run_does_not_connect_or_write_log(self):
        """--dry-run 不连 SMTP、不写日志。"""
        apk = self.make_fake_apk()

        with mock.patch("smtplib.SMTP") as mock_smtp:
            code, out, _ = self.run_main(
                ["--manifest", self.manifest, "--apk", apk, "--dry-run"], self.env())

        self.assertEqual(code, 0)
        mock_smtp.assert_not_called()
        self.assertEqual(self.read_logs(), [], "dry-run 不应写日志")
        self.assertIn("[dry-run]", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
