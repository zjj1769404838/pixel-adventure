class_name SpriteFactory
extends RefCounted
##
## 精灵工厂：读取 assets/final/meta.json 的帧清单，
## 在运行时构造 AnimatedSprite2D / Sprite2D。全部走代码建场景，不依赖 .tscn 手工引用。
##

static var _cache: Dictionary = {}
static var _meta: Variant = null

static func meta() -> Dictionary:
	if _meta == null:
		var path := "res://assets/sprites/meta.json"
		if FileAccess.file_exists(path):
			var txt := FileAccess.get_file_as_string(path)
			var parsed = JSON.parse_string(txt)
			_meta = parsed if parsed is Dictionary else {}
		else:
			_meta = {}
	return _meta

static func _load_tex(path: String) -> Texture2D:
	if _cache.has(path):
		return _cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path)
	_cache[path] = tex
	return tex

## 实体名 -> 帧文件名数组（从 meta.json 取）
static func frames_of(entity: String) -> Array:
	var m := meta()
	if not m.has(entity):
		return []
	var fm = m[entity].get("frames_meta", [])
	var out := []
	for f in fm:
		out.append(String(f.get("file", "")))
	return out

## 构造 AnimatedSprite2D。entity 为 meta.json 中的实体名。
static func make_animated(entity: String, fps: float = 10.0) -> AnimatedSprite2D:
	var spr := AnimatedSprite2D.new()
	var sf := SpriteFrames.new()
	sf.remove_animation("default")
	sf.add_animation("run")
	var names := frames_of(entity)
	var loaded := 0
	for f in names:
		var path: String = GameConfig.SPRITES + String(f)
		var tex := _load_tex(path)
		if tex == null:
			continue
		sf.add_frame("run", tex)
		loaded += 1
	if loaded == 0:
		# 兜底：manifest 里的常量帧名
		var fallback := _fallback_frames(entity)
		for f in fallback:
			var tex := _load_tex(GameConfig.SPRITES + f)
			if tex == null:
				continue
			sf.add_frame("run", tex)
			loaded += 1
	spr.sprite_frames = sf
	spr.animation = "run"
	spr.frame = 0
	spr.speed_scale = 1.0
	if loaded > 0:
		spr.set_meta("fps", fps)
	return spr

static func _fallback_frames(entity: String) -> Array:
	match entity:
		"hero": return GameConfig.FRAME_HERO
		"hero_jump": return GameConfig.FRAME_HERO_JUMP
		"enemy_grunt": return GameConfig.FRAME_GRUNT
		"enemy_flyer": return GameConfig.FRAME_FLYER
		"pickup_coin": return GameConfig.FRAME_COIN
		"fx_brick": return GameConfig.FRAME_FX_BRICK
	return []

## 构造单帧 Sprite2D。
static func make_static(entity: String) -> Sprite2D:
	var spr := Sprite2D.new()
	var files := frames_of(entity)
	var file := ""
	if files.size() > 0:
		file = String(files[0])
	else:
		match entity:
			"tile_ground": file = GameConfig.TEX_GROUND
			"tile_dirt": file = GameConfig.TEX_DIRT
			"tile_solid": file = GameConfig.TEX_SOLID
			"tile_brick": file = GameConfig.TEX_BRICK
			"tile_question": file = GameConfig.TEX_QUESTION
			"ui_heart": file = GameConfig.TEX_HEART
			"flag_goal": file = GameConfig.TEX_FLAG
			"pickup_mushroom": file = GameConfig.TEX_MUSHROOM
	var tex := _load_tex(GameConfig.SPRITES + file) if file != "" else null
	if tex != null:
		spr.texture = tex
	spr.centered = true
	return spr
