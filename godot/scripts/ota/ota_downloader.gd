class_name OtaDownloader
extends Node
##
## OTA 更新包下载：把 APK 下载到 user://ota/ 目录。
##
## 用法：
## var dl := OtaDownloader.new()
## add_child(dl)
## dl.progress.connect(_on_progress)
## dl.finished.connect(_on_finished)
## dl.failed.connect(_on_failed)
## dl.start("https://example.com/app.apk", "app.apk")
##
## 注意：HTTPRequest.download_file **必须给绝对路径**。
## 实测（Godot 4.7.2）：给相对路径 "ota/app.apk" 会被解析到**工程/可执行文件目录**
## （导出后是 exe 同级目录，Android 上不可写），返回 RESULT_CANT_OPEN(10)；
## 给 "user://ota/app.apk" 这类带协议前缀的路径同样不可靠。
## 唯一稳定做法：先 ProjectSettings.globalize_path() 得到绝对路径再赋给 download_file。
##

signal progress(received: int, total: int)
signal finished(path: String, sha256: String)
signal failed(reason: String)

enum Fail {
	NETWORK,  # 网络 / HTTP 错误
	DISK,     # 磁盘写入失败
	ABORTED,  # 被 cancel()
	EMPTY,    # 下载完成但文件为空
}

## 下载目录（user:// 路径）
var dest_dir: String = "user://ota"

var _http: HTTPRequest = null
var _running: bool = false
var _done: bool = false
var _rel_path: String = ""
var _abs_path: String = ""

func _ready() -> void:
	_ensure_http()

func _ensure_http() -> void:
	if _http == null:
		_http = HTTPRequest.new()
		_http.name = "OtaDownloaderHTTP"
		add_child(_http)
		_http.request_completed.connect(_on_request_completed)

## 开始下载。url 必须是 https 或本机回环地址。
func start(url: String, filename: String) -> void:
	_ensure_http()
	_done = false
	var u := url.strip_edges()
	if not _is_allowed_url(u):
		_running = false
		OtaLog.write("download_failed", {"reason": "下载地址必须使用 https", "url_host": _host_of(u)})
		failed.emit("下载地址必须使用 https")
		return
	var safe_name := filename.strip_edges()
	if safe_name.is_empty():
		safe_name = "update.apk"
	# 去掉路径分隔符，防止写到 dest_dir 之外
	safe_name = safe_name.replace("\\", "/").get_file()
	if safe_name.is_empty():
		_running = false
		OtaLog.write("download_failed", {"reason": "文件名非法", "url_host": _host_of(u)})
		failed.emit("文件名非法")
		return

	if not _ensure_dir():
		_running = false
		OtaLog.write("download_failed", {"reason": "无法创建下载目录", "dir": dest_dir})
		failed.emit("无法创建下载目录")
		return

	# download_file 必须用绝对路径，否则会落到可执行文件目录（见文件头注释）
	var dir_abs := ProjectSettings.globalize_path(dest_dir)
	_rel_path = dir_abs + "/" + safe_name
	_abs_path = _rel_path

	_running = true
	_http.download_file = _abs_path
	_http.timeout = 0.0
	var err := _http.request(u)
	if err != OK:
		_running = false
		var reason := "请求发起失败: %d" % err
		OtaLog.write("download_failed", {"reason": reason, "url_host": _host_of(u)})
		failed.emit(reason)
		return
	OtaLog.write("download_start", {"url_host": _host_of(u), "file": safe_name})

## 取消下载。会发一次 failed(ABORTED)。
func cancel() -> void:
	if not _running:
		return
	if _http != null:
		_http.cancel_request()
	_running = false
	if _done:
		return
	_done = true
	OtaLog.write("download_failed", {"reason": "已取消", "file": _rel_path})
	failed.emit("已取消下载")

## 是否正在下载
func is_running() -> bool:
	return _running

func _process(_delta: float) -> void:
	if not _running or _http == null:
		return
	progress.emit(_http.get_downloaded_bytes(), _http.get_body_size())

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_running = false
	if _done:
		return
	_done = true
	if result != HTTPRequest.RESULT_SUCCESS:
		var reason := "下载失败: %s" % _result_text(result)
		OtaLog.write("download_failed", {"reason": reason, "file": _rel_path})
		failed.emit(reason)
		return
	if response_code != 200:
		var reason := "下载失败: HTTP %d" % response_code
		OtaLog.write("download_failed", {"reason": reason, "file": _rel_path})
		failed.emit(reason)
		return

	if not FileAccess.file_exists(_abs_path):
		var reason := "下载失败: 文件未生成"
		OtaLog.write("download_failed", {"reason": reason, "file": _rel_path})
		failed.emit(reason)
		return
	var size := OtaVerifier.file_size(_abs_path)
	if size <= 0:
		OtaLog.write("download_failed", {"reason": "下载文件为空", "file": _rel_path})
		failed.emit("下载文件为空")
		return

	var sha := OtaVerifier.file_sha256(_abs_path)
	OtaLog.write("download_done", {
		"file": _rel_path,
		"size": size,
		"sha256": sha.substr(0, 12),
	})
	finished.emit(_abs_path, sha)

## 创建下载目录（user:// 相对路径），成功返回 true
func _ensure_dir() -> bool:
	var rel := _strip_user_prefix(dest_dir)
	if rel.is_empty():
		rel = "ota"
	var abs := ProjectSettings.globalize_path("user://" + rel)
	if DirAccess.dir_exists_absolute(abs):
		return true
	return DirAccess.make_dir_recursive_absolute(abs) == OK

## 去掉 "user://" 前缀，得到相对 user:// 的路径
static func _strip_user_prefix(path: String) -> String:
	var p := path.strip_edges()
	if p.begins_with("user://"):
		p = p.substr(7)
	while p.begins_with("/"):
		p = p.substr(1)
	while p.ends_with("/"):
		p = p.substr(0, p.length() - 1)
	return p

## 失败原因字符串 -> Fail 枚举，便于上层按类型分支处理
static func fail_code(reason: String) -> int:
	if reason.contains("取消"):
		return Fail.ABORTED
	if reason.contains("为空"):
		return Fail.EMPTY
	if reason.contains("文件") or reason.contains("目录") or reason.contains("写入"):
		return Fail.DISK
	return Fail.NETWORK

## https 或本机回环（仅本地集成测试用，生产必须 https）
static func _is_allowed_url(url: String) -> bool:
	if url.begins_with("https://"):
		return true
	if url.begins_with("http://127.0.0.1") or url.begins_with("http://localhost"):
		return true
	return false

## 只保留 host 写日志，避免泄露查询串
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
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN:
			return "无法写入下载文件"
		HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR:
			return "写入下载文件出错"
		HTTPRequest.RESULT_TIMEOUT:
			return "超时"
		_:
			return "错误码 %d" % result
