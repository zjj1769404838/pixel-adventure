class_name GameUI
extends CanvasLayer
##
## 界面层：标题 / HUD / 暂停 / 胜利 / 失败 五套界面，全部用 Control + Label 构建，
## 像素中文字体统一走 setup() 里加载的 zpix.ttf。
##
## 设计分辨率 640x360（GameConfig.VIEW_W / VIEW_H），所有界面锚点居中。

# ---- 配色 ----
const COL_TEXT := Color(1.0, 1.0, 1.0)
const COL_TITLE := Color(1.0, 0.86, 0.25)     # 标题黄
const COL_ACCENT := Color(0.35, 0.9, 1.0)     # 提示青
const COL_DIM := Color(1.0, 1.0, 1.0, 0.35)   # 空血格
const COL_OUTLINE := Color(0.0, 0.0, 0.0, 1.0)

# ---- 字号（zpix.ttf 是 12px 点阵字体，只用 12 / 24 整数倍，保证点阵清晰） ----
const FS_BODY := 12
const FS_HEAD := 24

# ---- 布局常量 ----
const HUD_LEFT := 6.0
const HUD_ROW := 18.0
const HUD_TOP := 2.0
const HEART_GAP := 18.0

var _font: FontFile = null
var _labels: Array[Label] = []

# ---- 五个界面根节点 ----
var title_root: Control
var hud_root: Control
var pause_root: Control
var win_root: Control
var lose_root: Control

# ---- HUD 部件 ----
var _coin_label: Label
var _score_label: Label
var _time_label: Label
var _hint_label: Label
var _hearts: Array[Sprite2D] = []

# ---- 标题界面闪烁部件 ----
var _title_blink: Label
var _blink_t := 0.0

# ---- 结果界面统计标签 ----
var _win_stats: Array[Label] = []
var _lose_stats: Array[Label] = []


func _ready() -> void:
	layer = 100
	_build_ui()


# ======================================================================
#  构建
# ======================================================================

func _build_ui() -> void:
	title_root = _make_root("TitleRoot")
	hud_root = _make_root("HudRoot")
	pause_root = _make_root("PauseRoot")
	win_root = _make_root("WinRoot")
	lose_root = _make_root("LoseRoot")

	_build_title()
	_build_hud()
	_build_pause()
	_build_result(win_root, "通关！")
	_build_result(lose_root, "失败")

	hide_all()


## 全屏 Control（锚点铺满视口）
func _make_root(node_name: String) -> Control:
	var c := Control.new()
	c.name = node_name
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.offset_left = 0.0
	c.offset_top = 0.0
	c.offset_right = 0.0
	c.offset_bottom = 0.0
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.z_index = 100
	add_child(c)
	return c


## 居中 Label：水平铺满宽度并居中对齐，垂直锚在视口中心线的 y 处
func _make_center_label(parent: Control, text: String, font_size: int, color: Color, y: float) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.anchor_left = 0.0
	l.anchor_right = 1.0
	l.offset_left = 0.0
	l.offset_right = 0.0
	# 绝对定位：anchor 固定在视口左上角，offset 用视口绝对坐标
	l.anchor_top = 0.0
	l.anchor_bottom = 0.0
	var row_h := float(font_size) + 12.0
	l.offset_top = y - row_h * 0.5
	l.offset_bottom = y + row_h * 0.5
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_style(l, font_size, color)
	parent.add_child(l)
	return l


## 左上角 Label（HUD 用）
func _make_topleft_label(parent: Control, text: String, font_size: int, color: Color, x: float, y: float) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.anchor_left = 0.0
	l.anchor_right = 0.0
	l.anchor_top = 0.0
	l.anchor_bottom = 0.0
	l.offset_left = x
	l.offset_right = x + 240.0
	l.offset_top = y
	l.offset_bottom = y + float(font_size) + 6.0
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_style(l, font_size, color)
	parent.add_child(l)
	return l


## 定宽 Label（左对齐 / 右对齐，用于按键说明表的两列）
func _make_box_label(parent: Control, text: String, font_size: int, color: Color,
		x: float, y: float, w: float, align: int) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.anchor_left = 0.0
	l.anchor_right = 0.0
	l.anchor_top = 0.0
	l.anchor_bottom = 0.0
	l.offset_left = x
	l.offset_right = x + w
	l.offset_top = y
	l.offset_bottom = y + float(font_size) + 6.0
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_style(l, font_size, color)
	parent.add_child(l)
	return l


func _style(l: Label, font_size: int, color: Color) -> void:
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", COL_OUTLINE)
	l.add_theme_constant_override("outline_size", 3 if font_size >= FS_HEAD else 2)
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", font_size)
	_labels.append(l)


# ======================================================================
#  各界面
# ======================================================================

func _build_title() -> void:
	_make_center_label(title_root, "像素冒险", FS_HEAD, COL_TITLE, 56.0)
	_make_center_label(title_root, "横版像素平台跳跃", FS_BODY, COL_ACCENT, 88.0)
	_title_blink = _make_center_label(title_root, "按 空格 / 回车 开始", FS_BODY, COL_TEXT, 132.0)

	_make_center_label(title_root, "操作说明", FS_BODY, COL_TITLE, 168.0)

	var rows := [
		["← → / A D", "移动"],
		["空格 / ↑ / W", "跳跃"],
		["Shift / X", "加速跑"],
		["P / ESC", "暂停"],
		["R", "重新开始"],
		["U", "检查更新"],
	]
	var y := 190.0
	for r in rows:
		var keys: String = r[0]
		var desc: String = r[1]
		_make_box_label(title_root, keys, FS_BODY, COL_ACCENT, 168.0, y, 190.0, HORIZONTAL_ALIGNMENT_RIGHT)
		_make_box_label(title_root, desc, FS_BODY, COL_TEXT, 366.0, y, 180.0, HORIZONTAL_ALIGNMENT_LEFT)
		y += 20.0


func _build_hud() -> void:
	_coin_label = _make_topleft_label(hud_root, "金币 x00", FS_BODY, COL_TITLE, HUD_LEFT, HUD_TOP)
	_score_label = _make_topleft_label(hud_root, "分数 x0000", FS_BODY, COL_TEXT, HUD_LEFT, HUD_TOP + HUD_ROW)
	_time_label = _make_topleft_label(hud_root, "时间 000", FS_BODY, COL_ACCENT, HUD_LEFT, HUD_TOP + HUD_ROW * 2.0)

	# 生命：ui_heart 精灵横排，最多 GameConfig.MAX_HP 个
	for i in GameConfig.MAX_HP:
		var spr := SpriteFactory.make_static("ui_heart")
		spr.position = Vector2(HUD_LEFT + 8.0 + float(i) * HEART_GAP, HUD_TOP + HUD_ROW * 3.0 + 9.0)
		hud_root.add_child(spr)
		_hearts.append(spr)

	# 屏幕中部下方的一行提示
	_hint_label = _make_center_label(hud_root, "", FS_BODY, COL_ACCENT, float(GameConfig.VIEW_H) - 42.0)
	_hint_label.visible = false


func _build_pause() -> void:
	_make_center_label(pause_root, "已暂停", FS_HEAD, COL_TITLE, 108.0)
	_make_center_label(pause_root, "按 P / ESC 继续", FS_BODY, COL_TEXT, 150.0)
	_make_center_label(pause_root, "按 R 重新开始", FS_BODY, COL_TEXT, 174.0)
	_make_center_label(pause_root, "游戏中可点亮旗帜存档，掉坑后从旗帜继续", FS_BODY, COL_DIM, 208.0)


func _build_result(root: Control, headline: String) -> void:
	_make_center_label(root, headline, FS_HEAD, COL_TITLE, 88.0)
	var stats: Array[Label] = [
		_make_center_label(root, "分数 0", FS_BODY, COL_TEXT, 126.0),
		_make_center_label(root, "金币 0", FS_BODY, COL_TEXT, 150.0),
		_make_center_label(root, "时间 0", FS_BODY, COL_TEXT, 174.0),
	]
	_make_center_label(root, "按 R 重新开始", FS_BODY, COL_ACCENT, 218.0)
	if root == win_root:
		_win_stats = stats
	else:
		_lose_stats = stats


# ======================================================================
#  字体
# ======================================================================

## 加载像素中文字体。
## 首选 ResourceLoader.load()（Godot 会把 zpix.ttf 自动导入成 FontFile 资源，最稳）；
## 失败则退回 FontFile.load_dynamic_font()；再失败直接读字节写入 FontFile.data，
## 三条路都能保证字体真正生效。
func setup(font_path: String) -> void:
	_font = _load_font(font_path)
	if _font != null:
		# 像素风：关闭抗锯齿与次像素定位，保持硬边缘
		_font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		_font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		_font.hinting = TextServer.HINTING_NONE
		_font.allow_system_fallback = false
	for l in _labels:
		if _font != null:
			l.add_theme_font_override("font", _font)


func _load_font(font_path: String) -> FontFile:
	if font_path == "":
		return null

	# 方案一：走资源导入管线（zpix.ttf 已被导入为 FontFile）
	if ResourceLoader.exists(font_path):
		var res := ResourceLoader.load(font_path)
		if res is FontFile:
			return res as FontFile

	# 方案二：FontFile.load_dynamic_font()
	var f := FontFile.new()
	if f.load_dynamic_font(font_path) == OK:
		return f

	# 方案三：读原始字节写入 data
	if FileAccess.file_exists(font_path):
		var bytes := FileAccess.get_file_as_bytes(font_path)
		if bytes.size() > 0:
			var f2 := FontFile.new()
			f2.data = bytes
			return f2
	return null


# ======================================================================
#  界面切换
# ======================================================================

func show_title() -> void:
	_hide_all_roots()
	title_root.visible = true


func show_hud() -> void:
	_hide_all_roots()
	hud_root.visible = true


func show_pause() -> void:
	_hide_all_roots()
	pause_root.visible = true


func show_win(score: int, coins: int, time_sec: int) -> void:
	_hide_all_roots()
	_set_result_stats(win_root, score, coins, time_sec)
	win_root.visible = true


func show_lose(score: int, coins: int, time_sec: int) -> void:
	_hide_all_roots()
	_set_result_stats(lose_root, score, coins, time_sec)
	lose_root.visible = true


func hide_all() -> void:
	_hide_all_roots()
	if _hint_label != null:
		_hint_label.visible = false


func _hide_all_roots() -> void:
	for c in [title_root, hud_root, pause_root, win_root, lose_root]:
		if c != null:
			c.visible = false


## 更新胜利/失败界面的三行统计
func _set_result_stats(root: Control, score: int, coins: int, time_sec: int) -> void:
	var stats: Array[Label] = _win_stats if root == win_root else _lose_stats
	if stats.size() < 3:
		return
	stats[0].text = "分数 %d" % score
	stats[1].text = "金币 %d" % coins
	stats[2].text = "时间 %d" % time_sec


# ======================================================================
#  HUD 数据
# ======================================================================

func set_score(score: int) -> void:
	if _score_label != null:
		_score_label.text = "分数 x%04d" % maxi(score, 0)


func set_coins(coins: int) -> void:
	if _coin_label != null:
		_coin_label.text = "金币 x%02d" % maxi(coins, 0)


func set_time(sec: int) -> void:
	if _time_label != null:
		_time_label.text = "时间 %03d" % maxi(sec, 0)


func set_hp(hp: int, max_hp: int) -> void:
	var cap := maxi(max_hp, GameConfig.MAX_HP)
	for i in _hearts.size():
		var spr := _hearts[i]
		if i < cap:
			spr.visible = true
			spr.modulate = COL_TEXT if i < hp else COL_DIM
		else:
			spr.visible = false


func set_hint(text: String) -> void:
	if _hint_label == null:
		return
	if text.strip_edges() == "":
		_hint_label.visible = false
		_hint_label.text = ""
	else:
		_hint_label.text = text
		_hint_label.visible = true


# ======================================================================
#  闪烁
# ======================================================================

func _process(delta: float) -> void:
	if _title_blink == null or not title_root.visible:
		return
	_blink_t += delta
	_title_blink.self_modulate.a = 0.35 + 0.65 * (0.5 + 0.5 * sin(_blink_t * 4.0))
