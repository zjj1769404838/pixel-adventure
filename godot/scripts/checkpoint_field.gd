class_name CheckpointField
extends Node2D
##
## 检查点集合：关卡中途存档（马里奥式旗帜）。
##
## 玩法：
##   - 玩家经过未点亮的检查点 → 点亮（金色）并记录；
##   - 掉坑重生时从**最近点亮的检查点**继续，而不是回到关卡开头；
##   - 一个检查点都没点亮过 → 回到出生点。
##

var checkpoints: Array[Checkpoint] = []
var _last_active: Checkpoint = null


## 在关卡里布置所有检查点（列号取自 GameConfig.CHECKPOINT_COLS）
func build() -> void:
	for c in GameConfig.CHECKPOINT_COLS:
		var cp := Checkpoint.new()
		cp.name = "Checkpoint_%d" % c
		add_child(cp)
		cp.setup(c, GameConfig.CHECKPOINT_GROUND_Y)
		checkpoints.append(cp)


## 每帧调用：检测玩家是否经过某个检查点
func update_player(player_rect: Rect2) -> void:
	for cp in checkpoints:
		if cp == null or not is_instance_valid(cp):
			continue
		if cp.active:
			continue
		if cp.get_rect().intersects(player_rect):
			cp.activate()
			_last_active = cp


## 当前应该重生的脚底坐标
func get_respawn_point(fallback: Vector2) -> Vector2:
	if _last_active != null and is_instance_valid(_last_active) and _last_active.active:
		return _last_active.get_respawn_point()
	return fallback


## 是否已经点亮过至少一个检查点
func has_active() -> bool:
	return _last_active != null and is_instance_valid(_last_active) and _last_active.active


## 全部复位为未点亮（重新开始游戏时调用）
func reset() -> void:
	_last_active = null
	for cp in checkpoints:
		if cp != null and is_instance_valid(cp):
			cp.active = false
			if cp.has_method("reset"):
				cp.call("reset")
