class_name Checkpoint
extends Node2D
##
## 检查点旗：玩家经过时点亮，重生时从这里继续（马里奥式中途存档）。
##
## 位置由关卡的列号给出，旗杆立在地面上：
##   脚底 y = 该列地面表层（GROUND_TOP * TILE）
##   旗中心 y = 脚底 - 旗高/2
##

signal reached(cp: Checkpoint)

const FLAG_H := 32.0          # flag_goal 贴图高度（32px）
const ACTIVE_COLOR := Color(1.0, 0.86, 0.25)   # 点亮：金色
const IDLE_COLOR := Color(0.55, 0.70, 0.95)    # 未点亮：淡蓝

var col: int = 0
var active: bool = false

var _sprite: Sprite2D = null
var _t := 0.0


## 在第 column 列的地面上放一个检查点
func setup(column: int, ground_y: float) -> void:
	col = column
	position = Vector2(float(column * GameConfig.TILE + GameConfig.TILE * 0.5), ground_y - FLAG_H * 0.5)
	_build()


func _build() -> void:
	if _sprite == null:
		_sprite = SpriteFactory.make_static("flag_goal")
		if _sprite == null:
			return
		add_child(_sprite)
	_sprite.modulate = IDLE_COLOR
	_sprite.z_index = 2


## 玩家经过：点亮并广播
func activate() -> void:
	if active:
		return
	active = true
	if _sprite != null:
		_sprite.modulate = ACTIVE_COLOR
	reached.emit(self)


## 重生的脚底坐标（落在地面上）
func get_respawn_point() -> Vector2:
	return Vector2(global_position.x, global_position.y + FLAG_H * 0.5)


## 回到未点亮状态（重新开始游戏时调用）
func reset() -> void:
	active = false
	_t = 0.0
	if _sprite != null:
		_sprite.modulate = IDLE_COLOR
		_sprite.position.y = 0.0


## 与玩家的碰撞盒（比贴图略小，够用即可）
func get_rect() -> Rect2:
	return Rect2(global_position - Vector2(8.0, FLAG_H * 0.5), Vector2(16.0, FLAG_H))


func _process(delta: float) -> void:
	if not active or _sprite == null:
		return
	# 点亮后轻微上下浮动，提示「这里是存档点」
	_t += delta
	_sprite.position.y = sin(_t * 3.0) * 1.5
