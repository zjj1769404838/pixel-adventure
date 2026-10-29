class_name OtaConfig
extends RefCounted
##
## OTA 配置加载器。
##
## 配置分两层，后者覆盖前者：
##   1. res://ota_config.json    —— 随包发布的默认配置（可进仓库，**不含任何凭据**）
##   2. user://ota_config.json   —— 本机覆盖配置（用户/运维手工放，不进仓库）
##
## 本文件刻意不读取任何 SMTP 凭据：邮件发送完全在发布侧用环境变量完成
## （见 scripts/send_release_email.py），APK 里永不携带邮箱账号密码。
##

## 默认值（配置文件缺失或缺字段时兜底）
const DEFAULT_MANIFEST_URL := ""
const DEFAULT_AUTHORITY := "com.pixelstudio.pixeladventure.fileprovider"
const DEFAULT_TIMEOUT := 10.0

## 内置默认配置（res://ota_config.json 存在时以它为准）
var manifest_url: String = DEFAULT_MANIFEST_URL
var install_authority: String = DEFAULT_AUTHORITY
var check_on_start: bool = true
var timeout_sec: float = DEFAULT_TIMEOUT
var game_name: String = "像素冒险"
var package_name: String = "com.pixelstudio.pixeladventure"

## 加载来源，便于日志排查（"res+user" / "res" / "user" / "default"）
var source: String = "default"


## 读取配置。永不抛异常；坏 JSON 只记录 error 并回落默认值。
static func load_config() -> OtaConfig:
	var cfg := OtaConfig.new()
	var loaded: Array[String] = []

	var res_path := "res://ota_config.json"
	if FileAccess.file_exists(res_path):
		if cfg._apply_json(FileAccess.get_file_as_string(res_path), res_path):
			loaded.append("res")

	var user_path := "user://ota_config.json"
	if FileAccess.file_exists(user_path):
		if cfg._apply_json(FileAccess.get_file_as_string(user_path), user_path):
			loaded.append("user")

	cfg.source = "+".join(loaded) if loaded.size() > 0 else "default"
	return cfg


func _apply_json(text: String, where: String) -> bool:
	if text.strip_edges() == "":
		return false
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		OtaLog.write("config_bad", {"where": where, "reason": "not a json object"})
		return false
	var d: Dictionary = data as Dictionary

	if d.has("manifest_url"):
		manifest_url = String(d["manifest_url"]).strip_edges()
	if d.has("install_authority"):
		install_authority = String(d["install_authority"]).strip_edges()
	if d.has("check_on_start"):
		check_on_start = bool(d["check_on_start"])
	if d.has("timeout_sec"):
		timeout_sec = clampf(float(d["timeout_sec"]), 3.0, 60.0)
	if d.has("game_name"):
		game_name = String(d["game_name"])
	if d.has("package_name"):
		package_name = String(d["package_name"])
	return true


## 清单地址是否可用（空 = 未配置，OTA 静默跳过，不影响游戏启动）
func has_manifest_url() -> bool:
	return manifest_url != ""


## 本机当前版本号 / 版本码，取自 project.godot 的 Android 预设语义。
## Godot 运行期拿不到 export preset，因此版本号由发布脚本在导出前写进
## res://version.json（见 scripts/publish_release.py），这里只负责读。
static func current_version() -> String:
	var v := _read_version_file()
	var name_s: String = String(v.get("version_name", "1.0.0"))
	return name_s if name_s != "" else "1.0.0"


static func current_version_code() -> int:
	var v := _read_version_file()
	return int(v.get("version_code", 1))


static func _read_version_file() -> Dictionary:
	var path := "res://version.json"
	if not FileAccess.file_exists(path):
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	return data as Dictionary
