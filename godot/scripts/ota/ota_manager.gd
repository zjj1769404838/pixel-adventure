class_name OtaManager
extends Node
##
## OTA 更新总控：把 检查 → 提示 → 下载 → 校验 → 安装 → 记录 串成一条状态机。
##
## 设计原则：
##   1. **绝不阻塞游戏**：检查与下载都是异步的；任何一步失败都只弹面板，不改游戏状态。
##   2. **失败保留当前版本**：只有 SHA-256 校验通过才会调用安装器；校验失败一律丢弃文件。
##   3. **一切可重试**：失败面板永远提供「重试」与「手动下载」两个出口。
##   4. **日志可排查**：每个状态迁移都写 OtaLog（自动脱敏，不含 URL 参数与凭据）。
##

enum State {
	IDLE,         ## 未开始
	CHECKING,     ## 正在拉清单
	AVAILABLE,    ## 有新版本，等用户决定
	DOWNLOADING,  ## 下载中
	VERIFYING,    ## 校验 SHA-256
	READY,        ## 校验通过，等用户确认安装
	INSTALLING,   ## 已拉起安装器
	FAILED        ## 某一步失败，可重试
}

var state: int = State.IDLE
var config: OtaConfig
var panel: OtaPanel

var _checker: OtaChecker
var _downloader: OtaDownloader
var _manifest: OtaManifest = null
var _apk_path := ""
var _last_error := ""

## 由 main.gd 注入：当 OTA 面板打开时暂停游戏逻辑
var on_busy_changed: Callable = Callable()


func setup(cfg: OtaConfig, p: OtaPanel) -> void:
	config = cfg
	panel = p

	_checker = OtaChecker.new()
	_checker.name = "OtaChecker"
	_checker.timeout_sec = cfg.timeout_sec
	add_child(_checker)
	_checker.checked.connect(_on_checked)
	_checker.failed.connect(_on_check_failed)

	_downloader = OtaDownloader.new()
	_downloader.name = "OtaDownloader"
	add_child(_downloader)
	_downloader.progress.connect(_on_download_progress)
	_downloader.finished.connect(_on_download_finished)
	_downloader.failed.connect(_on_download_failed)

	panel.action_taken.connect(_on_action)


## 界面是否占用了输入（main.gd 据此暂停游戏）
func is_busy() -> bool:
	return state in [State.CHECKING, State.AVAILABLE, State.DOWNLOADING, State.VERIFYING, State.READY, State.FAILED]


# ======================================================================
#  入口
# ======================================================================

## 静默检查（启动时调用）。没配置清单地址就直接跳过，不影响启动。
func check_silent() -> void:
	if config == null or not config.has_manifest_url():
		OtaLog.write("check_skipped", {"reason": "no_manifest_url"})
		return
	_begin_check()


## 手动检查（界面上的「检查更新」）
func check_manual() -> void:
	if config == null or not config.has_manifest_url():
		_set_failed("未配置更新地址", ["请在 ota_config.json 里填写 manifest_url"], ["知道了"])
		return
	_begin_check()


func _begin_check() -> void:
	if state == State.CHECKING or state == State.DOWNLOADING:
		return
	state = State.CHECKING
	_last_error = ""
	OtaLog.write("check_begin", {"current": OtaConfig.current_version()})
	_checker.check(config.manifest_url, OtaConfig.current_version(), OtaConfig.current_version_code())


# ======================================================================
#  检查回调
# ======================================================================

func _on_checked(result: int, m: OtaManifest) -> void:
	match result:
		OtaChecker.Result.NEW_VERSION:
			_manifest = m
			state = State.AVAILABLE
			OtaLog.write("check_new_version", {
				"remote": m.version_name,
				"local": OtaConfig.current_version(),
				"mandatory": m.mandatory,
			})
			panel.show_available(m)
			_emit_busy()
		OtaChecker.Result.UP_TO_DATE:
			state = State.IDLE
			OtaLog.write("check_up_to_date", {"local": OtaConfig.current_version()})
			if panel.is_open():
				panel.show_result("已是最新版本", ["当前版本 " + OtaConfig.current_version()], ["知道了"])
				_emit_busy()
		OtaChecker.Result.UNSUPPORTED:
			state = State.FAILED
			OtaLog.write("check_unsupported", {"min_code": m.min_supported_version_code})
			_set_failed("当前版本已停止支持", [
				"服务器要求最低版本码 " + str(m.min_supported_version_code),
				"请更新到 " + m.version_name + " 后继续游戏",
			], ["立即更新", "手动下载"])
		OtaChecker.Result.BAD_MANIFEST:
			state = State.FAILED
			_last_error = m.error if m != null else "清单格式错误"
			OtaLog.write("check_bad_manifest", {"reason": _last_error})
			_set_failed("版本清单不可用", [_last_error, "已保留当前版本，可稍后重试"], ["重试", "稍后提醒"])
		_:
			state = State.IDLE


func _on_check_failed(reason: String) -> void:
	state = State.FAILED
	_last_error = reason
	OtaLog.write("check_failed", {"reason": reason})
	# 静默检查失败不打扰用户；手动检查失败才弹面板
	if panel.is_open():
		_set_failed("检查更新失败", [reason, "已保留当前版本"], ["重试", "稍后提醒"])


# ======================================================================
#  下载 / 校验
# ======================================================================

func _start_download() -> void:
	if _manifest == null:
		return
	state = State.DOWNLOADING
	var fname := "pixel-adventure-%s.apk" % _manifest.version_name
	OtaLog.write("download_begin", {"version": _manifest.version_name, "size": _manifest.size_bytes})
	panel.show_progress(_manifest.version_name, 0, _manifest.size_bytes)
	_emit_busy()
	_downloader.start(_manifest.download_url, fname)


func _on_download_progress(received: int, total: int) -> void:
	if state == State.DOWNLOADING:
		panel.show_progress(_manifest.version_name if _manifest != null else "", received, total)


func _on_download_finished(abs_path: String, sha: String) -> void:
	_apk_path = abs_path
	state = State.VERIFYING
	panel.show_verifying()
	OtaLog.write("verify_begin", {"sha12": sha.substr(0, 12)})

	var verdict := OtaVerifier.verify_file(abs_path, _manifest.sha256 if _manifest != null else "")
	match verdict:
		OtaVerifier.Verdict.MATCH:
			state = State.READY
			OtaLog.write("verify_ok", {"sha12": sha.substr(0, 12)})
			panel.show_result("下载完成，校验通过", [
				"版本 " + (_manifest.version_name if _manifest != null else ""),
				"SHA-256 一致，可以安装",
				"安装时系统会询问「是否允许安装未知应用」",
			], ["立即安装", "稍后安装"], {"apk": abs_path})
		OtaVerifier.Verdict.MISMATCH:
			state = State.FAILED
			OtaLog.write("verify_mismatch", {"expected12": String(_manifest.sha256).substr(0, 12), "actual12": sha.substr(0, 12)})
			_discard_apk()
			_set_failed("安装包校验失败", [
				"SHA-256 与版本清单不一致，文件可能被篡改或下载不完整",
				"已删除该文件，当前版本未受影响",
			], ["重新下载", "手动下载"])
		OtaVerifier.Verdict.FILE_MISSING:
			state = State.FAILED
			OtaLog.write("verify_missing", {})
			_set_failed("安装包丢失", ["下载的文件已不存在"], ["重新下载", "手动下载"])
		_:
			state = State.FAILED
			OtaLog.write("verify_empty_hash", {})
			_set_failed("版本清单缺少校验值", ["无法验证安装包完整性，已取消安装"], ["手动下载", "稍后提醒"])
	_emit_busy()


func _on_download_failed(reason: String) -> void:
	state = State.FAILED
	_last_error = reason
	OtaLog.write("download_failed", {"reason": reason})
	_set_failed("下载失败", [reason, "已保留当前版本，可重试或手动下载"], ["重试", "手动下载"])


func _discard_apk() -> void:
	if _apk_path != "" and FileAccess.file_exists(_apk_path):
		DirAccess.remove_absolute(_apk_path)
	_apk_path = ""


# ======================================================================
#  安装
# ======================================================================

func _do_install() -> void:
	if _apk_path == "":
		_set_failed("安装包不存在", ["请重新下载"], ["重新下载", "手动下载"])
		return
	state = State.INSTALLING
	var fallback := _manifest.release_page if _manifest != null else ""
	var authority := config.install_authority if config != null else OtaConfig.DEFAULT_AUTHORITY
	var r := OtaInstaller.install(_apk_path, fallback, authority)
	OtaLog.write("install_result", {"code": r})
	_emit_busy()

	if r == OtaInstaller.Result.OK:
		panel.show_result("正在安装", [
			"请按系统提示完成安装",
			"安装完成后重新打开游戏即可使用新版本",
		], ["完成"])
	elif r == OtaInstaller.Result.FALLBACK_BROWSER:
		panel.show_result("已切换到手动安装", [
			"应用内安装不可用，已为你打开下载页面",
			"在浏览器里下载并安装后，重新打开游戏即可",
		], ["知道了", "手动下载"])
	elif r == OtaInstaller.Result.PERM_DENIED:
		panel.show_result("缺少安装权限", [
			OtaInstaller.result_text(r),
			"授权后回到这里点「立即安装」重试",
		], ["立即安装", "稍后安装"])
	else:
		panel.show_result("安装未完成", [
			OtaInstaller.result_text(r),
			"当前版本保持不变",
		], ["重试", "手动下载"])


# ======================================================================
#  按钮回调
# ======================================================================

func _on_action(action: String, ctx: Dictionary) -> void:
	OtaLog.write("ui_action", {"action": action, "state": state})
	match action:
		"update":
			_start_download()
		"retry":
			# 有清单就直接重下，没清单就重新检查
			if _manifest != null:
				_start_download()
			else:
				_begin_check()
		"manual":
			_manual_download()
		"cancel":
			if state == State.DOWNLOADING:
				_downloader.cancel()
			state = State.IDLE
			panel.close()
			_emit_busy()
		"later":
			state = State.IDLE
			panel.close()
			_emit_busy()
		"dismiss":
			state = State.IDLE
			panel.close()
			_emit_busy()
		"quit":
			OtaLog.write("user_quit", {})
			get_tree().quit()
		"install":
			# 「立即安装」按钮文案走 _key_for 映射不到，这里兜一层
			_do_install()
		_:
			panel.close()
			state = State.IDLE
			_emit_busy()


## 手动下载：打开 Release 页面（浏览器/系统下载器），不依赖应用内安装权限
func _manual_download() -> void:
	var url := ""
	if _manifest != null and _manifest.release_page != "":
		url = _manifest.release_page
	elif _manifest != null:
		url = _manifest.download_url
	if url == "":
		_set_failed("没有可用的下载地址", ["请检查 ota_config.json 的 manifest_url 配置"], ["知道了"])
		return
	var err := OS.shell_open(url)
	OtaLog.write("manual_download", {"ok": err == OK})
	if err == OK:
		panel.show_result("已打开下载页面", [
			"请在浏览器中下载并安装新版本",
			"安装后重新打开游戏即可",
		], ["知道了"])
	else:
		_set_failed("无法打开浏览器", ["请手动访问：" + url], ["知道了"])


# ======================================================================
#  工具
# ======================================================================

func _set_failed(headline: String, rows: Array, buttons: Array) -> void:
	state = State.FAILED
	panel.show_result(headline, rows, buttons)
	_emit_busy()


func _emit_busy() -> void:
	if on_busy_changed.is_valid():
		on_busy_changed.call(is_busy())
