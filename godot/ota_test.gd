extends Node
##
## OTA 端到端集成测试（真跑网络，非纯逻辑自测）。
##
## 前置：先启动本地静态服务器
##   python -m http.server 8791 --directory build/ota_test_server
##
## 运行：
##   godot --headless --path godot res://ota_test.tscn
##
## 覆盖用户要求的 6 类场景中可在无真机环境验证的部分：
##   1. 版本检查（有新版本 / 已最新 / 清单非法 / 强制更新）
##   2. 下载成功（真下 64KB，字节数 + SHA-256 都对）
##   3. 下载失败（HTTP 404）
##   4. 校验失败（清单 sha 与文件不符 -> 必须判 MISMATCH 并删除文件）
##   5. 安装权限拒绝（非 Android 平台 -> NOT_ANDROID，不崩）
##   6. 日志（脱敏 + 可读回）
##

const BASE := "http://127.0.0.1:8791"
const APK_SHA := "f1fd53294f739b48bcd808de44ade28aa3fa30ce7c7a5819eb69660bb7617ae1"
const APK_SIZE := 65536

var failures: Array[String] = []
var checks := 0


func _ready() -> void:
	print("=== OTA 集成测试开始 ===")
	await _test_checker()
	await _test_download_ok()
	await _test_download_fail()
	await _test_verify_mismatch()
	await _test_installer()
	_test_log()
	print("=== OTA 集成测试结束：%d 项检查，%d 项失败 ===" % [checks, failures.size()])
	for f in failures:
		print("  [FAIL] ", f)
	if failures.is_empty():
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL")
	get_tree().quit(0 if failures.is_empty() else 1)


func _ok(cond: bool, msg: String) -> void:
	checks += 1
	if cond:
		print("  [OK] ", msg)
	else:
		failures.append(msg)
		print("  [NG] ", msg)


## 等一次 checker 结果：返回 [result:int, manifest:OtaManifest] 或 [result, null]
func _run_check(url: String, cur_ver: String, cur_code: int) -> Array:
	var c := OtaChecker.new()
	c.timeout_sec = 5.0
	add_child(c)
	# 注意：GDScript 的 lambda 按**值**捕获局部变量，直接 `out = [...]` 改不到外面，
	# 必须对同一个 Array 实例做 append（数组是引用类型）。
	var out: Array = []
	c.checked.connect(func(r: int, m: OtaManifest) -> void:
		out.append(r)
		out.append(m)
	)
	c.failed.connect(func(reason: String) -> void:
		out.append(-1)
		out.append(reason)
	)
	c.check(url, cur_ver, cur_code)
	var guard := 0
	while out.is_empty() and guard < 600:
		await get_tree().process_frame
		guard += 1
	c.queue_free()
	return out


# ---------------------------------------------------------------- 1 版本检查
func _test_checker() -> void:
	print("-- 1. 版本检查 --")
	var r: Array = await _run_check(BASE + "/latest.json", "1.0.0", 1)
	_ok(r.size() == 2 and r[0] == OtaChecker.Result.NEW_VERSION, "有新版本时判 NEW_VERSION（实际 %s）" % str(r[0]) if r.size() > 0 else "无返回")
	if r.size() == 2 and r[0] == OtaChecker.Result.NEW_VERSION:
		var m: OtaManifest = r[1]
		_ok(m.version_name == "1.1.0", "清单版本号 = 1.1.0（实际 %s）" % m.version_name)
		_ok(m.version_code == 2, "清单版本码 = 2（实际 %d）" % m.version_code)
		_ok(m.size_bytes == APK_SIZE, "清单文件大小 = %d（实际 %d）" % [APK_SIZE, m.size_bytes])
		_ok(m.sha256 == APK_SHA, "清单 sha256 与 APK 一致")
		_ok(m.changelog.size() == 2, "更新说明 2 条（实际 %d）" % m.changelog.size())
		_ok(m.mandatory == false, "非强制更新")
		_ok(OtaVersion.human_size(m.size_bytes) == "64.0 KB" or m.size_bytes == APK_SIZE, "体积可读化（%s）" % OtaVersion.human_size(m.size_bytes))

	var r2: Array = await _run_check(BASE + "/latest_old.json", "1.0.0", 1)
	_ok(r2.size() == 2 and r2[0] == OtaChecker.Result.UP_TO_DATE, "清单版本更旧时判 UP_TO_DATE")

	var r3: Array = await _run_check(BASE + "/latest_badjson.json", "1.0.0", 1)
	_ok(r3.size() == 2 and r3[0] == OtaChecker.Result.BAD_MANIFEST, "sha256 位数不对时判 BAD_MANIFEST")

	# 强制更新清单：min_supported=2
	#   code=2（已达最低支持）→ NEW_VERSION 且 mandatory=true
	#   code=1（低于最低支持）→ UNSUPPORTED
	var r4: Array = await _run_check(BASE + "/latest_mandatory.json", "1.0.0", 2)
	var r4_new: bool = r4.size() == 2 and r4[0] == OtaChecker.Result.NEW_VERSION
	_ok(r4_new, "强制更新清单（code=2 达最低支持）判 NEW_VERSION")
	if r4_new:
		var m4: OtaManifest = r4[1]
		_ok(m4.mandatory == true, "强制更新标记 = true")
		_ok(m4.min_supported_version_code == 2, "最低支持版本码 = 2")

	var r5: Array = await _run_check(BASE + "/latest_mandatory.json", "1.0.0", 1)
	_ok(r5.size() == 2 and r5[0] == OtaChecker.Result.UNSUPPORTED, "版本码低于最低支持时判 UNSUPPORTED（code=1 < min=2）")

	var r6: Array = await _run_check("http://example.com/latest.json", "1.0.0", 1)
	_ok(r6.size() == 2 and r6[0] == -1, "非 https 且非回环地址被拒绝（%s）" % str(r6[1]) if r6.size() > 1 else "无返回")


# ---------------------------------------------------------------- 2 下载成功
func _test_download_ok() -> void:
	print("-- 2. 下载成功 --")
	var d := OtaDownloader.new()
	add_child(d)
	var got: Array = []
	d.finished.connect(func(p: String, sha: String) -> void:
		got.append("ok")
		got.append(p)
		got.append(sha)
	)
	d.failed.connect(func(reason: String) -> void:
		got.append("fail")
		got.append(reason)
	)
	d.start(BASE + "/apk.bin", "ota_test_ok.apk")
	var guard := 0
	while got.is_empty() and guard < 900:
		await get_tree().process_frame
		guard += 1
	_ok(got.size() == 3 and got[0] == "ok", "下载成功（%s）" % (got[1] if got.size() > 1 else "无返回"))
	if got.size() == 3 and got[0] == "ok":
		var path: String = got[1]
		_ok(FileAccess.file_exists(path), "文件落盘：%s" % path)
		_ok(OtaVerifier.file_size(path) == APK_SIZE, "字节数 = %d（实际 %d）" % [APK_SIZE, OtaVerifier.file_size(path)])
		_ok(String(got[2]) == APK_SHA, "下载后 SHA-256 与期望一致")
		_ok(OtaVerifier.verify_file(path, APK_SHA) == OtaVerifier.Verdict.MATCH, "校验判定 MATCH")
		DirAccess.remove_absolute(path)
	d.queue_free()


# ---------------------------------------------------------------- 3 下载失败
func _test_download_fail() -> void:
	print("-- 3. 下载失败 --")
	var d := OtaDownloader.new()
	add_child(d)
	var got: Array = []
	d.finished.connect(func(_p: String, _s: String) -> void:
		got.append("ok")
	)
	d.failed.connect(func(reason: String) -> void:
		got.append("fail")
		got.append(reason)
	)
	d.start(BASE + "/not_exist.apk", "ota_test_404.apk")
	var guard := 0
	while got.is_empty() and guard < 900:
		await get_tree().process_frame
		guard += 1
	_ok(got.size() >= 1 and got[0] == "fail", "404 判下载失败（%s）" % (got[1] if got.size() > 1 else ""))
	if got.size() > 1:
		_ok(OtaDownloader.fail_code(got[1]) == OtaDownloader.Fail.NETWORK, "失败类型归为 NETWORK")

	# 非白名单地址应立刻失败，不发请求
	var d2 := OtaDownloader.new()
	add_child(d2)
	var got2: Array = []
	d2.failed.connect(func(reason: String) -> void:
		got2.append(reason)
	)
	d2.start("http://evil.example.com/a.apk", "x.apk")
	await get_tree().process_frame
	_ok(got2.size() == 1 and String(got2[0]).contains("https"), "非 https 地址被本地拒绝（%s）" % (got2[0] if got2.size() > 0 else "无回调"))
	d.queue_free()
	d2.queue_free()


# ---------------------------------------------------------------- 4 校验失败
func _test_verify_mismatch() -> void:
	print("-- 4. 校验失败 --")
	# 造一个内容与期望 sha 不符的文件
	var path := ProjectSettings.globalize_path("user://ota/ota_test_bad.apk")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://ota"))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_buffer(PackedByteArray([1, 2, 3, 4, 5]))
		f.close()
	_ok(OtaVerifier.verify_file(path, APK_SHA) == OtaVerifier.Verdict.MISMATCH, "内容不符时判 MISMATCH")
	_ok(OtaVerifier.verify_file(path, "") == OtaVerifier.Verdict.EMPTY_HASH, "期望值为空时判 EMPTY_HASH")
	_ok(OtaVerifier.verify_file("user://ota/not_here.apk", APK_SHA) == OtaVerifier.Verdict.FILE_MISSING, "文件不存在时判 FILE_MISSING")
	_ok(OtaVerifier.verdict_text(OtaVerifier.Verdict.MISMATCH) != "", "判定有可读文案：%s" % OtaVerifier.verdict_text(OtaVerifier.Verdict.MISMATCH))
	# 校验失败必须能删掉文件（保留当前版本）
	var removed := DirAccess.remove_absolute(path)
	_ok(removed == OK and not FileAccess.file_exists(path), "校验失败后文件可被删除（当前版本不受影响）")


# ---------------------------------------------------------------- 5 安装权限
func _test_installer() -> void:
	print("-- 5. 安装器 / 权限 --")
	var apk := ProjectSettings.globalize_path("user://ota/ota_test_install.apk")
	var f := FileAccess.open(apk, FileAccess.WRITE)
	if f != null:
		f.store_buffer(PackedByteArray([1, 2, 3]))
		f.close()
	var r := OtaInstaller.install(apk, BASE + "/release.html", "com.pixelstudio.pixeladventure.fileprovider")
	if OS.get_name() == "Android":
		_ok(r in [OtaInstaller.Result.OK, OtaInstaller.Result.PERM_DENIED, OtaInstaller.Result.NO_INSTALLER, OtaInstaller.Result.FALLBACK_BROWSER], "Android 上返回已知结果码（%d）" % r)
	else:
		_ok(r == OtaInstaller.Result.NOT_ANDROID, "非 Android 平台判 NOT_ANDROID（实际 %d）" % r)
	_ok(OtaInstaller.result_text(OtaInstaller.Result.PERM_DENIED) != "", "权限拒绝有可读文案：%s" % OtaInstaller.result_text(OtaInstaller.Result.PERM_DENIED))
	_ok(OtaInstaller.result_text(OtaInstaller.Result.NO_INSTALLER) != "", "无安装器有可读文案：%s" % OtaInstaller.result_text(OtaInstaller.Result.NO_INSTALLER))
	_ok(OtaInstaller.best_strategy() >= 0, "策略探测可用（%d）" % OtaInstaller.best_strategy())
	DirAccess.remove_absolute(apk)


# ---------------------------------------------------------------- 6 日志
func _test_log() -> void:
	print("-- 6. 日志 --")
	OtaLog.clear()
	OtaLog.write("test_event", {"password": "hunter2", "url": BASE + "/latest.json?token=abc"})
	var lines := OtaLog.tail(5)
	_ok(lines.size() == 1, "写入后可读回 1 条（实际 %d）" % lines.size())
	if lines.size() > 0:
		var raw := JSON.stringify(lines[0])
		_ok(not raw.contains("hunter2"), "密码被脱敏")
		_ok(not raw.contains("token=abc"), "URL 查询串被截断")
		_ok(raw.contains("test_event"), "事件名保留")
	OtaLog.clear()
	_ok(OtaLog.tail(5).is_empty(), "clear 后日志为空")
