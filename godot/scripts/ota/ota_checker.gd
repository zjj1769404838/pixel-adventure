class_name OtaChecker
extends Node
##
## OTA 更新检查：拉取远端清单并判定当前版本是否需要更新。
##
## 用法：
## var checker := OtaChecker.new()
## add_child(checker)
## checker.checked.connect(_on_checked)
## checker.failed.connect(_on_failed)
## checker.check("https://example.com/dist/latest.json", "1.0.0", 1)
##
## 判定顺序：
## 1. 清单地址非法        -> failed("清单地址必须使用 https")
## 2. HTTP 非 200         -> failed("HTTP %d")
## 3. JSON / 字段校验失败 -> checked(BAD_MANIFEST, manifest)
## 4. 远端最低版本高于本地 -> checked(UNSUPPORTED, manifest)
## 5. 远端更新            -> checked(NEW_VERSION, manifest)
## 6. 否则                -> checked(UP_TO_DATE, manifest)
##

signal checked(result: int, manifest: OtaManifest)
signal failed(reason: String)

enum Result {
	NEW_VERSION,  # 有新版本
	UP_TO_DATE,   # 已是最新
	UNSUPPORTED,  # 本地版本太低，无法升级到该版本
	BAD_MANIFEST, # 清单非法
}

## 清单请求超时（秒）
var timeout_sec: float = 10.0

var _http: HTTPRequest = null
var _busy: bool = false
var _local_version: String = ""
var _local_version_code: int = 0

func _ready() -> void:
	_ensure_http()

func _ensure_http() -> void:
	if _http == null:
		_http = HTTPRequest.new()
		_http.name = "OtaCheckerHTTP"
		add_child(_http)
		_http.request_completed.connect(_on_request_completed)
	_http.timeout = timeout_sec

## 开始一次检查。不会阻塞，结果通过 checked / failed 信号返回。
func check(manifest_url: String, current_version: String, current_version_code: int) -> void:
	_ensure_http()
	_local_version = current_version
	_local_version_code = current_version_code
	_busy = true

	var url := manifest_url.strip_edges()
	if not _is_allowed_url(url):
		_busy = false
		OtaLog.write("check_failed", {"reason": "清单地址必须使用 https", "url_host": _host_of(url)})
		failed.emit("清单地址必须使用 https")
		return

	_http.timeout = timeout_sec
	var err := _http.request(url)
	if err != OK:
		_busy = false
		var reason := "请求发起失败: %d" % err
		OtaLog.write("check_failed", {"reason": reason, "url_host": _host_of(url)})
		failed.emit(reason)
		return
	OtaLog.write("check_start", {
		"url_host": _host_of(url),
		"current_version": current_version,
		"current_version_code": current_version_code,
	})

## 中断进行中的检查。
func abort() -> void:
	if _http != null:
		_http.cancel_request()
	_busy = false

## 是否正在检查
func is_busy() -> bool:
	return _busy

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	if result != HTTPRequest.RESULT_SUCCESS:
		var reason := "请求失败: %s" % _result_text(result)
		OtaLog.write("check_failed", {"reason": reason, "result": result})
		failed.emit(reason)
		return
	if response_code != 200:
		var reason := "HTTP %d" % response_code
		OtaLog.write("check_failed", {"reason": reason, "response_code": response_code})
		failed.emit(reason)
		return

	var text := body.get_string_from_utf8()
	var m := OtaManifest.from_json_text(text)
	if not m.ok:
		OtaLog.write("check_failed", {"reason": "清单校验失败: " + m.error})
		checked.emit(Result.BAD_MANIFEST, m)
		return

	# 本地版本太低：远端要求的最低版本高于当前版本
	if m.min_supported_version_code > _local_version_code:
		OtaLog.write("check_result", {
			"result": "UNSUPPORTED",
			"version_name": m.version_name,
			"version_code": m.version_code,
			"min_supported_version_code": m.min_supported_version_code,
			"current_version_code": _local_version_code,
		})
		checked.emit(Result.UNSUPPORTED, m)
		return

	if OtaVersion.is_newer(m.version_name, _local_version):
		OtaLog.write("check_result", {
			"result": "NEW_VERSION",
			"version_name": m.version_name,
			"version_code": m.version_code,
			"current_version": _local_version,
		})
		checked.emit(Result.NEW_VERSION, m)
		return

	OtaLog.write("check_result", {
		"result": "UP_TO_DATE",
		"version_name": m.version_name,
		"current_version": _local_version,
	})
	checked.emit(Result.UP_TO_DATE, m)

## 清单地址白名单：https 或本机回环（仅本地集成测试用，生产必须 https）
static func _is_allowed_url(url: String) -> bool:
	if url.begins_with("https://"):
		return true
	if url.begins_with("http://127.0.0.1") or url.begins_with("http://localhost"):
		return true
	return false

## 只保留 host，避免把带令牌的查询串写进日志
static func _host_of(url: String) -> String:
	var s := url.strip_edges()
	var scheme_end := s.find("://")
	if scheme_end == -1:
		return ""
	var rest := s.substr(scheme_end + 3)
	var cut := rest.find("/")
	var hostpart := rest if cut == -1 else rest.substr(0, cut)
	var q := hostpart.find("?")
	if q != -1:
		hostpart = hostpart.substr(0, q)
	return hostpart

static func _result_text(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "无法连接"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "域名解析失败"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "连接错误"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS 握手失败"
		HTTPRequest.RESULT_NO_RESPONSE:
			return "无响应"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "响应体超限"
		HTTPRequest.RESULT_BODY_DECOMPRESS_FAILED:
			return "解压失败"
		HTTPRequest.RESULT_REQUEST_FAILED:
			return "请求失败"
		HTTPRequest.RESULT_TIMEOUT:
			return "超时"
		_:
			return "错误码 %d" % result
