extends Node
## OTA 面板截图（仅用于文档配图，不进包）
## 运行： godot --path godot res://ota_shot.tscn -- <输出png绝对路径> [available|progress|failed]
var _out := "user://ota_shot.png"
var _mode := "available"

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	if args.size() > 1:
		_mode = String(args[1])
	var scene: PackedScene = load("res://main.tscn")
	var inst = scene.instantiate()
	add_child(inst)
	for i in 30:
		await get_tree().physics_frame
	inst.call("start_game")
	for i in 20:
		await get_tree().physics_frame

	var panel = inst.get("ota_panel")
	var m := OtaManifest.from_json_text("""{"latest": {
		"game": "像素冒险",
		"package": "com.pixelstudio.pixeladventure",
		"version_name": "1.1.0",
		"version_code": 3,
		"published_at": "2026-11-05T09:30:00Z",
		"size_bytes": 30383842,
		"sha256": "710b581710c3e7cca8dc39600a7c51003136f958fcf3a1d4a14bbad39175ffc5",
		"min_supported_version_code": 1,
		"mandatory": false,
		"changelog": ["新增应用内 OTA 更新：启动检查、下载、SHA-256 校验、安装跳转", "新增 OTA 日志与失败重试入口"],
		"download_url": "https://github.com/owner/repo/releases/download/v1.1.0/pixel-adventure-1.1.0.apk",
		"release_page": "https://github.com/owner/repo/releases/tag/v1.1.0"
	}}""")
	match _mode:
		"available":
			panel.call("show_available", m)
		"progress":
			panel.call("show_progress", "1.1.0", 14680064, 30383842)
		"failed":
			panel.call("show_result", "更新失败", [
				"原因：下载中断（网络错误）",
				"当前版本 1.0.1 未受影响，可继续游戏",
			], ["重试", "手动下载", "取消"], {"kind": "failed"})
	for i in 8:
		await get_tree().physics_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_out)
	print("SHOT: ", _out, " ", img.get_width(), "x", img.get_height())
	get_tree().quit(0)
