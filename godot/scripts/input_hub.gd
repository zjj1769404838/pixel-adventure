class_name InputHub
extends Node
##
## 统一输入层：把键盘按键映射为抽象动作，供玩家/敌人/UI 读取。
## 只负责「按下/松开/边沿」三种语义，不做任何物理判断。
##

signal action_pressed(action: StringName)
signal action_released(action: StringName)

const LEFT := &"left"
const RIGHT := &"right"
const JUMP := &"jump"
const RUN := &"run"
const PAUSE := &"pause"
const RESTART := &"restart"
const CONFIRM := &"confirm"
const CHECK_UPDATE := &"check_update"

# 动作 -> 物理键位列表（支持方向键 + WASD 双套）
const BINDINGS := {
	LEFT: [KEY_LEFT, KEY_A],
	RIGHT: [KEY_RIGHT, KEY_D],
	JUMP: [KEY_SPACE, KEY_UP, KEY_W, KEY_Z],
	RUN: [KEY_SHIFT, KEY_X],
	PAUSE: [KEY_ESCAPE, KEY_P],
	RESTART: [KEY_R],
	CONFIRM: [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER],
	CHECK_UPDATE: [KEY_U],
}

var _held := {}          # action -> bool
var _pressed_frame := {} # action -> int（按下时的帧号，仅用于调试）
var _pending := {}       # action -> bool（按下后未被消费，等待 just_pressed 取走）
var _simulated := {}     # action -> bool：由脚本注入的按键（poll 不覆盖其状态）
var _virtual := {}       # action -> bool：虚拟输入（触屏摇杆/按钮），与物理输入取或

func _ready() -> void:
	for a in BINDINGS.keys():
		_held[a] = false
		_pressed_frame[a] = -1
	set_process_unhandled_input(true)

## 注入一次「按住 / 松开」某个动作（供自动化测试与回放使用）。
## 被注入的动作不会被 poll() 的物理键轮询覆盖。
func set_simulated(action: StringName, down: bool) -> void:
	_simulated[action] = down
	if down:
		_press(action)
	else:
		_release(action)

## 写入虚拟输入（触屏摇杆 / 虚拟按钮）。
## 与物理按键取或：桌面按住键盘同键仍然有效，两路互不覆盖。
func set_virtual(action: StringName, down: bool) -> void:
	_virtual[action] = down
	if down:
		_press(action)
	elif not _physical_down(action):
		_release(action)

## 该动作当前是否有物理按键被按住。
func _physical_down(action: StringName) -> bool:
	var keys: Array = BINDINGS.get(action, [])
	for key in keys:
		if Input.is_physical_key_pressed(key):
			return true
	return false

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	for action in BINDINGS.keys():
		if event is InputEventKey and event.physical_keycode in BINDINGS[action]:
			_press(action)

func _press(action: StringName) -> void:
	if _held.get(action, false):
		return
	_held[action] = true
	_pressed_frame[action] = Engine.get_process_frames()
	_pending[action] = true
	action_pressed.emit(action)

func _release(action: StringName) -> void:
	if not _held.get(action, false):
		return
	_held[action] = false
	action_released.emit(action)

## 物理按键抬起（Input 状态轮询版，_process 里统一处理）
## 虚拟输入与物理输入取或：任一路按下即视为按下。
func poll() -> void:
	for action in BINDINGS.keys():
		if _simulated.get(action, false):
			continue
		var down := _physical_down(action)
		if _virtual.get(action, false):
			down = true
		if down and not _held.get(action, false):
			_press(action)
		elif not down and _held.get(action, false):
			_release(action)

func is_held(action: StringName) -> bool:
	return _held.get(action, false)

## 边沿检测：按下后返回 true 一次，随后自动复位。
## 用「待消费标志」而不是帧号比较 —— 无头测试里物理帧与渲染帧不同步，
## 帧号比较会漏掉在两帧之间注入的按键。
func just_pressed(action: StringName) -> bool:
	if _pending.get(action, false):
		_pending[action] = false
		return true
	return false

## 水平输入轴：-1 / 0 / +1
func axis_x() -> float:
	var v := 0.0
	if is_held(LEFT):
		v -= 1.0
	if is_held(RIGHT):
		v += 1.0
	return v
