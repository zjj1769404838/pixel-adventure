class_name TouchControls
extends CanvasLayer
##
## 触屏虚拟控制：左下角虚拟摇杆 + 右侧跳跃/暂停/重启按钮。
##
## 设计要点：
## - 全部控件用代码绘制（Polygon2D 多边形近似圆，纯色 + 黑描边），零外部素材。
## - 摇杆死区 15%：位移小于死区时输出 0，避免手指轻微抖动导致角色漂移。
## - 多指追踪：用 event.index 区分手指，拖摇杆与点跳跃互不干扰。
## - 抬起立即归零：摇杆回中、按钮释放，不留残留输入。
## - 桌面端可用鼠标驱动（左半屏 = 摇杆，右半屏 = 跳跃）方便调试；
##   桌面且没有任何触摸/鼠标输入时隐藏控件，不遮挡标题界面观感。
## - 只有 set_enabled(true) 时才响应玩法输入；标题/暂停/结算由 main.gd 关掉并清零。
## - 非 PLAY 状态下按屏幕 = 开始 / 继续 / 重开（移动端没有键盘，必须有屏幕入口）。
##

const DEBUG_FORCE_SHOW := false

# ---- 摇杆 ----
const STICK_CENTER := Vector2(64.0, 296.0)
const STICK_VISUAL_RADIUS := 32.0     # 可视半径 / 摇杆最大位移
const STICK_TOUCH_RADIUS := 44.0       # 触区半径
const STICK_DEADZONE := 0.15           # 死区 15%
const STICK_KNOB_RADIUS := 15.0

# ---- 跳跃（大圆，热区 >= 44px）----
const JUMP_CENTER := Vector2(566.0, 296.0)
const JUMP_VISUAL_RADIUS := 26.0
const JUMP_TOUCH_RADIUS := 44.0

# ---- 暂停 / 重启（小圆）----
const PAUSE_CENTER := Vector2(612.0, 212.0)
const RESTART_CENTER := Vector2(612.0, 156.0)
const SMALL_VISUAL_RADIUS := 14.0
const SMALL_TOUCH_RADIUS := 22.0

const POINTER_MOUSE := -1

# 非 PLAY 状态的屏幕点击行为
const TAP_NONE := 0
const TAP_START := 1
const TAP_RESUME := 2
const TAP_RESTART := 3

const ROLE_NONE := &""
const ROLE_STICK := &"stick"
const ROLE_JUMP := &"jump"
const ROLE_PAUSE := &"pause"
const ROLE_RESTART := &"restart"

const COL_EDGE := Color(0.0, 0.0, 0.0, 0.85)
const COL_STICK := Color(1.0, 1.0, 1.0, 0.16)
const COL_KNOB := Color(1.0, 1.0, 1.0, 0.60)
const COL_JUMP := Color(0.93, 0.33, 0.24, 0.55)
const COL_JUMP_ON := Color(1.0, 0.62, 0.40, 0.85)
const COL_PAUSE := Color(0.36, 0.62, 0.92, 0.55)
const COL_RESTART := Color(0.44, 0.78, 0.44, 0.55)

var hub: InputHub
var enabled := false

var _pad: Node2D
var _stick_knob: Polygon2D
var _jump_fill: Polygon2D
var _pause_fill: Polygon2D
var _restart_fill: Polygon2D

var _pointers := {}       # pointer index -> role
var _axis := 0.0          # 当前水平轴 -1 / 0 / +1
var _input_seen := false  # 是否已经收到过触摸/鼠标输入（桌面隐藏判定）
var _touch_seen := false  # 是否收到过真实触摸事件（之后忽略鼠标模拟事件）
var _tap_mode := TAP_NONE # 非 PLAY 状态下的屏幕点击行为

# ---------------------------------------------------------------- 初始化
## 绑定输入层并生成控件图形。
## font_path 为空时用引擎默认字体（仅用于按钮上的 ASCII 标签）。
func setup(input_hub: InputHub, font_path: String = "") -> void:
	hub = input_hub
	layer = 10
	set_process_input(true)

	_pad = Node2D.new()
	_pad.name = "Pad"
	add_child(_pad)

	var font: Font = null
	if font_path != "" and ResourceLoader.exists(font_path):
		font = load(font_path)

	_add_disc(STICK_CENTER, STICK_VISUAL_RADIUS, COL_STICK)
	_stick_knob = _add_disc(STICK_CENTER, STICK_KNOB_RADIUS, COL_KNOB)
	_jump_fill = _add_disc(JUMP_CENTER, JUMP_VISUAL_RADIUS, COL_JUMP)
	_pause_fill = _add_disc(PAUSE_CENTER, SMALL_VISUAL_RADIUS, COL_PAUSE)
	_restart_fill = _add_disc(RESTART_CENTER, SMALL_VISUAL_RADIUS, COL_RESTART)

	_add_label("JUMP", JUMP_CENTER, font)
	_add_label("II", PAUSE_CENTER, font)
	_add_label("R", RESTART_CENTER, font)

	_refresh_visibility()

## 画一个「黑描边 + 半透明纯色填充」的圆（16 边形近似，像素风无抗锯齿）。
func _add_disc(center: Vector2, radius: float, fill: Color) -> Polygon2D:
	var edge := Polygon2D.new()
	edge.polygon = _disc_points(radius + 2.0)
	edge.color = COL_EDGE
	edge.position = center
	_pad.add_child(edge)

	var body := Polygon2D.new()
	body.polygon = _disc_points(radius)
	body.color = fill
	body.position = center
	_pad.add_child(body)
	return body

func _disc_points(radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var segments := 16
	for i in segments:
		var a := TAU * float(i) / float(segments)
		pts.append(Vector2(cos(a), sin(a)) * radius)
	return pts

func _add_label(text: String, center: Vector2, font: Font) -> void:
	var l := Label.new()
	l.text = text
	l.size = Vector2(72.0, 16.0)
	l.position = center - Vector2(36.0, 8.0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font != null:
		l.add_theme_font_override("font", font)
	l.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.9))
	l.add_theme_constant_override("outline_size", 3)
	l.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	_pad.add_child(l)

# ---------------------------------------------------------------- 开关
## 只在 State.PLAY 时启用；关闭时隐藏控件并把所有虚拟输入清零。
func set_enabled(value: bool) -> void:
	if enabled == value:
		return
	enabled = value
	if not enabled:
		_clear_all()
	_refresh_visibility()

## 非 PLAY 状态下的屏幕点击行为：TAP_START / TAP_RESUME / TAP_RESTART / TAP_NONE。
func set_tap_mode(mode: int) -> void:
	_tap_mode = mode

func is_shown() -> bool:
	return _pad != null and _pad.visible

func _refresh_visibility() -> void:
	var show_pad := enabled and (DEBUG_FORCE_SHOW or DisplayServer.is_touchscreen_available() or _input_seen)
	if _pad != null:
		_pad.visible = show_pad

## 抬起 / 禁用时把所有虚拟输入归零，避免角色在暂停时还在跑。
func _clear_all() -> void:
	_pointers.clear()
	_reset_stick()
	if _jump_fill != null:
		_jump_fill.color = COL_JUMP
	if hub != null:
		hub.set_virtual(InputHub.JUMP, false)
		hub.set_virtual(InputHub.LEFT, false)
		hub.set_virtual(InputHub.RIGHT, false)
		hub.set_virtual(InputHub.PAUSE, false)
		hub.set_virtual(InputHub.RESTART, false)

func _reset_stick() -> void:
	if _stick_knob != null:
		_stick_knob.position = STICK_CENTER
	_set_axis(0.0)

# ---------------------------------------------------------------- 输入
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var te := event as InputEventScreenTouch
		if not _touch_seen:
			_touch_seen = true
			# 触屏设备的触摸会被模拟成鼠标事件，清掉可能残留的鼠标指针。
			if _pointers.has(POINTER_MOUSE):
				_end_pointer(POINTER_MOUSE)
		_input_seen = true
		if te.pressed:
			_begin_pointer(te.index, te.position, false)
		else:
			_end_pointer(te.index)
	elif event is InputEventScreenDrag:
		var de := event as InputEventScreenDrag
		_input_seen = true
		_move_pointer(de.index, de.position)
	elif event is InputEventMouseButton:
		# 触屏设备（或已见过真实触摸）上忽略鼠标事件，避免同一根手指被处理两次。
		if DisplayServer.is_touchscreen_available() or _touch_seen:
			return
		var me := event as InputEventMouseButton
		if me.button_index != MOUSE_BUTTON_LEFT:
			return
		_input_seen = true
		if me.pressed:
			_begin_pointer(POINTER_MOUSE, me.position, true)
		else:
			_end_pointer(POINTER_MOUSE)
	elif event is InputEventMouseMotion:
		if DisplayServer.is_touchscreen_available() or _touch_seen:
			return
		var mm := event as InputEventMouseMotion
		if (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			return
		_input_seen = true
		_move_pointer(POINTER_MOUSE, mm.position)

func _begin_pointer(index: int, pos: Vector2, from_mouse: bool) -> void:
	if not enabled:
		_apply_tap_mode()
		return
	if _pointers.has(index):
		return
	var role := _role_at(pos, from_mouse)
	if role == ROLE_NONE:
		return
	_pointers[index] = role
	_apply_role(role, true)
	_refresh_visibility()

func _end_pointer(index: int) -> void:
	var role: StringName = _pointers.get(index, ROLE_NONE)
	if role == ROLE_NONE:
		return
	_pointers.erase(index)
	# 同一角色可能有多根手指（如双手点跳跃），只有最后一根抬起才释放。
	for k in _pointers.keys():
		if _pointers[k] == role:
			return
	_apply_role(role, false)

func _move_pointer(index: int, pos: Vector2) -> void:
	var role: StringName = _pointers.get(index, ROLE_NONE)
	if role != ROLE_STICK:
		return
	var delta := pos - STICK_CENTER
	if delta.length() > STICK_VISUAL_RADIUS:
		delta = delta.normalized() * STICK_VISUAL_RADIUS
	if _stick_knob != null:
		_stick_knob.position = STICK_CENTER + delta
	var nx := delta.x / STICK_VISUAL_RADIUS
	if nx > STICK_DEADZONE:
		_set_axis(1.0)
	elif nx < -STICK_DEADZONE:
		_set_axis(-1.0)
	else:
		_set_axis(0.0)

## 命中判定：按钮按精确热区；触摸只认摇杆热区，鼠标额外支持左右半屏。
func _role_at(pos: Vector2, from_mouse: bool) -> StringName:
	if pos.distance_to(JUMP_CENTER) <= JUMP_TOUCH_RADIUS:
		return ROLE_JUMP
	if pos.distance_to(PAUSE_CENTER) <= SMALL_TOUCH_RADIUS:
		return ROLE_PAUSE
	if pos.distance_to(RESTART_CENTER) <= SMALL_TOUCH_RADIUS:
		return ROLE_RESTART
	if from_mouse:
		if pos.x < GameConfig.VIEW_W * 0.5:
			return ROLE_STICK
		return ROLE_JUMP
	if pos.distance_to(STICK_CENTER) <= STICK_TOUCH_RADIUS:
		return ROLE_STICK
	return ROLE_NONE

func _apply_role(role: StringName, down: bool) -> void:
	match role:
		ROLE_STICK:
			if not down:
				_reset_stick()
		ROLE_JUMP:
			if _jump_fill != null:
				_jump_fill.color = COL_JUMP_ON if down else COL_JUMP
			if hub != null:
				hub.set_virtual(InputHub.JUMP, down)
		ROLE_PAUSE:
			if hub != null:
				hub.set_virtual(InputHub.PAUSE, down)
		ROLE_RESTART:
			if hub != null:
				hub.set_virtual(InputHub.RESTART, down)

## 非 PLAY 状态下按屏幕：开始 / 继续 / 重开。
func _apply_tap_mode() -> void:
	if hub == null:
		return
	match _tap_mode:
		TAP_START:
			hub.set_virtual(InputHub.CONFIRM, true)
			hub.set_virtual(InputHub.CONFIRM, false)
		TAP_RESUME:
			hub.set_virtual(InputHub.PAUSE, true)
			hub.set_virtual(InputHub.PAUSE, false)
		TAP_RESTART:
			hub.set_virtual(InputHub.RESTART, true)
			hub.set_virtual(InputHub.RESTART, false)
		_:
			pass

## 水平轴输出：-1 / 0 / +1，写入 InputHub 的 LEFT / RIGHT。
func _set_axis(value: float) -> void:
	if absf(value - _axis) < 0.001:
		return
	_axis = value
	if hub != null:
		hub.set_virtual(InputHub.RIGHT, value > 0.0)
		hub.set_virtual(InputHub.LEFT, value < 0.0)
