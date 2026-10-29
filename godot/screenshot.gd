extends Node
##
## 截图工具：加载主场景，等待若干帧后把视口存成 PNG，用于视觉核验。
## 运行： godot --path <工程> res://screenshot.tscn -- <输出前缀> [等待帧数] [跳过开始界面]
##

var _out := "user://shot.png"
var _wait := 60
var _skip_title := false
var _mode := "play"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	if args.size() > 1:
		_wait = int(args[1])
	if args.size() > 2:
		_skip_title = args[2] == "1"
	if args.size() > 3:
		_mode = String(args[3])

	var scene: PackedScene = load("res://main.tscn")
	var inst = scene.instantiate()
	add_child(inst)
	for i in 30:
		await get_tree().physics_frame
	if _skip_title:
		inst.call("start_game")
	for i in _wait:
		await get_tree().physics_frame

	match _mode:
		"goal":
			var cam = inst.get("camera")
			cam.position = Vector2(3240.0, 240.0)
			cam.reset_smoothing()
			var pl3 = inst.get("player")
			pl3.global_position = Vector2(3240.0, 240.0)
			var ui = inst.get("ui")
			ui.visible = false
			for i in 10:
				await get_tree().physics_frame
		"pause":
			var hub = inst.get("input_hub")
			hub.call("set_simulated", "pause", true)
			for i in 4:
				await get_tree().physics_frame
			hub.call("set_simulated", "pause", false)
			for i in 4:
				await get_tree().physics_frame
		"win":
			var pl = inst.get("player")
			pl.global_position.x = 3230.0
			for i in 10:
				await get_tree().physics_frame
		"lose":
			var pl2 = inst.get("player")
			pl2.hp = 0
			pl2.alive = false
			inst.call("_enter_lose")
			for i in 6:
				await get_tree().physics_frame
		"checkpoint":
			# 走到第一个检查点（列 36）并点亮，展示存档旗
			var plc = inst.get("player")
			plc.global_position = Vector2(36.0 * 16.0 + 8.0, 288.0 - 8.0)
			for i in 20:
				await get_tree().physics_frame
		"touch":
			# 强制显示触屏控件（桌面端默认自动隐藏）
			var tc = inst.get("touch")
			tc.set("_input_seen", true)
			tc.call("_refresh_visibility")
			tc.call("set_enabled", true)
			for i in 10:
				await get_tree().physics_frame

	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_out)
	print("SHOT: ", _out, " ", img.get_width(), "x", img.get_height())
	get_tree().quit(0)
