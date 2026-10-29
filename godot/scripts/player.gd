class_name Player
extends CharacterBody2D
##
## 玩家角色：还原《超级玛丽》式横版手感。
##   - 可变跳高：上升期按住跳跃键，重力乘 RISE_GRAVITY_SCALE
##   - 松开跳跃键截断上升速度：velocity.y *= JUMP_CUT
##   - 土狼时间 COYOTE / 跳跃缓冲 BUFFER
##   - 最大下落速度 MAX_FALL，地面 / 空中加速度分离
## 严格遵循 docs/contracts.md §6。
##

signal died(reason: String)              # "pit" | "damage"
signal hp_changed(hp: int, max_hp: int)
signal block_hit(result: String, block_pos: Vector2)
signal stomped(enemy: Node2D)
signal coin_collected(pos: Vector2)
signal powerup(pos: Vector2)
signal landed(strong: bool)

const SPRITE_SCALE := 0.5        # 素材为 32x32，世界碰撞体 12x15，缩到一半对齐
const PUSH_DOWN_SPEED := 60.0     # 顶到砖块后的下压反馈
const STRONG_LAND_SPEED := 320.0 # 超过该下落速度算“重落地”

# ---- 公开状态（main.gd 依赖）----
var hp: int = GameConfig.START_HP
var max_hp: int = GameConfig.MAX_HP
var alive: bool = true
var invuln_timer: float = 0.0
var facing: int = 1

var input: InputHub = null

# ---- 内部状态 ----
var _sprite: AnimatedSprite2D = null
var _jump_sprite: AnimatedSprite2D = null
var _shape: CollisionShape2D = null
var _coyote_timer: float = 0.0
var _buffer_timer: float = 0.0
var _jump_cut_done: bool = false
var _was_on_floor: bool = true
var _fall_speed: float = 0.0
var _blink_timer: float = 0.0
var _pit_reported: bool = false

# ================================================================ 生命周期
func _ready() -> void:
	collision_layer = 2          # 玩家
	collision_mask = 1           # 只与地形碰撞
	motion_mode = CharacterBody2D.MOTION_MODE_GROUNDED
	_build_body()
	_build_sprites()

func setup(input_hub: InputHub) -> void:
	input = input_hub

## 重置位置 / 速度 / 无敌帧；保留 hp（不超过 max_hp），不重置 max_hp
func respawn(pos: Vector2) -> void:
	# pos 为「脚底」位置（契约 §0：出生点 feet y=288）
	position = pos - Vector2(0.0, GameConfig.PLAYER_H * 0.5)
	velocity = Vector2.ZERO
	alive = true
	_pit_reported = false
	invuln_timer = 0.0
	_coyote_timer = 0.0
	_buffer_timer = 0.0
	_jump_cut_done = false
	_fall_speed = 0.0
	_was_on_floor = false
	hp = clampi(hp, 0, max_hp)
	_set_alpha(1.0)
	_update_sprite_state()

# ================================================================ 构造
func _build_body() -> void:
	if _shape != null:
		return
	_shape = CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(GameConfig.PLAYER_W, GameConfig.PLAYER_H)
	_shape.shape = rect
	add_child(_shape)

func _build_sprites() -> void:
	if _sprite != null:
		return
	_sprite = SpriteFactory.make_animated("hero", 10.0)
	_ensure_run_animation(_sprite, "hero", GameConfig.FRAME_HERO, 10.0)
	_set_anim_speed(_sprite, 10.0)
	_sprite.scale = Vector2(SPRITE_SCALE, SPRITE_SCALE)
	add_child(_sprite)
	_align_sprite_bottom(_sprite, GameConfig.PLAYER_H)
	_play_run(_sprite)

	_jump_sprite = SpriteFactory.make_animated("hero_jump", 10.0)
	_ensure_run_animation(_jump_sprite, "hero_jump", GameConfig.FRAME_HERO_JUMP, 10.0)
	_set_anim_speed(_jump_sprite, 10.0)
	_jump_sprite.scale = Vector2(SPRITE_SCALE, SPRITE_SCALE)
	add_child(_jump_sprite)
	_align_sprite_bottom(_jump_sprite, GameConfig.PLAYER_H)
	_play_run(_jump_sprite)
	_jump_sprite.visible = false

## 播放 "run" 动画（动画缺失时安全跳过，避免运行期报错）
func _play_run(spr: AnimatedSprite2D) -> void:
	if spr == null or spr.sprite_frames == null:
		return
	if not spr.sprite_frames.has_animation("run"):
		return
	if spr.sprite_frames.get_frame_count("run") <= 0:
		return
	spr.play("run")

## SpriteFrames 动画速度（工厂只写 meta，这里补上真正的 fps）
func _set_anim_speed(spr: AnimatedSprite2D, fps: float) -> void:
	if spr == null or spr.sprite_frames == null:
		return
	for anim in spr.sprite_frames.get_animation_names():
		spr.sprite_frames.set_animation_speed(anim, fps)

## 兼容修复：SpriteFactory.make_animated() 目前不会创建 "run" 动画
## （内部 remove_animation("default") 后直接 add_frame("run")，Godot 会报
##  "Animation 'run' doesn't exist"）。这里在拿到 SpriteFrames 之后补建动画并填帧，
## 保证动画帧真的存在。修复工厂后本函数自动变成空操作。
func _ensure_run_animation(spr: AnimatedSprite2D, entity: String, frame_files: Array, fps: float) -> void:
	if spr == null or spr.sprite_frames == null:
		return
	var sf := spr.sprite_frames
	if sf.has_animation("run"):
		if sf.get_frame_count("run") <= 0:
			_fill_run_frames(sf, frame_files)
		sf.set_animation_speed("run", fps)
		return
	sf.add_animation("run")
	sf.set_animation_speed("run", fps)
	_fill_run_frames(sf, frame_files)
	spr.animation = "run"
	spr.frame = 0

func _fill_run_frames(sf: SpriteFrames, frame_files: Array) -> void:
	for f in frame_files:
		var path: String = GameConfig.SPRITES + String(f)
		if not ResourceLoader.exists(path):
			continue
		var tex: Texture2D = load(path)
		if tex != null:
			sf.add_frame("run", tex)

## 精灵底部对齐碰撞体底部
func _align_sprite_bottom(spr: AnimatedSprite2D, body_h: float) -> void:
	var tex_h := 0.0
	if spr.sprite_frames != null and spr.sprite_frames.has_animation("run"):
		var frames := spr.sprite_frames.get_frame_count("run")
		if frames > 0:
			var tex := spr.sprite_frames.get_frame_texture("run", 0)
			if tex != null:
				tex_h = float(tex.get_height()) * SPRITE_SCALE
	if tex_h <= 0.0:
		return
	spr.position = Vector2(0.0, (tex_h - body_h) * 0.5)

# ================================================================ 主循环
func _physics_process(delta: float) -> void:
	if not alive:
		return

	var dir := 0.0
	if input != null:
		dir = input.axis_x()

	var on_floor := is_on_floor()

	# ---- 水平移动：地面 ACCEL / 空中 AIR_ACCEL，地面 FRICTION 减速 ----
	var accel := GameConfig.ACCEL if on_floor else GameConfig.AIR_ACCEL
	if absf(dir) > 0.01:
		facing = 1 if dir > 0.0 else -1
		velocity.x = move_toward(velocity.x, dir * GameConfig.SPEED, accel * delta)
	elif on_floor:
		velocity.x = move_toward(velocity.x, 0.0, GameConfig.FRICTION * delta)

	# ---- 土狼时间 / 跳跃缓冲 ----
	if on_floor:
		_coyote_timer = GameConfig.COYOTE
	else:
		_coyote_timer = maxf(0.0, _coyote_timer - delta)
	if input != null and input.just_pressed(InputHub.JUMP):
		_buffer_timer = GameConfig.BUFFER
	else:
		_buffer_timer = maxf(0.0, _buffer_timer - delta)

	if _buffer_timer > 0.0 and _coyote_timer > 0.0:
		velocity.y = GameConfig.JUMP_V
		_buffer_timer = 0.0
		_coyote_timer = 0.0
		_jump_cut_done = false
		_fall_speed = 0.0

	# ---- 重力：上升期按住跳跃键重力打折（可变跳高）----
	var jump_held := input != null and input.is_held(InputHub.JUMP)
	var g := GameConfig.GRAVITY
	if velocity.y < 0.0:
		if jump_held:
			g *= GameConfig.RISE_GRAVITY_SCALE
		elif not _jump_cut_done:
			velocity.y *= GameConfig.JUMP_CUT   # 松手截断上升
			_jump_cut_done = true
	velocity.y += g * delta
	if velocity.y > GameConfig.MAX_FALL:
		velocity.y = GameConfig.MAX_FALL

	_fall_speed = maxf(_fall_speed, velocity.y)
	move_and_slide()

	# ---- 落地判定 ----
	var now_on_floor := is_on_floor()
	if now_on_floor and not _was_on_floor:
		landed.emit(_fall_speed >= STRONG_LAND_SPEED)
		_fall_speed = 0.0
	_was_on_floor = now_on_floor

	# ---- 顶砖块 ----
	_check_block_hits()

	# ---- 掉坑 ----
	if not _pit_reported and position.y > GameConfig.WORLD_H + 40.0:
		_pit_reported = true
		alive = false
		died.emit("pit")

	_update_sprite_state()
	_update_invuln(delta)

# ================================================================ 顶砖块
## 每次物理帧检查滑动碰撞：法线朝下（被从下往上顶）且碰撞体有 hit() 时调用。
## 同一帧内对同一碰撞体只触发一次。
func _check_block_hits() -> void:
	var count := get_slide_collision_count()
	if count <= 0:
		return
	var seen := {}
	var hit_any := false
	for i in count:
		var col := get_slide_collision(i)
		if col == null:
			continue
		if col.get_normal().y <= 0.5:
			continue
		var obj: Object = col.get_collider()
		if obj == null or not obj.has_method("hit"):
			continue
		var id := obj.get_instance_id()
		if seen.has(id):
			continue
		seen[id] = true
		var result := ""
		var rv: Variant = obj.call("hit")
		if rv is String:
			result = rv
		var bpos := global_position
		if obj is Node2D:
			bpos = (obj as Node2D).global_position
		hit_any = true
		block_hit.emit(result, bpos)
	if hit_any:
		velocity.y = PUSH_DOWN_SPEED

# ================================================================ 生命 / 受伤
## 返回是否真的受伤（无敌帧内返回 false）
func hurt() -> bool:
	if not alive:
		return false
	if invuln_timer > 0.0:
		return false
	hp -= 1
	invuln_timer = GameConfig.INVULN
	_blink_timer = 0.0
	hp_changed.emit(hp, max_hp)
	if hp <= 0:
		hp = 0
		alive = false
		died.emit("damage")
	return true

func add_hp(n: int) -> void:
	hp = clampi(hp + n, 0, max_hp)
	hp_changed.emit(hp, max_hp)

## 踩到敌人后的弹跳
func bounce() -> void:
	velocity.y = GameConfig.STOMP_BOUNCE
	_jump_cut_done = false

func is_dead() -> bool:
	return not alive

# ================================================================ 查询
## 世界坐标 AABB（main.gd 手动判定用）
func get_rect() -> Rect2:
	return Rect2(
		global_position - Vector2(GameConfig.PLAYER_W, GameConfig.PLAYER_H) * 0.5,
		Vector2(GameConfig.PLAYER_W, GameConfig.PLAYER_H)
	)

## 脚底世界 y
func get_feet_y() -> float:
	return global_position.y + GameConfig.PLAYER_H * 0.5

# ================================================================ 视觉
func _update_sprite_state() -> void:
	var airborne := not is_on_floor()
	if _sprite != null:
		_sprite.visible = not airborne
		_sprite.flip_h = facing < 0
	if _jump_sprite != null:
		_jump_sprite.visible = airborne
		_jump_sprite.flip_h = facing < 0

func _update_invuln(delta: float) -> void:
	if invuln_timer <= 0.0:
		if _blink_timer != 0.0:
			_blink_timer = 0.0
			_set_alpha(1.0)
		return
	invuln_timer = maxf(0.0, invuln_timer - delta)
	_blink_timer += delta
	var a := 1.0 if fmod(_blink_timer, 0.16) < 0.08 else 0.3
	_set_alpha(a)

func _set_alpha(a: float) -> void:
	if _sprite != null:
		_sprite.modulate.a = a
	if _jump_sprite != null:
		_jump_sprite.modulate.a = a
