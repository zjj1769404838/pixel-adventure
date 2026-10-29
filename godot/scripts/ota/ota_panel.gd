class_name OtaPanel
extends CanvasLayer
##
## OTA 更新界面（CanvasLayer，layer=120，盖在游戏 UI 之上）。
##
## 界面语言与游戏一致：640x360 设计分辨率、zpix 像素中文字体、纯 Control + Label 构建，
## 不依赖任何外部素材。三种形态：
##   1. 有新版  —— 显示版本号 / 更新内容 / 文件大小 / SHA-256 前 12 位，三个按钮
##   2. 下载中  —— 进度条 + 百分比 + 已下载/总量，可取消
##   3. 失败/结果 —— 原因 + 重试 / 取消 / 手动下载
##
## 键盘：←/→ 或 A/D 切换按钮，Enter/Space 确认，Esc 取消
## 触屏：直接点按钮（按钮 mouse_filter = STOP）
##

signal action_taken(action: String, payload: Dictionary)

const COL_TEXT := Color(1.0, 1.0, 1.0)
const COL_TITLE := Color(1.0, 0.86, 0.25)
const COL_ACCENT := Color(0.35, 0.9, 1.0)
const COL_WARN := Color(1.0, 0.45, 0.35)
const COL_DIM := Color(0.78, 0.84, 0.92)
const COL_BTN := Color(0.16, 0.20, 0.28)
const COL_BTN_SEL := Color(0.28, 0.46, 0.70)

const FS_BODY := 12
const FS_HEAD := 24

var _font: FontFile = null
var _root: Control
var _box: PanelContainer
var _headline: Label
var _lines: Array[Label] = []
var _buttons: Array[Button] = []
var _sel := 0
var _mode := ""

## 当前展示的数据快照（供按钮回传）
var _ctx: Dictionary = {}


func _ready() -> void:
	layer = 120
	_build()
	hide()


func _build() -> void:
	_root = Control.new()
	_root.name = "OtaRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	# 半透明遮罩
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	# 面板
	_box = PanelContainer.new()
	_box.set_anchors_preset(Control.PRESET_CENTER)
	_box.custom_minimum_size = Vector2(520, 240)
	_box.offset_left = -260
	_box.offset_top = -120
	_box.offset_right = 260
	_box.offset_bottom = 120
	_box.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.11, 0.16, 0.98)
	sb.border_color = COL_ACCENT
	sb.set_border_width_all(2)
	sb.set_content_margin_all(10)
	_box.add_theme_stylebox_override("panel", sb)
	_root.add_child(_box)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	_box.add_child(vb)

	_headline = _make_label("", FS_HEAD, COL_TITLE)
	vb.add_child(_headline)

	# 正文行（固定 8 行槽位，避免动态增删导致布局跳动）
	for i in 8:
		var l := _make_label("", FS_BODY, COL_TEXT)
		l.visible = false
		_lines.append(l)
		vb.add_child(l)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	vb.add_child(spacer)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(hb)
	_btn_row = hb


var _btn_row: HBoxContainer


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	if _font != null:
		l.add_theme_font_override("font", _font)
	return l


func setup(font_path: String) -> void:
	if font_path != "" and ResourceLoader.exists(font_path):
		var res := ResourceLoader.load(font_path)
		if res is FontFile:
			_font = res as FontFile
	if _font != null:
		_font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		_font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		_font.hinting = TextServer.HINTING_NONE
		_font.allow_system_fallback = false
	# 重建按钮区的字体（按钮在 _set_buttons 里创建，这里只改已存在的）
	for b in _buttons:
		if _font != null:
			b.add_theme_font_override("font", _font)


# ======================================================================
#  三种形态
# ======================================================================

## 发现新版本
func show_available(m: OtaManifest) -> void:
	_mode = "available"
	_ctx = {
		"version_name": m.version_name,
		"version_code": m.version_code,
		"download_url": m.download_url,
		"release_page": m.release_page,
		"sha256": m.sha256,
		"size_bytes": m.size_bytes,
		"mandatory": m.mandatory,
	}
	_headline.text = "发现新版本 " + m.version_name
	var rows: Array[String] = []
	rows.append("当前版本 " + OtaConfig.current_version() + "  →  最新 " + m.version_name)
	rows.append("安装包大小 " + OtaVersion.human_size(m.size_bytes) + "    发布时间 " + OtaVersion.human_time(m.published_at) + " (UTC)")
	rows.append("SHA-256 " + m.sha256.substr(0, 12) + "…（下载后自动校验）")
	if m.mandatory:
		rows.append("※ 这是强制更新版本，需更新后才能继续游戏")
	if m.changelog.size() == 0:
		rows.append("更新内容：见发布页面")
	else:
		rows.append("更新内容：")
		for i in mini(m.changelog.size(), 3):
			rows.append("  · " + m.changelog[i])
		if m.changelog.size() > 3:
			rows.append("  · …共 %d 条" % m.changelog.size())
	_set_lines(rows)
	if m.mandatory:
		_set_buttons(["立即更新", "退出游戏"])
	else:
		_set_buttons(["立即更新", "稍后提醒", "手动下载"])
	show()


## 下载中
func show_progress(version_name: String, received: int, total: int) -> void:
	_mode = "progress"
	var pct := 0
	if total > 0:
		pct = int(float(received) / float(total) * 100.0)
		_headline.text = "正在下载 " + version_name + "  " + str(pct) + "%"
	else:
		_headline.text = "正在下载 " + version_name
	var rows: Array[String] = []
	rows.append("已下载 " + OtaVersion.human_size(received) + " / " + OtaVersion.human_size(total))
	rows.append(_bar(pct))
	rows.append("下载完成后会自动校验 SHA-256，校验失败不会安装")
	_set_lines(rows)
	_set_buttons(["取消下载"])
	show()


## 校验中
func show_verifying() -> void:
	_mode = "verifying"
	_headline.text = "正在校验安装包"
	_set_lines(["计算 SHA-256 并与版本清单比对…"])
	_set_buttons([])
	show()


## 失败 / 结果
func show_result(headline: String, rows: Array, buttons: Array, ctx: Dictionary = {}) -> void:
	_mode = "result"
	if ctx.size() > 0:
		_ctx = ctx
	_headline.text = headline
	var s: Array[String] = []
	for r in rows:
		s.append(String(r))
	_set_lines(s)
	_set_buttons(buttons)
	show()


func close() -> void:
	hide()
	_mode = ""


func is_open() -> bool:
	return visible


func mode() -> String:
	return _mode


func current_context() -> Dictionary:
	return _ctx


# ======================================================================
#  内部
# ======================================================================

func _set_lines(rows: Array) -> void:
	for i in _lines.size():
		if i < rows.size():
			_lines[i].text = String(rows[i])
			_lines[i].visible = true
		else:
			_lines[i].text = ""
			_lines[i].visible = false


func _set_buttons(labels: Array) -> void:
	for b in _buttons:
		b.queue_free()
	_buttons.clear()
	_sel = 0
	for i in labels.size():
		var b := Button.new()
		b.text = String(labels[i])
		b.custom_minimum_size = Vector2(120, 26)
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", FS_BODY)
		if _font != null:
			b.add_theme_font_override("font", _font)
		var idx := i
		b.pressed.connect(func() -> void: _fire(idx))
		_btn_row.add_child(b)
		_buttons.append(b)
	_refresh_sel()


func _refresh_sel() -> void:
	for i in _buttons.size():
		var b := _buttons[i]
		var sb := StyleBoxFlat.new()
		sb.bg_color = COL_BTN_SEL if i == _sel else COL_BTN
		sb.border_color = COL_ACCENT if i == _sel else Color(0.35, 0.4, 0.5)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(2)
		sb.set_content_margin_all(4)
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
		b.add_theme_stylebox_override("pressed", sb)
		b.add_theme_color_override("font_color", COL_TEXT)


func _fire(idx: int) -> void:
	if idx < 0 or idx >= _buttons.size():
		return
	var label := _buttons[idx].text
	action_taken.emit(_key_for(label), _ctx)


## 按钮文案 → 语义化 action（界面与逻辑解耦，改文案不影响逻辑）
func _key_for(label: String) -> String:
	match label:
		"立即更新", "立即下载":
			return "update"
		"立即安装":
			return "install"
		"去授权":
			return "grant"
		"稍后安装", "稍后提醒":
			return "later"
		"手动下载":
			return "manual"
		"取消下载", "取消":
			return "cancel"
		"重试", "重新下载":
			return "retry"
		"退出游戏":
			return "quit"
		"完成", "知道了":
			return "dismiss"
		_:
			return "dismiss"


## 文本进度条（不引入 ProgressBar，保持像素风一致性）
func _bar(pct: int) -> String:
	var n := 24
	var filled := clampi(int(float(pct) / 100.0 * float(n)), 0, n)
	var s := ""
	for i in n:
		s += "█" if i < filled else "░"
	return s


func _process(_delta: float) -> void:
	if not visible or _buttons.size() == 0:
		return
	if Input.is_action_just_pressed("ui_left"):
		_sel = (_sel - 1 + _buttons.size()) % _buttons.size()
		_refresh_sel()
	elif Input.is_action_just_pressed("ui_right"):
		_sel = (_sel + 1) % _buttons.size()
		_refresh_sel()
	elif Input.is_action_just_pressed("ui_accept"):
		_fire(_sel)
	elif Input.is_action_just_pressed("ui_cancel"):
		# Esc 等价于最后一个按钮（通常是取消/稍后）
		_fire(_buttons.size() - 1)
