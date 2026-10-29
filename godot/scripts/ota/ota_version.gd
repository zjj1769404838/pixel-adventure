class_name OtaVersion
extends RefCounted
##
## OTA 版本号工具：解析、比较、可读体积格式化。
##
## 版本号形如 "1.2.3"，允许前后空格与 "v" / "V" 前缀。
## 段数不同时按缺失段补 0，因此 "1.2" == "1.2.0"。
## 任何非法输入都不会崩溃：parse 返回空数组、compare 返回 0，
## 并把原因写进静态字段 last_error 供调用方展示。
##

## 最近一次解析/比较失败的原因，空字符串表示上次操作成功。
static var last_error: String = ""

## 解析版本号，返回各段的整数数组；非法返回空数组。
## 例："1.2.3" -> [1, 2, 3]；"v2.0" -> [2, 0]；"abc" -> []
static func parse(v: String) -> Array[int]:
	last_error = ""
	var s := v.strip_edges()
	if s.is_empty():
		last_error = "版本号为空"
		return []
	# 容忍 "v" / "V" 前缀
	if s.begins_with("v") or s.begins_with("V"):
		s = s.substr(1).strip_edges()
	if s.is_empty():
		last_error = "版本号仅包含前缀，缺少数字"
		return []
	# allow_empty = true：让 "1..2" / "1." 之类被判定为非法而不是被静默吞掉
	var parts := s.split(".", true)
	var out: Array[int] = []
	for part in parts:
		var t := part.strip_edges()
		if t.is_empty():
			last_error = "版本号含有空段: " + v
			return []
		if not t.is_valid_int():
			last_error = "版本号含有非数字段: " + v
			return []
		out.append(int(t))
	if out.is_empty():
		last_error = "版本号无法解析: " + v
		return []
	return out

## 比较两个版本号：a > b 返回 1，a < b 返回 -1，相等返回 0。
## 任一方非法时返回 0，并在 last_error 中给出原因。
static func compare(a: String, b: String) -> int:
	last_error = ""
	var pa := parse(a)
	if pa.is_empty():
		# parse 失败时它已写入原因；这里兜底一个更完整的描述
		if last_error.is_empty():
			last_error = "无法比较版本号: " + a + " / " + b
		return 0
	var pb := parse(b)
	if pb.is_empty():
		if last_error.is_empty():
			last_error = "无法比较版本号: " + a + " / " + b
		return 0
	var n: int = maxi(pa.size(), pb.size())
	for i in n:
		var x: int = pa[i] if i < pa.size() else 0
		var y: int = pb[i] if i < pb.size() else 0
		if x > y:
			return 1
		if x < y:
			return -1
	return 0

## 远端版本是否比本地新。非法输入视为「不新」，不抛异常。
static func is_newer(remote: String, local: String) -> bool:
	return compare(remote, local) > 0

## 字节数转可读字符串。
## 例：30332907 -> "28.9 MB"；512 -> "512 B"
static func human_size(bytes: int) -> String:
	if bytes < 0:
		return "0 B"
	if bytes < 1024:
		return "%d B" % bytes
	var kb := float(bytes) / 1024.0
	if kb < 1024.0:
		return "%.1f KB" % kb
	var mb := kb / 1024.0
	if mb < 1024.0:
		return "%.1f MB" % mb
	return "%.1f GB" % (mb / 1024.0)

## 把 ISO-8601 时间串格式化成 "YYYY-MM-DD HH:MM"（UTC）。
## 解析失败时原样返回输入，绝不崩溃、绝不返回空串。
## 例："2026-10-29T14:00:00Z" -> "2026-10-29 14:00"
static func human_time(iso: String) -> String:
	var s := iso.strip_edges()
	if s.is_empty():
		return "未知"
	var idx := s.find("T")
	if idx <= 0:
		return s
	var date_part := s.substr(0, idx)
	var rest := s.substr(idx + 1)
	# 去掉时区后缀（Z / +08:00 / -05:00）
	for mark in ["Z", "z", "+", "-"]:
		var at := rest.find(mark)
		if at > 0:
			rest = rest.substr(0, at)
			break
	var bits := rest.split(":")
	if bits.size() < 2:
		return date_part
	var hh := bits[0].strip_edges()
	var mm := bits[1].strip_edges()
	if not hh.is_valid_int() or not mm.is_valid_int():
		return date_part
	return "%s %02d:%02d" % [date_part, int(hh), int(mm)]
