class_name Block
extends StaticBody2D
##
## 砖块 / 问号块：玩家从下方顶到时由 player.gd 调用 hit() 取得反馈。
## 严格遵循 docs/contracts.md §5。
##
##   - kind: "brick" | "question"
##   - hit() 返回 "coin" / "item" / "break" / ""
##   - question 被顶过后 used=true，纹理换成 tile_solid，碰撞体保留
##   - brick 被顶过后返回 "break"，由 main.gd 负责 queue_free（碰撞体随之消失）
##

const TILE := GameConfig.TILE

# ---- 公开状态（main.gd / level_builder.gd 依赖）----
var kind: String = "brick"
var used: bool = false
var has_item: bool = false   # question 是否含物品
var col: int = 0
var row: int = 0

var _sprite: Sprite2D = null

# ================================================================ 生命周期
func _ready() -> void:
	collision_layer = 1          # 地形
	collision_mask = 0           # 静态物体不需要掩码
	_build_body()
	_build_sprite()

func _build_body() -> void:
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(TILE, TILE)
	shape.shape = rect
	add_child(shape)

func _build_sprite() -> void:
	_sprite = SpriteFactory.make_static(_texture_entity())
	if _sprite == null:
		return
	add_child(_sprite)

# ================================================================ 交互
## 玩家从下方顶到时调用。返回值决定反馈：
## "coin" 顶出金币 / "item" 顶出道具 / "break" 砖块碎裂 / "" 无事发生
func hit() -> String:
	if used:
		return ""
	if kind == "brick":
		used = true
		return "break"
	# question：第一次生效，之后变实心
	used = true
	_set_texture("tile_solid")
	return "item" if has_item else "coin"

# ================================================================ 内部
func _texture_entity() -> String:
	match kind:
		"brick":
			return "tile_brick"
		"question":
			return "tile_question"
	return "tile_solid"

func _set_texture(entity: String) -> void:
	if _sprite == null:
		return
	var s := SpriteFactory.make_static(entity)
	if s == null or s.texture == null:
		return
	_sprite.texture = s.texture
