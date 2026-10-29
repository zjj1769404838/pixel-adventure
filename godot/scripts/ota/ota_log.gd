class_name OtaLog
extends RefCounted
##
## OTA 过程日志：追加写 user://ota_log.jsonl，每行一条 JSON。
##
## 设计要点：
## - 不抛异常：磁盘不可写、文件损坏都只是静默返回（GDScript 无 try/except，
##   因此所有可能失败的操作都先判空再使用）；
## - 脱敏：键名含 pass/token/secret/key/auth 的值替换为 "***"；
##   值里若含 URL，'?' 之后的查询串（常带签名与令牌）被截断；
## - 容量上限 200 行，超出时只保留最后 200 行。
##

const LOG_PATH := "user://ota_log.jsonl"
const MAX_LINES := 200

## 敏感键名片段（大小写不敏感）
const SENSITIVE_KEYS := ["pass", "token", "secret", "key", "auth"]

## 写一条日志。
## detail 里的敏感值会被脱敏后再落盘。
static func write(event: String, detail: Dictionary = {}) -> void:
	var safe: Variant = _sanitize(detail)
	var row := {
		"ts": Time.get_datetime_string_from_system(true),
		"event": event,
		"detail": safe,
	}
	var line := JSON.stringify(row)
	# 文件不存在时以写模式新建；存在则以读写模式追加到末尾
	var f := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(LOG_PATH, FileAccess.WRITE)
		if f == null:
			return
		f.store_line(line)
		f.close()
		return
	f.seek_end()
	f.store_line(line)
	f.close()
	_trim()

## 读取最后 n 行（按写入顺序），坏行跳过。n <= 0 时返回空数组。
static func tail(n: int = 20) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if n <= 0:
		return out
	if not FileAccess.file_exists(LOG_PATH):
		return out
	var f := FileAccess.open(LOG_PATH, FileAccess.READ)
	if f == null:
		return out
	var lines: Array[String] = []
	while not f.eof_reached():
		var line := f.get_line()
		if line.strip_edges().is_empty():
			continue
		lines.append(line)
	f.close()
	var start: int = maxi(0, lines.size() - n)
	for i in range(start, lines.size()):
		var raw := lines[i].strip_edges()
		# 先做形状判断，避免坏行让引擎往控制台打 JSON 解析错误
		if not (raw.begins_with("{") and raw.ends_with("}")):
			continue
		var parsed: Variant = JSON.parse_string(raw)
		if parsed is Dictionary:
			out.append(parsed)
	return out
## 清空日志文件。
static func clear() -> void:
	var abs_path := ProjectSettings.globalize_path(LOG_PATH)
	if FileAccess.file_exists(LOG_PATH):
		DirAccess.remove_absolute(abs_path)
		return
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if f != null:
		f.close()

## 把字典逐层脱敏后返回副本
static func _sanitize(value: Variant) -> Variant:
	if value is Dictionary:
		var src: Dictionary = value
		var out := {}
		for k in src.keys():
			var key := str(k)
			if _is_sensitive_key(key):
				out[key] = "***"
			else:
				out[key] = _sanitize(src[k])
		return out
	if value is Array:
		var src_arr: Array = value
		var arr: Array = []
		for item in src_arr:
			arr.append(_sanitize(item))
		return arr
	if typeof(value) == TYPE_STRING:
		return _sanitize_string(str(value))
	return value

## 键名是否敏感（含 pass/token/secret/key/auth，忽略大小写）
static func _is_sensitive_key(key: String) -> bool:
	var lower := key.to_lower()
	for frag in SENSITIVE_KEYS:
		if lower.contains(frag):
			return true
	return false

## 字符串脱敏：URL 中 '?' 之后的内容截断
static func _sanitize_string(s: String) -> String:
	var q := s.find("?")
	if q == -1:
		return s
	# 只对看起来像 URL 的字符串做截断（含 ://）
	var head := s.substr(0, q)
	if not head.contains("://"):
		return s
	return head + "?***"

## 行数超限时裁剪，只保留最后 MAX_LINES 行
static func _trim() -> void:
	if not FileAccess.file_exists(LOG_PATH):
		return
	var f := FileAccess.open(LOG_PATH, FileAccess.READ)
	if f == null:
		return
	var lines: Array[String] = []
	while not f.eof_reached():
		var line := f.get_line()
		if line.strip_edges().is_empty():
			continue
		lines.append(line)
	f.close()
	if lines.size() <= MAX_LINES:
		return
	var keep: Array[String] = []
	for i in range(lines.size() - MAX_LINES, lines.size()):
		keep.append(lines[i])
	var w := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if w == null:
		return
	for l in keep:
		w.store_line(l)
	w.close()
