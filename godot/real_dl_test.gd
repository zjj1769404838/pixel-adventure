extends Node
## 真实 29MB APK 的端到端下载 + SHA-256 校验演练（跑完可删）
const MANIFEST := "http://127.0.0.1:8792/build/ota_test_server/latest_real.json"

func _ready() -> void:
	print("=== 真实 APK 下载演练开始 ===")
	var c := OtaChecker.new()
	c.timeout_sec = 10.0
	add_child(c)
	var out: Array = []
	c.checked.connect(func(r: int, m: OtaManifest) -> void:
		out.append(r); out.append(m))
	c.failed.connect(func(reason: String) -> void:
		out.append(-1); out.append(reason))
	c.check(MANIFEST, "1.0.0", 1)
	var g := 0
	while out.is_empty() and g < 600:
		await get_tree().process_frame
		g += 1
	if out.is_empty() or out[0] != OtaChecker.Result.NEW_VERSION:
		print("RESULT: FAIL 版本检查异常 -> ", out)
		get_tree().quit(1); return
	var m: OtaManifest = out[1]
	print("  版本 %s (code %d)  大小 %d  说明 %d 条" % [m.version_name, m.version_code, m.size_bytes, m.changelog.size()])
	print("  下载地址 ", m.download_url)

	var d := OtaDownloader.new()
	add_child(d)
	var dl: Array = []
	var last_pct := -1
	d.progress.connect(func(recv: int, total: int) -> void:
		var pct := int(recv * 100 / maxi(total, 1))
		if pct / 25 != last_pct / 25:
			last_pct = pct
			print("  进度 %d%%  %d/%d" % [pct, recv, total]))
	d.finished.connect(func(path: String, sha: String) -> void:
		dl.append(path); dl.append(sha))
	d.failed.connect(func(reason: String) -> void:
		dl.append(""); dl.append(reason))
	d.start(m.download_url, "pixel-adventure-%s.apk" % m.version_name)
	g = 0
	while dl.is_empty() and g < 3600:
		await get_tree().process_frame
		g += 1
	if dl.is_empty() or String(dl[0]) == "":
		print("RESULT: FAIL 下载失败 -> ", dl)
		get_tree().quit(1); return
	var abs_path := String(dl[0])
	var size := OtaVerifier.file_size(abs_path)
	var verdict := OtaVerifier.verify_file(abs_path, m.sha256)
	print("  落盘 %s" % abs_path)
	print("  字节 %d（清单 %d）" % [size, m.size_bytes])
	print("  判定 %s" % OtaVerifier.verdict_text(verdict))
	var ok := size == m.size_bytes and verdict == OtaVerifier.Verdict.MATCH
	print("=== 真实 APK 下载演练结束 ===")
	print("RESULT: ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)
