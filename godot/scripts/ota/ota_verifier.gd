class_name OtaVerifier
extends RefCounted
##
## OTA 下载包校验：比对本地文件的 SHA-256 与清单声明值。
##
## 实现说明：Godot 4.7 的 FileAccess 提供静态方法
## `FileAccess.get_sha256(path)`（见引擎文档 FileAccess.xml，qualifiers="static"），
## 因此直接使用它，无需自行分块用 HashingContext 计算。
## 该方法要求传入**绝对路径**（res:// 与 user:// 也接受绝对化后的形式）。
##

enum Verdict {
	MATCH,        # 哈希一致
	MISMATCH,     # 文件存在但哈希不符
	FILE_MISSING, # 文件不存在或无法打开
	EMPTY_HASH,   # 期望哈希为空，无法比对
}

## 校验本地文件。
## expected_sha256 允许大小写混写与首尾空格；为空返回 EMPTY_HASH。
static func verify_file(abs_path: String, expected_sha256: String) -> int:
	var want := expected_sha256.strip_edges().to_lower()
	if want.is_empty():
		return Verdict.EMPTY_HASH
	if abs_path.strip_edges().is_empty():
		return Verdict.FILE_MISSING
	if not FileAccess.file_exists(abs_path):
		return Verdict.FILE_MISSING
	var got := file_sha256(abs_path)
	if got.is_empty():
		return Verdict.FILE_MISSING
	if got == want:
		return Verdict.MATCH
	return Verdict.MISMATCH

## 计算文件 SHA-256（小写十六进制）；失败返回 ""。
static func file_sha256(abs_path: String) -> String:
	if abs_path.strip_edges().is_empty():
		return ""
	if not FileAccess.file_exists(abs_path):
		return ""
	var sha := FileAccess.get_sha256(abs_path)
	if sha.is_empty():
		return ""
	return str(sha).to_lower()

## 文件字节数；不存在返回 0。
static func file_size(abs_path: String) -> int:
	if abs_path.strip_edges().is_empty():
		return 0
	if not FileAccess.file_exists(abs_path):
		return 0
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return 0
	var size := f.get_length()
	f.close()
	return size

## 判定结果的可读文案
static func verdict_text(v: int) -> String:
	match v:
		Verdict.MATCH:
			return "校验通过"
		Verdict.MISMATCH:
			return "校验失败：哈希不匹配"
		Verdict.FILE_MISSING:
			return "校验失败：文件不存在"
		Verdict.EMPTY_HASH:
			return "校验失败：期望哈希为空"
		_:
			return "校验失败：未知结果"
