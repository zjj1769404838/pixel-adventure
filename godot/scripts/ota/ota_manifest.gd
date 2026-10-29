class_name OtaManifest
extends RefCounted
##
## OTA 清单（dist/latest.json）的结构化表示与严格校验。
##
## 清单来自网络，属于安全边界：任何一项校验不通过就整体判为无效，
## 不做「部分填充」，避免上层拿到半可信的数据去做下载或安装。
##
## 期望的 JSON 结构：
## {
##   "latest": {
##     "game": "pixel-adventure",
##     "package": "com.pixelstudio.pixeladventure",
##     "version_name": "1.1.0",
##     "version_code": 2,
##     "published_at": "2026-10-29T12:00:00Z",
##     "size_bytes": 30332907,
##     "sha256": "<64 位小写十六进制>",
##     "min_supported_version_code": 1,
##     "mandatory": false,
##     "changelog": ["..."],
##     "download_url": "https://...",
##     "release_page": "https://..."
##   }
## }
##

var ok: bool = false
var error: String = ""
var game: String = ""
var package: String = ""
var version_name: String = ""
var version_code: int = 0
var published_at: String = ""
var size_bytes: int = 0
var sha256: String = ""
var min_supported_version_code: int = 0
var mandatory: bool = false
var changelog: Array[String] = []
var download_url: String = ""
var release_page: String = ""

const SHA256_CHARS := "0123456789abcdef"

## 下载地址是否允许。
## https 一律允许；http 仅允许本机回环地址（仅用于本地集成测试，
## 生产环境必须使用 https）；其余 http 一律拒绝。
static func is_allowed_download_url(url: String) -> bool:
	var u := url.strip_edges()
	if u.begins_with("https://"):
		return true
	# 仅用于本地回环测试（python -m http.server），生产必须 https
	if u.begins_with("http://127.0.0.1") or u.begins_with("http://localhost"):
		return true
	return false

## 把 JSON 值转成整数；非整数（或带小数的浮点）返回 -1 表示非法。
## JSON 里 2 解析为 int、2.0 解析为 float，两者都接受；字符串 "2" 不接受。
static func _to_int(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		return int(value)
	if typeof(value) == TYPE_FLOAT:
		var f := float(value)
		if is_equal_approx(f, round(f)):
			return int(round(f))
	return -1

## sha256 是否是 64 位小写十六进制
static func _is_sha256(s: String) -> bool:
	if s.length() != 64:
		return false
	for i in s.length():
		if not SHA256_CHARS.contains(s[i]):
			return false
	return true

## 把任意 Variant 转成文本。
## 注意：GDScript 的 String(value) 构造器对已经是 String 的值会报
## "Invalid call 'String' constructor"，所以这里按类型分派。
static func _variant_to_text(value: Variant) -> String:
	match typeof(value):
		TYPE_STRING:
			return String(value)
		TYPE_FLOAT:
			# 整数值的 float 不带小数尾巴（42.0 -> "42"）
			if is_equal_approx(value, round(value)):
				return str(int(round(value)))
			return str(value)
		TYPE_NIL:
			return ""
		_:
			return str(value)

## 解析并严格校验清单文本。永远返回对象，失败时 ok=false 且 error 非空。
static func from_json_text(text: String) -> OtaManifest:
	var m := OtaManifest.new()
	m.ok = false
	m.error = ""
	if text.strip_edges().is_empty():
		m.error = "清单内容为空"
		return m
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		m.error = "清单 JSON 解析失败: " + str(json.get_error_message())
		return m
	var parsed: Variant = json.data
	if not (parsed is Dictionary):
		m.error = "清单根节点必须是 JSON 对象"
		return m
	var root: Dictionary = parsed
	if not root.has("latest"):
		m.error = "清单缺少 latest 字段"
		return m
	if not (root["latest"] is Dictionary):
		m.error = "latest 字段必须是 JSON 对象"
		return m
	var latest: Dictionary = root["latest"]

	# ---- version_name ----
	if not latest.has("version_name"):
		m.error = "缺少 version_name"
		return m
	if not (latest["version_name"] is String):
		m.error = "version_name 必须是字符串"
		return m
	var vname: String = latest["version_name"]
	if vname.strip_edges().is_empty():
		m.error = "version_name 不能为空"
		return m

	# ---- version_code ----
	if not latest.has("version_code"):
		m.error = "缺少 version_code"
		return m
	var vcode := _to_int(latest["version_code"])
	if vcode <= 0:
		m.error = "version_code 必须是大于 0 的整数"
		return m

	# ---- sha256 ----
	if not latest.has("sha256"):
		m.error = "缺少 sha256"
		return m
	if not (latest["sha256"] is String):
		m.error = "sha256 必须是字符串"
		return m
	var sha: String = latest["sha256"]
	if not _is_sha256(sha):
		m.error = "sha256 必须是 64 位小写十六进制"
		return m

	# ---- size_bytes ----
	if not latest.has("size_bytes"):
		m.error = "缺少 size_bytes"
		return m
	var size := _to_int(latest["size_bytes"])
	if size <= 0:
		m.error = "size_bytes 必须是大于 0 的整数"
		return m

	# ---- download_url ----
	if not latest.has("download_url"):
		m.error = "缺少 download_url"
		return m
	if not (latest["download_url"] is String):
		m.error = "download_url 必须是字符串"
		return m
	var url: String = latest["download_url"]
	if not is_allowed_download_url(url):
		m.error = "下载地址必须使用 https"
		return m

	# ---- 可选字段（缺失时取默认值，类型非法才报错） ----
	var game_name := ""
	if latest.has("game"):
		if not (latest["game"] is String):
			m.error = "game 必须是字符串"
			return m
		game_name = latest["game"]
	var pkg := ""
	if latest.has("package"):
		if not (latest["package"] is String):
			m.error = "package 必须是字符串"
			return m
		pkg = latest["package"]
	var published := ""
	if latest.has("published_at"):
		if not (latest["published_at"] is String):
			m.error = "published_at 必须是字符串"
			return m
		published = latest["published_at"]
	var min_code := 0
	if latest.has("min_supported_version_code"):
		min_code = _to_int(latest["min_supported_version_code"])
		if min_code < 0:
			m.error = "min_supported_version_code 必须是整数"
			return m
	var is_mandatory := false
	if latest.has("mandatory"):
		if typeof(latest["mandatory"]) != TYPE_BOOL:
			m.error = "mandatory 必须是布尔值"
			return m
		is_mandatory = latest["mandatory"]
	var notes: Array[String] = []
	if latest.has("changelog"):
		if not (latest["changelog"] is Array):
			m.error = "changelog 必须是数组"
			return m
		for item in latest["changelog"]:
			# str() 兼容任意 Variant（String()/str() 对已是 String 的值会报构造错）
			notes.append(_variant_to_text(item))
	var release := ""
	if latest.has("release_page"):
		if not (latest["release_page"] is String):
			m.error = "release_page 必须是字符串"
			return m
		release = latest["release_page"]

	# 全部校验通过，一次性填充
	m.game = game_name
	m.package = pkg
	m.version_name = vname
	m.version_code = vcode
	m.published_at = published
	m.size_bytes = size
	m.sha256 = sha
	m.min_supported_version_code = min_code
	m.mandatory = is_mandatory
	m.changelog = notes
	m.download_url = url
	m.release_page = release
	m.ok = true
	m.error = ""
	return m

## 便于 UI 展示的一行摘要
func summary() -> String:
	if not ok:
		return "清单无效: " + error
	return "%s (code %d, %s)" % [version_name, version_code, OtaVersion.human_size(size_bytes)]
