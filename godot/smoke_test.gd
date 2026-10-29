extends Node
##
## 无头冒烟测试：自检输入 / 物理 / 关卡构建 / 敌人拾取 / 重生 / 关卡结束流程。
## 运行方式：
##   godot --headless --path <godot工程> --import
##   godot --headless --path <godot工程> res://smoke_test.tscn
##
## 关键点：所有玩家行为测试都必须在**真实关卡地形**上跑，
## 否则玩家脚下没有地面会直接掉出世界被判死。
##

const ITER := 240

var failures: Array[String] = []
var checks := 0

var _level: LevelBuilder = null
var _hub: InputHub = null


func _ready() -> void:
	print("=== 像素冒险 冒烟测试开始 ===")
	await _test_level()
	await _test_player_move()
	await _test_player_jump()
	await _test_enemy_and_pickup()
	await _test_respawn()
	await _test_checkpoint()
	await _test_checkpoint_respawn_in_main()
	await _test_main_scene()
	await _test_playthrough()
	print("=== 冒烟测试结束：%d 项检查，%d 项失败 ===" % [checks, failures.size()])
	for f in failures:
		print("  [FAIL] ", f)
	if failures.is_empty():
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL")
	get_tree().quit(0 if failures.is_empty() else 1)


func _ok(cond: bool, msg: String) -> void:
	checks += 1
	if cond:
		print("  [OK] ", msg)
	else:
		failures.append(msg)
		print("  [NG] ", msg)


# ---------------------------------------------------------------- 关卡
func _test_level() -> void:
	print("-- 关卡构建 --")
	_level = LevelBuilder.new()
	_level.name = "TestLevel"
	add_child(_level)
	_level.build(LevelData.ROWS)
	await get_tree().physics_frame
	_ok(LevelData.ROWS.size() == GameConfig.LEVEL_ROWS, "关卡行数 = %d" % LevelData.ROWS.size())
	_ok(_level.spawn_point.x > 0.0 and _level.spawn_point.y > 0.0, "出生点有效 %s" % str(_level.spawn_point))
	_ok(_level.goal_point.x > _level.spawn_point.x, "终点在出生点右侧 %s" % str(_level.goal_point))
	_ok(_level.enemies.size() > 0, "敌人数 = %d" % _level.enemies.size())
	_ok(_level.pickups.size() > 0, "拾取物数 = %d" % _level.pickups.size())
	_ok(_level.blocks.size() > 0, "砖块数 = %d" % _level.blocks.size())
	_ok(_level.goal_point.distance_to(Vector2(202 * 16, 256)) < 20.0,
		"终点坐标符合契约 %s" % str(_level.goal_point))


# ---------------------------------------------------------------- 移动
func _test_player_move() -> void:
	print("-- 水平移动 --")
	var p := _make_player()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_ok(p.is_on_floor(), "玩家在出生点站在地面上")
	var x0 := p.global_position.x
	# 只跑 120 帧（约 2 秒，位移约 300px），避免冲进 29-34 列的第一个深坑
	for i in 120:
		_press(InputHub.RIGHT, true)
		await get_tree().physics_frame
	_press(InputHub.RIGHT, false)
	await get_tree().physics_frame
	_ok(p.global_position.x > x0 + 20.0, "按住右键后 x 前进 %.1f -> %.1f" % [x0, p.global_position.x])
	_ok(p.alive, "移动过程中玩家存活")
	p.queue_free()


# ---------------------------------------------------------------- 跳跃
func _test_player_jump() -> void:
	print("-- 跳跃与落地 --")
	var p := _make_player()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var y0 := p.global_position.y
	var min_y := y0
	for i in 60:
		_press(InputHub.JUMP, true)
		await get_tree().physics_frame
		min_y = minf(min_y, p.global_position.y)
	_press(InputHub.JUMP, false)
	_ok(min_y < y0 - 10.0, "起跳后高度上升 %.1f px" % (y0 - min_y))

	# 短按跳跃（滞空控制）：同样的按键时长，跳得应当更低
	var p2 := _make_player()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var y02 := p2.global_position.y
	var min_y2 := y02
	for i in 6:
		_press(InputHub.JUMP, true)
		await get_tree().physics_frame
		min_y2 = minf(min_y2, p2.global_position.y)
	_press(InputHub.JUMP, false)
	for i in 40:
		await get_tree().physics_frame
		min_y2 = minf(min_y2, p2.global_position.y)
	_ok(min_y2 > min_y + 2.0, "短按跳跃更矮：短按 %.1f px < 长按 %.1f px" % [y0 - min_y2, y0 - min_y])
	p2.queue_free()

	for i in 120:
		await get_tree().physics_frame
	_ok(absf(p.global_position.y - y0) < 3.0, "落地后回到原高度 y=%.1f (起始 %.1f)" % [p.global_position.y, y0])
	p.queue_free()


# ---------------------------------------------------------------- 敌人 / 拾取
func _test_enemy_and_pickup() -> void:
	print("-- 敌人与拾取 --")
	var e: Node2D = _level.enemies[0]
	_ok(e.has_method("get_rect"), "敌人提供 get_rect()")
	_ok(e.has_method("stomp"), "敌人提供 stomp()")
	_ok(e.has_method("hit_player"), "敌人提供 hit_player()")
	_ok(e.has_method("reset"), "敌人提供 reset()")
	var rect: Rect2 = e.get_rect()
	_ok(rect.size.x > 0 and rect.size.y > 0, "敌人 AABB 有效 %s" % str(rect))
	e.stomp()
	await get_tree().physics_frame
	_ok(not e.is_alive(), "踩踏后敌人失效")
	e.reset()
	await get_tree().physics_frame
	_ok(e.is_alive(), "reset 后敌人复活")

	# 拾取物结构：main.gd 依赖 node / kind / pos / taken 四个键
	var pk: Dictionary = _level.pickups[0]
	_ok(pk.has("node") and pk.has("kind") and pk.has("pos") and pk.has("taken"),
		"拾取物含 node/kind/pos/taken 四个键")
	_ok(is_instance_valid(pk["node"]), "拾取物节点有效")


# ---------------------------------------------------------------- 重生
func _test_respawn() -> void:
	print("-- 失败重生 --")
	var p := _make_player()
	p.global_position = Vector2(100, GameConfig.WORLD_H + 100)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_ok(not p.alive, "掉出世界后判定死亡")
	var hp_before := p.hp
	p.respawn(_level.spawn_point)
	await get_tree().physics_frame
	_ok(p.global_position.distance_to(_level.spawn_point - Vector2(0, GameConfig.PLAYER_H * 0.5)) < 4.0,
		"respawn 后回到出生点 %s" % str(p.global_position))
	_ok(p.alive, "respawn 后恢复存活")
	_ok(p.hp == hp_before, "respawn 不重置血量 %d" % p.hp)
	p.queue_free()


# ---------------------------------------------------------------- 检查点
# 检查点：玩家经过旗帜 → 点亮；掉坑重生 → 从最近点亮的检查点继续。
func _test_checkpoint() -> void:
	print("-- 检查点 --")
	var field := CheckpointField.new()
	field.name = "CheckpointField"
	add_child(field)
	field.build()
	await get_tree().physics_frame
	_ok(field.checkpoints.size() == GameConfig.CHECKPOINT_COLS.size(),
		"检查点数量 = %d" % field.checkpoints.size())

	# 全部检查点必须站在实心地面上（旗底 y == 地面表层 y）
	var all_grounded := true
	for cp in field.checkpoints:
		var r: Rect2 = cp.get_rect()
		# 旗底 = rect 底边，应正好等于地面表层
		if absf(r.position.y + r.size.y - GameConfig.CHECKPOINT_GROUND_Y) > 1.0:
			all_grounded = false
	_ok(all_grounded, "检查点都立在地面表层 y=%.0f" % GameConfig.CHECKPOINT_GROUND_Y)

	# 未点亮时重生点 = 出生点
	_ok(field.get_respawn_point(_level.spawn_point).distance_to(_level.spawn_point) < 1.0,
		"未点亮检查点时仍从出生点重生")

	# 模拟玩家走到第一个检查点 → 应点亮
	var cp0: Checkpoint = field.checkpoints[0]
	var pr := Rect2(cp0.global_position, Vector2(8, 8))
	field.update_player(pr)
	await get_tree().physics_frame
	_ok(cp0.active, "玩家经过后检查点点亮")
	_ok(field.has_active(), "检查点场记录了激活状态")
	_ok(field.get_respawn_point(_level.spawn_point).distance_to(cp0.get_respawn_point()) < 1.0,
		"点亮后重生点改为检查点 %s" % str(cp0.get_respawn_point()))

	# reset 应恢复未点亮
	field.reset()
	await get_tree().physics_frame
	_ok(not cp0.active, "reset 后检查点熄灭")
	_ok(not field.has_active(), "reset 后无激活检查点")
	field.queue_free()


# ---------------------------------------------------- 检查点接入主控后的重生
# 主控里掉坑重生应回到「最近点亮的检查点」，而不是关卡起点。
func _test_checkpoint_respawn_in_main() -> void:
	print("-- 检查点接入主控 --")
	var inst: GameMain = load("res://main.tscn").instantiate()
	add_child(inst)
	inst.start_game()
	await get_tree().physics_frame

	var field: CheckpointField = inst.get("checkpoint_field")
	var pl: Player = inst.get("player")
	_ok(field != null, "主场景装配了检查点场")
	if field == null:
		inst.queue_free()
		return

	# 模拟玩家走到第一个检查点
	var cp0: Checkpoint = field.checkpoints[0]
	field.update_player(Rect2(cp0.global_position, Vector2(8, 8)))
	await get_tree().physics_frame
	_ok(cp0.active, "主控中经过检查点会点亮")

	# 把玩家丢出世界 → 触发 pit 死亡 → 应从检查点重生
	pl.position = Vector2(pl.global_position.x, GameConfig.WORLD_H + 100.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	var expected := cp0.get_respawn_point()
	_ok(pl.global_position.distance_to(Vector2(expected.x, expected.y - GameConfig.PLAYER_H * 0.5)) < 2.0,
		"掉坑后从检查点重生（期望 x=%.0f，实际 x=%.0f）" % [expected.x, pl.global_position.x])
	_ok(pl.alive, "从检查点重生后仍然存活")
	inst.queue_free()
	await get_tree().physics_frame


# ---------------------------------------------------------------- 主场景
func _test_main_scene() -> void:
	print("-- 主场景装配 --")
	var scene: PackedScene = load("res://main.tscn")
	_ok(scene != null, "main.tscn 可加载")
	if scene == null:
		return
	var inst = scene.instantiate()
	add_child(inst)
	for i in 30:
		await get_tree().physics_frame
	_ok(inst.has_method("start_game"), "主场景具备 start_game()")
	inst.call("start_game")
	for i in 30:
		await get_tree().physics_frame
	var pl = inst.get("player")
	_ok(pl != null and is_instance_valid(pl), "玩家节点存在")
	var lv = inst.get("level")
	_ok(lv != null and is_instance_valid(lv), "关卡节点存在")
	inst.queue_free()


# ---------------------------------------------------------------- 自动通关
## 自动机器人：按住右方向键一路前进，遇到「前方无地面（深坑 / 平台尽头）」
## 或「前方有台阶」就起跳，目标是走完整关到达终点旗并进入结算状态。
## 血量在测试期间放宽到 30，保证掉坑重生 / 敌人碰撞不会直接结束游戏。
func _test_playthrough() -> void:
	print("-- 自动通关 --")
	var scene: PackedScene = load("res://main.tscn")
	if scene == null:
		_ok(false, "main.tscn 可加载（通关测试）")
		return
	var inst = scene.instantiate()
	add_child(inst)
	await get_tree().physics_frame
	await get_tree().physics_frame
	inst.call("start_game")
	await get_tree().physics_frame
	var pl: Player = inst.get("player")
	var hub: InputHub = inst.get("input_hub")
	var lv: LevelBuilder = inst.get("level")
	if pl == null or hub == null or lv == null:
		_ok(false, "通关测试：主场景节点齐全")
		inst.queue_free()
		return
	pl.max_hp = 30
	pl.hp = 30
	inst.set("hp", 30)

	var frames := 0
	var jumps := 0
	var jump_hold := 0
	var reached := false
	var finished_state := -1
	while frames < 15000:
		frames += 1
		var st: int = inst.get("state")
		if st != GameMain.State.PLAY:
			finished_state = st
			if st == GameMain.State.WIN:
				reached = true
			break
		# ---- 决策：站在地面上时，前方无地面或有台阶就起跳 ----
		if jump_hold <= 0 and pl.alive and pl.is_on_floor():
			var feet := pl.get_feet_y()
			if (not _ground_ahead(pl, feet)) or _wall_ahead(pl, feet):
				jumps += 1
				jump_hold = 30
		hub.set_simulated(InputHub.RIGHT, true)
		if jump_hold > 0:
			jump_hold -= 1
			hub.set_simulated(InputHub.JUMP, true)
		else:
			hub.set_simulated(InputHub.JUMP, false)
		await get_tree().physics_frame

	_ok(reached, "机器人走完全关到达终点（帧 %d，起跳 %d 次，x=%.0f，终点 x=%.0f）"
		% [frames, jumps, pl.global_position.x, lv.goal_point.x])
	_ok(finished_state == GameMain.State.WIN, "到达终点后进入 WIN 结算状态")
	inst.queue_free()
	await get_tree().physics_frame


## 前方（ahead 像素处）脚下是否有地面
func _ground_ahead(pl: Node2D, feet_y: float) -> bool:
	var space := pl.get_world_2d().direct_space_state
	if space == null:
		return true
	var from := Vector2(pl.global_position.x + 20.0, feet_y - 6.0)
	var to := from + Vector2(0.0, 40.0)
	var q := PhysicsRayQueryParameters2D.create(from, to)
	q.collision_mask = 1
	q.exclude = [pl.get_rid()]
	return not space.intersect_ray(q).is_empty()


## 前方是否有挡路的台阶 / 墙
func _wall_ahead(pl: Node2D, feet_y: float) -> bool:
	var space := pl.get_world_2d().direct_space_state
	if space == null:
		return false
	var from := Vector2(pl.global_position.x + 4.0, feet_y - 8.0)
	var to := Vector2(pl.global_position.x + 18.0, feet_y - 8.0)
	var q := PhysicsRayQueryParameters2D.create(from, to)
	q.collision_mask = 1
	q.exclude = [pl.get_rid()]
	return not space.intersect_ray(q).is_empty()


# ---------------------------------------------------------------- 辅助
## 在真实关卡地形上放一个玩家
func _make_player() -> Player:
	_hub = InputHub.new()
	_hub.name = "InputHub"
	add_child(_hub)
	var p := Player.new()
	p.name = "Player"
	add_child(p)
	p.setup(_hub)
	p.max_hp = GameConfig.MAX_HP
	p.hp = GameConfig.START_HP
	p.respawn(_level.spawn_point)
	return p


func _press(action: StringName, down: bool) -> void:
	if _hub == null:
		return
	_hub.set_simulated(action, down)
