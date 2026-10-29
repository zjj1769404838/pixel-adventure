class_name Enemy
extends CharacterBody2D
##
## 敌人：grunt（地面巡逻）/ flyer（空中正弦浮动）。
## 碰撞层 4、掩码 1 —— 不与玩家发生物理碰撞，踩踏/受伤由 main.gd 用 get_rect() 手动判定。
## 严格遵循 docs/contracts.md §7。
##

signal defeated(enemy: Node2D)

const ENEMY_W := 14.0
const ENEMY_H := 14.0
const SPRITE_SCALE := 0.5
const CLIFF_RAY_LEN := 24.0     # 悬崖检测射线的长度
const CLIFF_RAY_OFFSET := 12.0  # 悬崖检测射线相对身体前缘的水平偏移
const EDGE_LOOKAHEAD := 14.0    # 墙体检测的前探距离

var kind: String = "grunt"
var alive: bool = true

var _sprite: AnimatedSprite2D = null
var _shape: CollisionShape2D = null
var _dir: int = 1
var _initial_position: Vector2 = Vector2.ZERO
var _initial_dir: int = 1
var _fly_phase: float = 0.0
var _fly_base_y: float = 0.0
var _fly_dir: int = 1
var _ground_probe: RayCast2D = null

# ================================================================ 生命周期
func _ready() -> void:
	collision_layer = 4          # 敌人
	collision_mask = 1           # 只与地形碰撞，不与玩家碰撞
	motion_mode = CharacterBody2D.MOTION_MODE_GROUNDED
	_build_body()
	_build_sprite()
	if _initial_position == Vector2.ZERO:
		_initial_position = position

## kind: "grunt" | "flyer"
func setup(kind_name: String) -> void:
	kind = kind_name
	_initial_position = position
	_initial_dir = _dir
	alive = true
	visible = true
	rotation = 0.0
	modulate = Color(1, 1, 1, 1)
	velocity = Vector2.ZERO
	if kind == "flyer":
		_fly_phase = 0.0
		_fly_base_y = position.y
		_fly_dir = _initial_dir
		_rebuild_sprite("enemy_flyer", false)
	else:
		_rebuild_sprite("enemy_grunt", true)

## 回到初始位置 / 朝向并重新变为 alive（按 R 重开复用）
func reset() -> void:
	position = _initial_position
	velocity = Vector2.ZERO
	_dir = _initial_dir
	alive = true
	visible = true
	rotation = 0.0
	modulate = Color(1, 1, 1, 1)
	set_physics_process(true)
	_fly_phase = 0.0
	_fly_base_y = _initial_position.y
	_fly_dir = _initial_dir

# ================================================================ 构造
func _build_body() -> void:
	if _shape != null:
		return
	_shape = CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(ENEMY_W, ENEMY_H)
	_shape.shape = rect
	add_child(_shape)

func _build_sprite() -> void:
	_rebuild_sprite("enemy_grunt" if kind == "grunt" else "enemy_flyer", kind != "flyer")

func _rebuild_sprite(entity: String, bottom_align: bool) -> void:
	if _sprite != null:
		_sprite.queue_free()
		_sprite = null
	_sprite = SpriteFactory.make_animated(entity, 8.0)
	var frames: Array = GameConfig.FRAME_GRUNT if entity == "enemy_grunt" else GameConfig.FRAME_FLYER
	_ensure_run_animation(_sprite, frames, 8.0)
	_set_anim_speed(_sprite, 8.0)
	_sprite.scale = Vector2(SPRITE_SCALE, SPRITE_SCALE)
	add_child(_sprite)
	if bottom_align:
		_align_bottom(_sprite)
	_play_run(_sprite)

## 播放 "run" 动画（动画缺失时安全跳过）
func _play_run(spr: AnimatedSprite2D) -> void:
	if spr == null or spr.sprite_frames == null:
		return
	if not spr.sprite_frames.has_animation("run"):
		return
	if spr.sprite_frames.get_frame_count("run") <= 0:
		return
	spr.play("run")

func _set_anim_speed(spr: AnimatedSprite2D, fps: float) -> void:
	if spr == null or spr.sprite_frames == null:
		return
	for anim in spr.sprite_frames.get_animation_names():
		spr.sprite_frames.set_animation_speed(anim, fps)

## 兼容修复：SpriteFactory.make_animated() 目前不会创建 "run" 动画
## （内部 remove_animation("default") 后直接 add_frame("run")，Godot 会报
##  "Animation 'run' doesn't exist"）。这里补建动画并填帧。修复工厂后自动变成空操作。
func _ensure_run_animation(spr: AnimatedSprite2D, frame_files: Array, fps: float) -> void:
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
func _align_bottom(spr: AnimatedSprite2D) -> void:
	var tex_h := 0.0
	if spr.sprite_frames != null and spr.sprite_frames.has_animation("run"):
		if spr.sprite_frames.get_frame_count("run") > 0:
			var tex := spr.sprite_frames.get_frame_texture("run", 0)
			if tex != null:
				tex_h = float(tex.get_height()) * SPRITE_SCALE
	if tex_h <= 0.0:
		return
	spr.position = Vector2(0.0, (tex_h - ENEMY_H) * 0.5)

# ================================================================ 主循环
func _physics_process(delta: float) -> void:
	if not alive:
		return
	if kind == "flyer":
		_tick_flyer(delta)
	else:
		_tick_grunt(delta)
	if _sprite != null:
		_sprite.flip_h = _dir < 0

## 地面敌人：受重力，水平巡逻，遇墙 / 遇悬崖转向
func _tick_grunt(delta: float) -> void:
	velocity.x = _dir * GameConfig.GRUNT_SPEED
	velocity.y = minf(velocity.y + GameConfig.GRUNT_GRAVITY * delta, GameConfig.MAX_FALL)
	move_and_slide()

	# 遇墙转向
	if is_on_wall():
		_dir = -_dir
		velocity.x = _dir * GameConfig.GRUNT_SPEED

	# 悬崖边转向：身体前方 12px 处向下射线，射不到地面就掉头
	if is_on_floor() and not _has_ground_ahead():
		_dir = -_dir
		velocity.x = _dir * GameConfig.GRUNT_SPEED

## 空中敌人：不受重力，水平匀速 + 竖直正弦浮动
func _tick_flyer(delta: float) -> void:
	var omega := GameConfig.FLYER_SPEED_Y / maxf(GameConfig.FLYER_AMP, 1.0)
	_fly_phase += delta * omega
	velocity.x = _fly_dir * GameConfig.FLYER_SPEED
	velocity.y = 0.0
	move_and_slide()
	if is_on_wall():
		_fly_dir = -_fly_dir
		_dir = _fly_dir
		velocity.x = _fly_dir * GameConfig.FLYER_SPEED
	# 竖直方向直接按正弦驱动，避免被地形卡住
	position.y = _fly_base_y + sin(_fly_phase) * GameConfig.FLYER_AMP

## 前方是否有地面（悬崖检测）
func _has_ground_ahead() -> bool:
	var space := get_world_2d().direct_space_state
	if space == null:
		return true
	var from := global_position + Vector2(_dir * CLIFF_RAY_OFFSET, ENEMY_H * 0.5 - 2.0)
	var to := from + Vector2(0.0, CLIFF_RAY_LEN)
	var q := PhysicsRayQueryParameters2D.create(from, to)
	q.exclude = [get_rid()]
	q.collision_mask = 1
	var hit := space.intersect_ray(q)
	return not hit.is_empty()

# ================================================================ 交互
## 被踩：翻车并 emit defeated
func stomp() -> void:
	if not alive:
		return
	alive = false
	set_physics_process(false)
	velocity = Vector2.ZERO
	rotation = PI * 0.5
	modulate = Color(0.7, 0.7, 0.7, 1.0)
	defeated.emit(self)

## 侧面碰到玩家：返回是否命中（伤害由 main 决定）
func hit_player() -> bool:
	return alive

func is_alive() -> bool:
	return alive

## 世界坐标 AABB
func get_rect() -> Rect2:
	return Rect2(
		global_position - Vector2(ENEMY_W, ENEMY_H) * 0.5,
		Vector2(ENEMY_W, ENEMY_H)
	)
