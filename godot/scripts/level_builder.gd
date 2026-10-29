class_name LevelBuilder
extends Node2D
##
## 关卡构建：把 level_data.gd 的 ASCII 网格转成碰撞体、方块、敌人、拾取物。
## 严格遵循 docs/contracts.md §4。
##
## 字符表： '.' 空  '#' 地面  'X' 实心块  'B' 砖  '?' 问号块
##          '=' 单向平台  'P' 出生点  'E' 地面敌人  'F' 飞行敌人
##          'C' 金币  'M' 蘑菇  'G' 终点旗
##

const TILE := GameConfig.TILE

## 是否使用离线烘焙的地形大图（scripts/gen_level_texture.py 生成）。
## 设为 false 或资源缺失时，自动退回逐格建 Sprite2D 的旧逻辑。
const USE_BAKED_TERRAIN := true

## 烘焙地形大图路径。尺寸必须是 LEVEL_COLS*TILE x LEVEL_ROWS*TILE。
const TERRAIN_BAKED_TEX := "res://assets/sprites/level_terrain.png"

# ---- 公开状态（main.gd / smoke_test.gd 依赖）----
var spawn_point: Vector2 = Vector2.ZERO      # 玩家出生「脚底」坐标
var goal_point: Vector2 = Vector2.ZERO       # 终点旗「底部」坐标
var blocks: Dictionary = {}                 # Vector2i(col,row) -> Block
var enemies: Array[Node2D] = []
var pickups: Array[Dictionary] = []

var _terrain_body: StaticBody2D = null
var _terrain_shapes: Array[CollisionShape2D] = []
var _platform_body: StaticBody2D = null
var _platform_shapes: Array[CollisionShape2D] = []
var _visual_root: Node2D = null
var _question_index: int = 0


func build(rows: Array) -> void:
	_clear()
	_visual_root = Node2D.new()
	_visual_root.name = "Visuals"
	add_child(_visual_root)

	_terrain_body = StaticBody2D.new()
	_terrain_body.name = "Terrain"
	_terrain_body.collision_layer = 1
	_terrain_body.collision_mask = 0
	add_child(_terrain_body)

	_platform_body = StaticBody2D.new()
	_platform_body.name = "OneWayPlatforms"
	_platform_body.collision_layer = 1
	_platform_body.collision_mask = 0
	add_child(_platform_body)

	# 视觉层：地形用一张烘焙大图（单 Sprite2D）；资源缺失时退回逐格建
	var baked_ok := false
	if USE_BAKED_TERRAIN:
		baked_ok = _add_baked_terrain()
	if not baked_ok:
		_build_terrain_tiles(rows)
	# 碰撞层：水平连续段合并成矩形
	_build_terrain_collision(rows)

	# 第二遍：方块 / 平台 / 出生点 / 终点 / 敌人 / 拾取物
	for r in rows.size():
		var row: String = str(rows[r])
		for c in row.length():
			match row[c]:
				"B":
					_add_block(c, r, "brick", false)
				"?":
					_add_block(c, r, "question", _question_has_item())
				"=":
					_add_one_way(c, r)
				"P":
					spawn_point = Vector2(float(c * TILE), float((r + 1) * TILE))
				"G":
					goal_point = Vector2(float(c * TILE + TILE / 2), float((r + 1) * TILE))
					_add_goal_flag(c, r)
				"E":
					_add_enemy(c, r, "grunt")
				"F":
					_add_enemy(c, r, "flyer")
				"C":
					_add_pickup(c, r, "coin", "pickup_coin")
				"M":
					_add_pickup(c, r, "mushroom", "pickup_mushroom")


func _clear() -> void:
	blocks.clear()
	enemies.clear()
	pickups.clear()
	_terrain_shapes.clear()
	_platform_shapes.clear()
	for child in get_children():
		child.queue_free()


# ================================================================ 地形
## 水平连续段合并成一个矩形碰撞体（避免一格一个 StaticBody2D）
func _add_terrain_tile(c: int, r: int, tex_entity: String) -> void:
	var center := Vector2(float(c * TILE + TILE / 2), float(r * TILE + TILE / 2))
	var spr := SpriteFactory.make_static(tex_entity)
	spr.position = center
	spr.z_index = 0
	_visual_root.add_child(spr)


## 地形视觉层（兜底路径）：每格地形一个 Sprite2D。
## 仅在烘焙大图缺失时才走这里，节点数约 1000 个。
func _build_terrain_tiles(rows: Array) -> void:
	for r in rows.size():
		var row: String = str(rows[r])
		for c in row.length():
			match row[c]:
				"#":
					_add_terrain_tile(c, r, _ground_tex(rows, c, r))
				"X":
					_add_terrain_tile(c, r, "tile_solid")


## 地形视觉层（首选路径）：一张烘焙大图 = 一个 Sprite2D。
## 贴图由 scripts/gen_level_texture.py 生成，像素与逐格方案完全一致。
## 成功返回 true；资源缺失 / 尺寸不符返回 false，调用方退回逐格方案。
func _add_baked_terrain() -> bool:
	if not ResourceLoader.exists(TERRAIN_BAKED_TEX):
		push_warning("烘焙地形图不存在，回退逐格构建：%s" % TERRAIN_BAKED_TEX)
		return false
	var tex: Texture2D = load(TERRAIN_BAKED_TEX)
	if tex == null:
		push_warning("烘焙地形图加载失败，回退逐格构建：%s" % TERRAIN_BAKED_TEX)
		return false
	var expect := Vector2i(GameConfig.LEVEL_COLS * TILE, GameConfig.LEVEL_ROWS * TILE)
	if tex.get_size() != Vector2(expect):
		push_warning("烘焙地形图尺寸不符（%s），回退逐格构建" % str(tex.get_size()))
		return false
	var spr := Sprite2D.new()
	spr.name = "TerrainBaked"
	spr.texture = tex
	spr.centered = false
	spr.position = Vector2.ZERO
	spr.z_index = 0
	_visual_root.add_child(spr)
	return true


## 地面格子的贴图：暴露在表层的用草皮 tile_ground，被埋在下面的用泥土 tile_dirt
## （烘焙脚本 gen_level_texture.py 的 ground_tex() 与此规则保持一致）
func _ground_tex(rows: Array, c: int, r: int) -> String:
	if r <= 0:
		return "tile_ground"
	var above: String = str(rows[r - 1])
	if c < above.length():
		var ch := above[c]
		if ch == "#" or ch == "X":
			return "tile_dirt"
	return "tile_ground"


## 扫描整张表，把每一行里连续的 # / X 合并成矩形碰撞体
func _build_terrain_collision(rows: Array) -> void:
	for r in rows.size():
		var row: String = str(rows[r])
		var c := 0
		while c < row.length():
			var ch := row[c]
			if ch != "#" and ch != "X":
				c += 1
				continue
			var start := c
			while c < row.length() and row[c] == ch:
				c += 1
			var width := c - start
			var shape := CollisionShape2D.new()
			var rect := RectangleShape2D.new()
			rect.size = Vector2(float(width * TILE), float(TILE))
			shape.shape = rect
			shape.position = Vector2(float(start * TILE + width * TILE / 2), float(r * TILE + TILE / 2))
			_terrain_body.add_child(shape)
			_terrain_shapes.append(shape)


## 单向平台：碰撞形状贴在格子底部，one_way_collision = true，可从下方跳上来
func _add_one_way(c: int, r: int) -> void:
	var spr := SpriteFactory.make_static("tile_solid")
	spr.position = Vector2(float(c * TILE + TILE / 2), float(r * TILE + TILE / 2))
	spr.z_index = 0
	spr.modulate = Color(0.92, 0.82, 0.55)
	_visual_root.add_child(spr)

	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(float(TILE), 6.0)
	shape.shape = rect
	shape.position = Vector2(float(c * TILE + TILE / 2), float(r * TILE + 13))
	shape.one_way_collision = true
	_platform_body.add_child(shape)
	_platform_shapes.append(shape)


# ================================================================ 方块
func _add_block(c: int, r: int, kind: String, has_item: bool) -> void:
	var b := Block.new()
	b.kind = kind
	b.has_item = has_item
	b.col = c
	b.row = r
	b.position = Vector2(float(c * TILE + TILE / 2), float(r * TILE + TILE / 2))
	b.name = "Block_%d_%d" % [c, r]
	add_child(b)
	blocks[Vector2i(c, r)] = b


## 问号块内容：每第 3 个问号块藏蘑菇，其余藏金币
func _question_has_item() -> bool:
	_question_index += 1
	return (_question_index % 3) == 0


# ================================================================ 敌人 / 拾取 / 终点
func _add_enemy(c: int, r: int, kind_name: String) -> void:
	var e := Enemy.new()
	e.kind = kind_name
	e.position = Vector2(float(c * TILE + TILE / 2), float(r * TILE + TILE / 2))
	e.name = "Enemy_%d_%d" % [c, r]
	add_child(e)
	e.setup(kind_name)
	enemies.append(e)


func _add_pickup(c: int, r: int, kind_name: String, entity: String) -> void:
	var pos := Vector2(float(c * TILE + TILE / 2), float(r * TILE + TILE / 2))
	var node: Node2D = null
	if kind_name == "coin":
		var anim := SpriteFactory.make_animated(entity, 10.0)
		if anim.sprite_frames != null:
			for anim_name in anim.sprite_frames.get_animation_names():
				anim.sprite_frames.set_animation_speed(anim_name, 10.0)
		anim.play("run")
		node = anim
	else:
		node = SpriteFactory.make_static(entity)
	node.position = pos
	node.z_index = 2
	node.name = "Pickup_%d_%d" % [c, r]
	add_child(node)
	pickups.append({
		"node": node,
		"kind": kind_name,
		"pos": pos,
		"taken": false,
	})


func _add_goal_flag(c: int, r: int) -> void:
	var spr := SpriteFactory.make_static("flag_goal")
	spr.position = Vector2(float(c * TILE + TILE / 2), float(r * TILE + TILE / 2))
	spr.z_index = 2
	_visual_root.add_child(spr)
