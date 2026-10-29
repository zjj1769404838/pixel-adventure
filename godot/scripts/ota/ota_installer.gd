class_name OtaInstaller
extends RefCounted
##
## APK 安装触发层。
##
## 为什么不是一个 OS.execute 就完事：
##   Android 7(API 24) 起禁止把 file:// URI 交给别的应用（FileUriExposedException），
##   安装 APK 必须走 FileProvider 的 content:// URI，而这需要在 Android 端有 Java 代码
##   （自定义 Android 构建模板 / Godot Android 插件）。
##
## 因此这里做**策略链**，按可用性依次降级，每一步都返回明确的结果码，
## 让界面能告诉用户「现在卡在哪一步、下一步该干什么」，而不是静默失败：
##
##   PLUGIN      有 OtaInstaller 单例（自建 Android 插件）→ 直接拉起系统安装器
##   AM_INTENT   用 am start 发 VIEW intent（部分 ROM 可用，best-effort）
##   BROWSER     打开 Release 页面，用户在浏览器里手动下载安装（永远可用的兜底）
##
## 结果码写进日志，**不含任何敏感信息**（只有策略名与结果码）。
##

enum Result {
	OK,              ## 已成功拉起安装流程
	NO_FILE,         ## 本地 APK 不存在
	NOT_ANDROID,     ## 非 Android 平台（桌面/Web），只提示不安装
	NO_INSTALLER,    ## 系统没有可用的包安装器
	PERM_DENIED,     ## 缺少「安装未知应用」权限
	USER_CANCELLED,  ## 用户取消（由界面回传）
	FALLBACK_BROWSER ## 已降级为浏览器手动安装
}

enum Strategy { PLUGIN, AM_INTENT, BROWSER, NONE }

## 插件单例名（自建插件时用这个名字注册）
const PLUGIN_NAME := "OtaInstaller"


static func is_android() -> bool:
	return OS.get_name() == "Android"


## 探测当前环境能用的最高优先级策略（不执行安装，只判断）
static func best_strategy() -> int:
	if Engine.has_singleton(PLUGIN_NAME):
		return Strategy.PLUGIN
	if is_android():
		return Strategy.AM_INTENT
	return Strategy.BROWSER


## 触发安装。
## abs_apk_path: 本地 APK 绝对路径（user:// 下的文件已由 OtaDownloader 转成绝对路径）
## fallback_url: 降级时打开的页面（Release 页或 APK 直链）
## authority:    FileProvider authority，只在插件路径里用到
static func install(abs_apk_path: String, fallback_url: String, authority: String = OtaConfig.DEFAULT_AUTHORITY) -> int:
	if abs_apk_path == "" or not FileAccess.file_exists(abs_apk_path):
		OtaLog.write("install_failed", {"reason": "file_missing"})
		return Result.NO_FILE

	var strat := best_strategy()
	match strat:
		Strategy.PLUGIN:
			var r := _install_via_plugin(abs_apk_path, authority)
			if r == Result.OK:
				return Result.OK
			OtaLog.write("install_fallback", {"from": "plugin", "to": "am_intent"})
			var r2 := _install_via_am(abs_apk_path)
			if r2 == Result.OK:
				return Result.OK
			return _install_via_browser(fallback_url)
		Strategy.AM_INTENT:
			var r3 := _install_via_am(abs_apk_path)
			if r3 == Result.OK:
				return Result.OK
			return _install_via_browser(fallback_url)
		_:
			if is_android():
				return _install_via_browser(fallback_url)
			# 桌面平台：没有「安装」概念，打开文件所在目录即可
			OtaLog.write("install_skipped", {"platform": OS.get_name()})
			return Result.NOT_ANDROID


## ---- 策略 1：Android 插件（需要自建 gradle 模板，见 docs/OTA.md） ----
static func _install_via_plugin(abs_apk_path: String, authority: String) -> int:
	if not Engine.has_singleton(PLUGIN_NAME):
		return Result.NO_INSTALLER
	var plugin: Object = Engine.get_singleton(PLUGIN_NAME)
	if plugin == null or not plugin.has_method("installApk"):
		return Result.NO_INSTALLER
	var ret: Variant = plugin.call("installApk", abs_apk_path, authority)
	# 插件约定返回 int：0 成功 / 1 无安装器 / 2 缺未知来源权限 / 3 用户取消
	match int(ret):
		0:
			OtaLog.write("install_ok", {"strategy": "plugin"})
			return Result.OK
		1:
			OtaLog.write("install_failed", {"strategy": "plugin", "reason": "no_installer"})
			return Result.NO_INSTALLER
		2:
			OtaLog.write("install_failed", {"strategy": "plugin", "reason": "perm_denied"})
			return Result.PERM_DENIED
		3:
			OtaLog.write("install_failed", {"strategy": "plugin", "reason": "user_cancelled"})
			return Result.USER_CANCELLED
		_:
			return Result.NO_INSTALLER


## ---- 策略 2：am start 发 VIEW intent（best-effort，无 FileProvider 时多数 ROM 会拒绝） ----
static func _install_via_am(abs_apk_path: String) -> int:
	if not is_android():
		return Result.NO_INSTALLER
	var args := PackedStringArray([
		"start",
		"-a", "android.intent.action.VIEW",
		"-d", "file://" + abs_apk_path,
		"-t", "application/vnd.android.package-archive",
		"-f", "0x10000001",   # FLAG_GRANT_READ_URI_PERMISSION | FLAG_ACTIVITY_NEW_TASK
	])
	# Godot 4 的 OS.execute 返回 int 退出码，输出写进出参数组
	var out: Array = []
	var code := OS.execute("am", args, out, true)
	var text := ""
	for line in out:
		text += String(line)
	# am 失败时通常 exit_code != 0，或输出里带 Error / Exception
	if code == 0 and not text.contains("Error") and not text.contains("Exception"):
		OtaLog.write("install_ok", {"strategy": "am_intent"})
		return Result.OK
	OtaLog.write("install_failed", {"strategy": "am_intent", "exit_code": code})
	# 输出里出现 SecurityException / FileUriExposed 说明是权限或 URI 暴露限制
	if text.contains("SecurityException") or text.contains("FileUriExposed") or text.contains("Permission"):
		return Result.PERM_DENIED
	return Result.NO_INSTALLER


## ---- 策略 3：打开浏览器/文件管理器，让用户手动下载安装（兜底，永远可用） ----
static func _install_via_browser(fallback_url: String) -> int:
	if fallback_url == "":
		OtaLog.write("install_failed", {"strategy": "browser", "reason": "no_fallback_url"})
		return Result.NO_INSTALLER
	var err := OS.shell_open(fallback_url)
	if err == OK:
		OtaLog.write("install_fallback_browser", {"ok": true})
		return Result.FALLBACK_BROWSER
	OtaLog.write("install_failed", {"strategy": "browser", "reason": "shell_open_failed"})
	return Result.NO_INSTALLER


## 打开系统的「安装未知应用」授权页（需要插件支持）。
## Android 8.0 起安装 APK 必须由用户给本应用授权，否则 startActivity 会被系统拦。
## 返回 true 表示已成功拉起授权页。
static func open_permission_settings() -> bool:
	if not Engine.has_singleton(PLUGIN_NAME):
		return false
	var plugin: Object = Engine.get_singleton(PLUGIN_NAME)
	if plugin == null or not plugin.has_method("openInstallPermissionSettings"):
		return false
	var ret: Variant = plugin.call("openInstallPermissionSettings")
	OtaLog.write("permission_settings_opened", {"ok": int(ret) == 0})
	return int(ret) == 0


## 给界面用的人类可读文案
static func result_text(code: int) -> String:
	match code:
		Result.OK:
			return "已打开系统安装器，请按提示完成安装"
		Result.NO_FILE:
			return "安装包不存在，请重新下载"
		Result.NOT_ANDROID:
			return "当前平台不支持应用内安装，已为你打开文件位置"
		Result.NO_INSTALLER:
			return "未找到可用的安装器，已改为手动下载"
		Result.PERM_DENIED:
			return "缺少安装权限：请到 设置 → 应用 → 特殊权限 → 安装未知应用 中允许本应用"
		Result.USER_CANCELLED:
			return "已取消安装，当前版本保持不变"
		Result.FALLBACK_BROWSER:
			return "已打开下载页面，请在浏览器中完成安装"
		_:
			return "安装未完成"
