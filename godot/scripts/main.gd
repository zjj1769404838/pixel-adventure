class_name GameMain
extends Node2D
##
## 主控：状态机 + 游戏循环 + 相机 + 音频 + 敌人/拾取判定。
##
## 状态：TITLE -> PLAY <-> PAUSE -> WIN / LOSE
##

enum State { TITLE, PLAY, PAUSE, WIN, LOSE }

const FONT_PATH := "res://assets/fonts/zpix.ttf"

var state: int = State.TITLE

# ---- 节点 ----
var input_hub: InputHub
var level: LevelBuilder
var player: Player
var camera: Camera2D
var ui: GameUI
var touch: TouchControls

# ---- 音频 ----
var bgm: AudioStreamPlayer
var sfx_pool: Array[AudioStreamPlayer] = []
var sfx_idx := 0

# ---- 运行时状态 ----
var score := 0
var coins := 0
var hp := 0
var elapsed := 0.0
var time_sec := 0
var lose_timer := 0.0
var win_timer := 0.0
var hint_text := ""
var hint_timer := 0.0
var _fx_layer: Node2D
var _pending_fx: Array = []
var checkpoint_field: CheckpointField = null

# ---- OTA 更新（可完全关闭：ota_config.json 里 manifest_url 留空即不检查） ----
var ota_panel: OtaPanel
var ota: OtaManager
var _ota_busy := false

func _ready() -> void:
	_build_scene()
	_enter_title()
	# 启动后静默检查一次更新：失败不打扰玩家，成功才弹面板
	if ota != null:
		ota.check_silent()

# ---------------------------------------------------------------- 场景构建
func _build_scene() -> void:
	# 背景色（天空）
	var bg := ColorRect.new()
	bg.color = Color(0.36, 0.62, 0.86)
	bg.size = Vector2(GameConfig.VIEW_W, GameConfig.VIEW_H)
	bg.z_index = -100
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# 远景山丘（两层视差，纯色剪影）
	_add_hills(Color(0.27, 0.47, 0.36), 60.0, 0.25, 18.0)
	_add_hills(Color(0.20, 0.38, 0.30), 40.0, 0.5, 12.0)

	_fx_layer = Node2D.new()
	_fx_layer.z_index = 40
	add_child(_fx_layer)

	# 输入
	input_hub = InputHub.new()
	input_hub.name = "InputHub"
	add_child(input_hub)

	# 关卡
	level = LevelBuilder.new()
	level.name = "Level"
	add_child(level)
	level.build(LevelData.ROWS)

	# 检查点（中途存档旗）
	checkpoint_field = CheckpointField.new()
	checkpoint_field.name = "CheckpointField"
	add_child(checkpoint_field)
	checkpoint_field.build()

	# 玩家
	player = Player.new()
	player.name = "Player"
	add_child(player)
	player.setup(input_hub)
	player.respawn(level.spawn_point)
	player.hp = GameConfig.START_HP
	player.max_hp = GameConfig.MAX_HP
	hp = player.hp
	player.died.connect(_on_player_died)
	player.hp_changed.connect(_on_player_hp)
	player.block_hit.connect(_on_player_block_hit)
	player.stomped.connect(_on_player_stomped)
	player.coin_collected.connect(_on_player_coin)
	player.powerup.connect(_on_player_powerup)

	# 相机
	camera = Camera2D.new()
	camera.name = "Camera"
	camera.enabled = true
	# 拉近镜头：视野变小、角色在屏占比变大（调参见 game_config.gd 的 CAMERA_ZOOM）
	camera.zoom = Vector2(GameConfig.CAMERA_ZOOM, GameConfig.CAMERA_ZOOM)
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 6.0
	camera.limit_left = 0
	camera.limit_right = GameConfig.WORLD_W
	camera.limit_top = 0
	camera.limit_bottom = GameConfig.WORLD_H
	add_child(camera)
	camera.make_current()

	# 界面
	ui = GameUI.new()
	ui.name = "UI"
	add_child(ui)
	ui.setup(FONT_PATH)

	# 触屏虚拟控制（仅 State.PLAY 启用）
	touch = TouchControls.new()
	touch.name = "TouchControls"
	add_child(touch)
	touch.setup(input_hub, FONT_PATH)
	touch.set_enabled(false)

	# 音频
	_setup_audio()

	# OTA 更新（放在最后：面板 layer 120 盖在 UI 之上）
	_setup_ota()

	# 敌人 / 拾取监听
	for e in level.enemies:
		if e.has_signal("defeated"):
			e.defeated.connect(_on_enemy_defeated)

## 远景山丘：程序化生成的视差剪影
func _add_hills(col: Color, spacing: float, parallax: float, height: float) -> void:
	var layer := Node2D.new()
	layer.z_index = -50
	add_child(layer)
	var count := int(GameConfig.WORLD_W / spacing) + 4
	for i in count:
		var poly := Polygon2D.new()
		poly.color = col
		var x := i * spacing
		var w := spacing * 1.4
		var h := height + fmod(float(i) * 37.0, height)
		poly.polygon = PackedVector2Array([
			Vector2(x, GameConfig.WORLD_H),
			Vector2(x + w * 0.5, GameConfig.WORLD_H - h),
			Vector2(x + w, GameConfig.WORLD_H),
		])
		layer.add_child(poly)
	layer.set_meta("parallax", parallax)

func _setup_audio() -> void:
	bgm = AudioStreamPlayer.new()
	var path := GameConfig.SFX_DIR + "bgm.wav"
	if ResourceLoader.exists(path):
		var st: AudioStreamWAV = load(path)
		if st != null:
			var total := st.get_length() * st.mix_rate
			if st.loop_mode == AudioStreamWAV.LOOP_FORWARD:
				st.loop_begin = 0
				st.loop_end = int(total)
			bgm.stream = st
	bgm.volume_db = -8.0
	add_child(bgm)
	for i in 6:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		sfx_pool.append(p)

# ---------------------------------------------------------------- OTA 更新
## 装配 OTA：面板 + 总控。
## 设计约束：**OTA 绝不能影响正常启动**——配置缺失/清单地址为空时只是不检查，
## 任何异常都被 OtaLog 吞掉，不改变游戏状态机。
func _setup_ota() -> void:
	var cfg := OtaConfig.load_config()

	ota_panel = OtaPanel.new()
	ota_panel.name = "OtaPanel"
	add_child(ota_panel)
	ota_panel.setup(FONT_PATH)

	ota = OtaManager.new()
	ota.name = "OtaManager"
	add_child(ota)
	ota.on_busy_changed = _on_ota_busy
	ota.setup(cfg, ota_panel)

	OtaLog.write("boot", {
		"version": OtaConfig.current_version(),
		"code": OtaConfig.current_version_code(),
		"config_source": cfg.source,
		"has_manifest": cfg.has_manifest_url(),
		"platform": OS.get_name(),
	})

## OTA 面板打开时暂停游戏输入（不改变 state，避免影响重开/结算流程）
func _on_ota_busy(busy: bool) -> void:
	_ota_busy = busy
	if busy:
		_set_touch_active(false, TouchControls.TAP_NONE)

# ---------------------------------------------------------------- 状态切换
func _enter_title() -> void:
	state = State.TITLE
	player.visible = false
	level.visible = true
	ui.hide_all()
	ui.show_title()
	ui.set_hint("")
	_set_touch_active(false, TouchControls.TAP_START)

func start_game() -> void:
	score = 0
	coins = 0
	elapsed = 0.0
	time_sec = 0
	lose_timer = 0.0
	win_timer = 0.0
	player.hp = GameConfig.START_HP
	player.max_hp = GameConfig.MAX_HP
	hp = player.hp
	player.alive = true
	player.visible = true
	player.invuln_timer = 0.0
	player.respawn(level.spawn_point)
	_reset_level_pickups()
	_reset_enemies()
	if checkpoint_field != null:
		checkpoint_field.reset()
	camera.position = Vector2(GameConfig.VIEW_W_ZOOM * 0.5, GameConfig.VIEW_H_ZOOM * 0.5)
	camera.reset_smoothing()
	state = State.PLAY
	ui.hide_all()
	ui.show_hud()
	ui.set_score(score)
	ui.set_coins(coins)
	ui.set_hp(hp, GameConfig.MAX_HP)
	ui.set_time(time_sec)
	ui.set_hint("")
	_play_sfx("powerup")
	if bgm.stream != null and not bgm.playing:
		bgm.play()
	_set_touch_active(true)

func _reset_level_pickups() -> void:
	for p in level.pickups:
		p["taken"] = false
		var n: Node2D = p["node"]
		if is_instance_valid(n):
			n.visible = true

func _reset_enemies() -> void:
	for e in level.enemies:
		if e.has_method("reset"):
			e.call("reset")

# ---------------------------------------------------------------- 主循环
func _process(delta: float) -> void:
	input_hub.poll()
	# OTA 面板打开时冻结游戏逻辑：面板自己处理输入，游戏状态原样保留
	if _ota_busy:
		return
	# 手动检查更新（U 键）：任何游戏状态下都可触发，不改变 state
	if ota != null and input_hub.just_pressed(InputHub.CHECK_UPDATE):
		ota.check_manual()
	match state:
		State.TITLE:
			if input_hub.just_pressed(InputHub.JUMP) or input_hub.just_pressed(InputHub.CONFIRM):
				start_game()
		State.PLAY:
			_tick_play(delta)
		State.PAUSE:
			if input_hub.just_pressed(InputHub.PAUSE):
				state = State.PLAY
				ui.hide_all()
				ui.show_hud()
				_set_touch_active(true)
			elif input_hub.just_pressed(InputHub.RESTART):
				start_game()
		State.WIN:
			win_timer += delta
			if input_hub.just_pressed(InputHub.RESTART):
				start_game()
		State.LOSE:
			lose_timer += delta
			if lose_timer > 0.5 and input_hub.just_pressed(InputHub.RESTART):
				start_game()

	if hint_timer > 0.0:
		hint_timer -= delta
		if hint_timer <= 0.0:
			ui.set_hint("")

	_update_camera(delta)

func _tick_play(delta: float) -> void:
	elapsed += delta
	time_sec = int(elapsed)
	ui.set_time(time_sec)
	score += int(GameConfig.SCORE_TIME * delta)

	if input_hub.just_pressed(InputHub.PAUSE):
		state = State.PAUSE
		ui.hide_all()
		ui.show_pause()
		_set_touch_active(false, TouchControls.TAP_RESUME)
		return
	if input_hub.just_pressed(InputHub.RESTART):
		start_game()
		return

	_check_pickups()
	_check_enemies()
	_check_checkpoints()
	_check_goal()
	_update_fx(delta)

## 经过检查点旗 → 点亮（马里奥式中途存档）
func _check_checkpoints() -> void:
	if checkpoint_field == null:
		return
	var before := checkpoint_field.has_active()
	checkpoint_field.update_player(player.get_rect())
	if checkpoint_field.has_active() and not before:
		_play_sfx("powerup")
		_show_hint("存档点！掉坑后从这里继续")

## 到达终点：碰到终点旗就算通关（马里奥碰旗杆即过关）。
## 判定用「横向到达 + 纵向宽容」，避免玩家跳过旗杆时因为高度差判不到。
func _check_goal() -> void:
	if state != State.PLAY:
		return
	var g: Vector2 = level.goal_point
	if player.global_position.x >= g.x - 16.0:
		_enter_win()

func _enter_win() -> void:
	state = State.WIN
	win_timer = 0.0
	_play_sfx("win")
	ui.hide_all()
	ui.show_win(score, coins, time_sec)
	_set_touch_active(false, TouchControls.TAP_RESTART)

func _on_player_died(reason: String) -> void:
	if state != State.PLAY:
		return
	if reason == "pit":
		# 掉进深坑：扣一条命并回到起点继续（马里奥式重生），不是直接结束游戏
		player.hp = maxi(0, player.hp - 1)
		hp = player.hp
		ui.set_hp(hp, GameConfig.MAX_HP)
		_play_sfx("hurt")
		if player.hp <= 0:
			_enter_lose()
			return
		player.respawn(_respawn_point())
		camera.position = Vector2(GameConfig.VIEW_W_ZOOM * 0.5, GameConfig.VIEW_H_ZOOM * 0.5)
		camera.reset_smoothing()
		_show_hint("掉进深坑！继续前进")
		return
	_enter_lose()

## 当前应该重生的脚底坐标：优先最近点亮的检查点，否则回出生点。
func _respawn_point() -> Vector2:
	if checkpoint_field != null:
		return checkpoint_field.get_respawn_point(level.spawn_point)
	return level.spawn_point

func _enter_lose() -> void:
	state = State.LOSE
	lose_timer = 0.0
	_play_sfx("lose")
	ui.hide_all()
	ui.show_lose(score, coins, time_sec)
	_set_touch_active(false, TouchControls.TAP_RESTART)

func _show_hint(msg: String) -> void:
	hint_text = msg
	hint_timer = 2.0
	ui.set_hint(msg)

## 触屏控件开关：只有 State.PLAY 才启用；关闭时隐藏控件并清零虚拟输入。
## 非 PLAY 状态下点屏幕可代替键盘：标题=开始、暂停=继续、结算=重开。
func _set_touch_active(active: bool, tap_mode: int = TouchControls.TAP_NONE) -> void:
	if touch == null:
		return
	touch.set_tap_mode(tap_mode)
	if active != touch.enabled:
		touch.set_enabled(active)

# ---------------------------------------------------------------- 拾取 / 敌人判定
func _check_pickups() -> void:
	var pr := player.get_rect()
	for p in level.pickups:
		if p["taken"]:
			continue
		var n: Node2D = p["node"]
		if not is_instance_valid(n) or not n.visible:
			continue
		var pos: Vector2 = p["pos"]
		var r := Rect2(pos - Vector2(8, 8), Vector2(16, 16))
		if not pr.intersects(r):
			continue
		p["taken"] = true
		n.visible = false
		if String(p["kind"]) == "coin":
			coins += 1
			score += GameConfig.SCORE_COIN
			_play_sfx("coin")
			_spawn_coin_fx(pos)
		else:
			score += GameConfig.SCORE_COIN * 2
			player.add_hp(1)
			_play_sfx("powerup")
			_spawn_pickup_fx(pos, "pickup_mushroom")
		ui.set_coins(coins)
		ui.set_score(score)
		ui.set_hp(hp, GameConfig.MAX_HP)

func _check_enemies() -> void:
	var pr := player.get_rect()
	for e in level.enemies:
		if not is_instance_valid(e) or not e.has_method("is_alive") or not e.is_alive():
			continue
		var er: Rect2 = e.get_rect()
		if not pr.intersects(er):
			continue
		# 踩踏判定：玩家下落中 + 脚底在敌人上半部
		var feet := player.get_feet_y()
		var stomping := player.velocity.y > 0.0 and feet <= er.position.y + 9.0 and feet >= er.position.y - 4.0
		if stomping:
			e.stomp()
			player.bounce()
			score += GameConfig.SCORE_ENEMY
			_play_sfx("hit")
			_spawn_enemy_fx(er.get_center())
			ui.set_score(score)
		elif e.hit_player():
			if player.hurt():
				_play_sfx("hurt")
				hp = player.hp
				ui.set_hp(hp, GameConfig.MAX_HP)
				_spawn_enemy_fx(er.get_center())

# ---------------------------------------------------------------- 事件回调
func _on_player_hp(new_hp: int, max_hp: int) -> void:
	hp = new_hp
	ui.set_hp(hp, max_hp)

func _on_player_block_hit(result: String, block_pos: Vector2) -> void:
	match result:
		"coin":
			coins += 1
			score += GameConfig.SCORE_COIN
			_play_sfx("coin")
			_spawn_coin_fx(block_pos)
			ui.set_coins(coins)
			ui.set_score(score)
		"item":
			player.add_hp(1)
			_play_sfx("powerup")
			_spawn_pickup_fx(block_pos, "pickup_mushroom")
		"break":
			_play_sfx("hit")
			_spawn_brick_fx(block_pos)
			_break_block_at(block_pos)
		_:
			pass

func _break_block_at(block_pos: Vector2) -> void:
	for key in level.blocks.keys():
		var b = level.blocks[key]
		if not is_instance_valid(b):
			continue
		var k: Vector2i = key
		if Vector2(k.x * 16 + 8, k.y * 16 + 8).distance_to(block_pos) < 2.0:
			level.blocks.erase(key)
			b.queue_free()
			return

func _on_player_stomped(enemy: Node2D) -> void:
	pass

func _on_player_coin(pos: Vector2) -> void:
	pass

func _on_player_powerup(pos: Vector2) -> void:
	pass

func _on_enemy_defeated(enemy: Node2D) -> void:
	pass

# ---------------------------------------------------------------- 特效
func _spawn_coin_fx(pos: Vector2) -> void:
	var spr := SpriteFactory.make_animated("pickup_coin", 12.0)
	spr.position = pos
	_fx_layer.add_child(spr)
	_pending_fx.append({"node": spr, "t": 0.5, "vel": Vector2(0, -60)})

func _spawn_pickup_fx(pos: Vector2, entity: String) -> void:
	var spr := SpriteFactory.make_static(entity)
	spr.position = pos
	_fx_layer.add_child(spr)
	_pending_fx.append({"node": spr, "t": 0.6, "vel": Vector2(0, -70)})

func _spawn_brick_fx(pos: Vector2) -> void:
	var spr := SpriteFactory.make_animated("fx_brick", 12.0)
	spr.position = pos
	_fx_layer.add_child(spr)
	_pending_fx.append({"node": spr, "t": 0.4, "vel": Vector2(0, 0)})

func _spawn_enemy_fx(pos: Vector2) -> void:
	var spr := SpriteFactory.make_animated("fx_brick", 12.0)
	spr.position = pos
	_fx_layer.add_child(spr)
	_pending_fx.append({"node": spr, "t": 0.4, "vel": Vector2(0, 0)})

func _update_fx(delta: float) -> void:
	var keep := []
	for f in _pending_fx:
		f["t"] -= delta
		var n: Node2D = f["node"]
		if is_instance_valid(n):
			var v: Vector2 = f["vel"]
			n.position += v * delta
			v.y += 240.0 * delta
			f["vel"] = v
			if f["t"] <= 0.0:
				n.queue_free()
			else:
				keep.append(f)
	_pending_fx = keep

# ---------------------------------------------------------------- 相机
func _update_camera(delta: float) -> void:
	if player == null or camera == null:
		return
	# 相机跟随：按缩放后的可见范围做边界夹取，避免镜头越界露出黑边
	var half_w := GameConfig.VIEW_W_ZOOM * 0.5
	var half_h := GameConfig.VIEW_H_ZOOM * 0.5
	var target_x := clampf(player.global_position.x, half_w, GameConfig.WORLD_W - half_w)
	var target_y := clampf(player.global_position.y - 40.0, half_h, GameConfig.WORLD_H - half_h)
	var target := Vector2(target_x, target_y)
	camera.position = camera.position.lerp(target, clampf(delta * 8.0, 0.0, 1.0))

# ---------------------------------------------------------------- 音频
func _play_sfx(name: String) -> void:
	if sfx_pool.is_empty():
		return
	var p := sfx_pool[sfx_idx]
	sfx_idx = (sfx_idx + 1) % sfx_pool.size()
	var path := GameConfig.SFX_DIR + name + ".wav"
	if not ResourceLoader.exists(path):
		return
	var st = load(path)
	if st == null:
		return
	p.stream = st
	p.play()
