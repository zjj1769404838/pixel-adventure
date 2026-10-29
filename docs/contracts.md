# 像素冒险 — 模块接口契约（所有并行开发者必须严格遵守）

工程根：`D:\my-projects\games\game-4`
Godot 4.7.2，2D，640x360 画布，tile=16，物理 60Hz。

## 0. 公共约定

- GDScript，全部使用 `class_name` 暴露类型；`extends Node` / `extends CharacterBody2D`。
- 常量一律从 `GameConfig` 读取，**不要**在各自脚本里另写魔法数字。
- 输入一律从 `InputHub` 读取，**不要**直接调用 `Input.is_action_pressed`。
- 精灵一律用 `SpriteFactory.make_animated/make_static` 构造，**不要**手写 `load()` 路径。
- 音效一律用 `GameConfig.SFX_DIR` 拼接路径。
- 碰撞层：1 = 地形(solid)，2 = 玩家，4 = 敌人。
  - 玩家 collision_layer=2, collision_mask=1
  - 敌人 collision_layer=4, collision_mask=1
  - 玩家与敌人**不通过物理层互相碰撞**（由 main 手动 AABB 判定，见 §5）。
- 坐标：第 `col` 列第 `row` 行的格子左上角 = `Vector2(col*16, row*16)`，Y 向下。
  地面表层 y = 18*16 = 288。玩家 P 在 (3,17) → 出生点 feet y=288，x=48。
  终点 G 在 (202,15) → 旗杆底部 y=16*16=256，x=202*16=3232。

## 1. GameConfig（已有，只读）
`godot/scripts/game_config.gd` — 见文件。常量含 TILE/VIEW_W/VIEW_H/LEVEL_ROWS/LEVEL_COLS/
GROUND_TOP/WORLD_W/WORLD_H/SPEED/ACCEL/AIR_ACCEL/FRICTION/JUMP_V/GRAVITY/RISE_GRAVITY_SCALE/
MAX_FALL/JUMP_CUT/COYOTE/BUFFER/STOMP_BOUNCE/INVULN/START_HP/MAX_HP/PLAYER_W/PLAYER_H/
GRUNT_SPEED/GRUNT_GRAVITY/FLYER_SPEED/FLYER_AMP/FLYER_SPEED_Y/SCORE_COIN/SCORE_ENEMY/SCORE_TIME/
SPRITES/SFX_DIR/FRAME_*/TEX_*。

## 2. InputHub（已有，只读）
`godot/scripts/input_hub.gd`：
`is_held(action) -> bool`、`just_pressed(action) -> bool`、`axis_x() -> float`。
动作常量：`InputHub.LEFT/RIGHT/JUMP/RUN/PAUSE/RESTART/CONFIRM`。

## 3. SpriteFactory（已有，只读）
`godot/scripts/sprite_factory.gd`：
`make_animated(entity: String, fps: float = 10.0) -> AnimatedSprite2D`（动画名固定 "run"）、
`make_static(entity: String) -> Sprite2D`、`frames_of(entity) -> Array`。

## 4. LevelBuilder —— 文件 `godot/scripts/level_builder.gd`
```gdscript
class_name LevelBuilder
extends Node2D

## 由 main.gd 调用一次。rows 为 level_data.gd 的 ROWS（Array[String]，长度 LEVEL_ROWS）
func build(rows: Array) -> void

var spawn_point: Vector2      # 玩家出生 feet 位置
var goal_point: Vector2       # 终点旗底部位置
var blocks: Dictionary        # Vector2i(col,row) -> Block
var enemies: Array[Node2D]    # Enemy 实例
var pickups: Array[Dictionary]# 每项 {node: Node2D, kind: String("coin"/"mushroom"), pos: Vector2, taken: bool}
```
- 地形 `#` `X`：合并**水平连续段**为尽量少的矩形碰撞体（不要一格一个 StaticBody2D）。
  视觉层用 `Sprite2D` + `texture_repeat` 或按 tile 铺 Sprite2D（每格一个 Sprite2D 即可，视觉不限量）。
  `#` 用 `tile_ground`，`X` 用 `tile_solid`。
- 砖 `B` / 问号 `?`：**每格一个 Block 节点**（独立 StaticBody2D），加入 `blocks` 字典。
- 单向平台 `=`：`=` 所在行的每个格子建一个 StaticBody2D，其 CollisionShape2D
  `one_way_collision = true`，形状高度 6px，位置在格子底部（y = row*16 + 13）。
- 敌人 `E` → Enemy kind="grunt"；`F` → Enemy kind="flyer"。
- 拾取 `C` → kind="coin"（AnimatedSprite2D，实体名 "pickup_coin"）；
  `M` → kind="mushroom"（Sprite2D，实体名 "pickup_mushroom"）。
- 终点 `G` → Sprite2D 实体名 "flag_goal"，放在 goal_point，底部对齐格子底部。
- `B`/`?` 的视觉：`B` 用 `tile_brick`，`?` 用 `tile_question`。
- LevelBuilder 自身不需要移动。

## 5. Block —— 文件 `godot/scripts/block.gd`
```gdscript
class_name Block
extends StaticBody2D

var kind: String          # "brick" 或 "question"
var used: bool = false
var has_item: bool = false   # question 是否含物品
var col: int
var row: int

## 玩家从下方顶到时调用。返回值决定反馈：
## "coin"   → 顶出金币（main 处理得分与特效）
## "item"   → 顶出蘑菇/道具（main 处理）
## "break"  → 砖块碎裂（main 移除节点并放特效）
## ""       → 无事发生
func hit() -> String
```
- `question` 且 `has_item=true`：第一次 hit 返回 "item"，之后 `used=true`，纹理换成 `tile_solid`。
- `question` 且 `has_item=false`：第一次 hit 返回 "coin"，之后同上。
- `brick`：第一次 hit 返回 "break"；`used=true`，由 main 负责 `queue_free`。
- 视觉：StaticBody2D + 子 Sprite2D（居中）。

## 6. Player —— 文件 `godot/scripts/player.gd`
```gdscript
class_name Player
extends CharacterBody2D

signal died(reason: String)            # "pit" | "damage"
signal hp_changed(hp: int, max_hp: int)
signal block_hit(result: String, block_pos: Vector2)
signal stomped(enemy: Node2D)
signal coin_collected(pos: Vector2)
signal powerup(pos: Vector2)
signal landed(strong: bool)

func setup(input: InputHub) -> void
func respawn(pos: Vector2) -> void      # 重置位置/速度/无敌帧，保留 hp
func hurt() -> bool                     # 返回是否真的受伤（无敌帧内返回 false）
func add_hp(n: int) -> void
func bounce() -> void                   # 踩敌人后的弹跳（STOMP_BOUNCE）
func get_rect() -> Rect2                # 玩家 AABB（用于 main 手动判定）
func get_feet_y() -> float
func is_dead() -> bool
var hp: int
var alive: bool
var invuln_timer: float
```
手感要求（**必须**按此实现，用户明确要求还原马里奥手感）：
- 水平：`SPEED`，地面 `ACCEL` 加速、`FRICTION` 减速；空中 `AIR_ACCEL`。
- 跳跃：`JUMP_V`；**可变跳高**——上升且按住跳跃键时重力乘 `RISE_GRAVITY_SCALE`；
  松开跳跃键时若 velocity.y < 0 则 `velocity.y *= JUMP_CUT`（滞空控制）。
- **土狼时间** `COYOTE`：**跳跃缓冲** `BUFFER`。
- 下落速度上限 `MAX_FALL`。
- 落地：`is_on_floor()` 判定；记录 `coyote_timer` / `buffer_timer`。
- 顶砖块：每次物理帧检查 `get_slide_collision_count()`，若碰撞法线朝下（`normal.y > 0.5`）
  且碰撞体有方法 `hit`，则调用它并 `emit_signal("block_hit", result, 碰撞体全局位置)`，
  同时 `velocity.y = 60`（轻微下压反馈）。
- 掉坑：`position.y > GameConfig.WORLD_H + 40` → `emit_signal("died", "pit")`。
- 受伤：`hurt()` 使 hp-1，`INVULN` 无敌帧（精灵闪烁），hp<=0 → `emit_signal("died","damage")`。
- 视觉：`Sprite2D`/`AnimatedSprite2D` 用 SpriteFactory；站立/跑动用 "hero"，腾空用 "hero_jump"；
  动画帧率 10。精灵底部对齐碰撞体底部。
- 受伤后不要立刻 respawn，由 main 决定。

## 7. Enemy —— 文件 `godot/scripts/enemy.gd`
```gdscript
class_name Enemy
extends CharacterBody2D

signal defeated(enemy: Node2D)

func setup(kind: String) -> void         # "grunt" | "flyer"
func get_rect() -> Rect2
func is_alive() -> bool
func stomp() -> void                     # 被踩：翻车/消失并 emit defeated
func hit_player() -> bool                # 侧面碰到玩家，返回是否命中
var kind: String
```
- `grunt`：水平巡逻 `GRUNT_SPEED`，受 `GRUNT_GRAVITY` 落地；走到墙前或悬崖边转向。
- `flyer`：水平 `FLYER_SPEED`，竖直做正弦浮动（`FLYER_AMP` / `FLYER_SPEED_Y`），不受重力。
- 精灵：grunt → "enemy_grunt"，flyer → "enemy_flyer"，AnimatedSprite2D，帧率 8。
- 碰撞层 4，掩码 1（不与玩家物理碰撞）。

## 8. UI —— 文件 `godot/scripts/ui.gd`
```gdscript
class_name GameUI
extends CanvasLayer

func setup(font_path: String) -> void    # "res://assets/fonts/zpix.ttf"
func show_title() -> void
func show_hud() -> void
func show_pause() -> void
func show_win(score: int, coins: int, time_sec: int) -> void
func show_lose(score: int, coins: int, time_sec: int) -> void
func hide_all() -> void
func set_score(score: int) -> void
func set_coins(coins: int) -> void
func set_hp(hp: int, max_hp: int) -> void
func set_time(sec: int) -> void
func set_hint(text: String) -> void
```
- 用 Label + zpix 字体（像素字体，字号 16/24）。颜色纯白/黄色系，描边用 `font_outline_color`+`outline_size`。
- HUD：左上角 `金币 xNN` `分数 xNNNN` `时间 NNN`；生命用 `ui_heart` 精灵横排（最多 MAX_HP 个）。
- 标题界面：游戏名 + "按 空格 / 回车 开始" + 操作按键说明表。
- 暂停界面：`已暂停` + "按 P / ESC 继续"。
- 胜利界面：`通关！` + 分数/金币/时间 + "按 R 重新开始"。
- 失败界面：`失败` + 同样的统计 + "按 R 重新开始"。
- 全部界面用 Control 节点 + Label，锚点居中。`z_index` 最高。

## 9. main.gd —— 由 Lead 编写
状态机：`TITLE / PLAY / PAUSE / WIN / LOSE`。
- `TITLE`：显示 title，等待 CONFIRM(JUMP/CONFIRM) → PLAY。
- `PLAY`：跑游戏循环，PAUSE 动作 → PAUSE。
- `PAUSE`：暂停物理与计时，显示 pause，PAUSE 再次 → PLAY。
- `WIN`：到达 goal_point 触发，显示 win，R 重开。
- `LOSE`：玩家 died 触发（延迟 0.6s），显示 lose，R 重开。
- 相机：`Camera2D` 跟随玩家 x，`position_smoothing_enabled=true`，限制在 [VIEW_W/2, WORLD_W-VIEW_W/2]，
  y 固定到 288-VIEW_H/2（=108）左右，或跟随玩家 y 但夹在合理范围。
- 音频：`AudioStreamPlayer` 播 BGM（`bgm.wav`，`loop_end = get_length()*mix_rate`），
  SFX 用一次性 `AudioStreamPlayer`（池 6 个）。
- 敌人/拾取判定用 `get_rect()` 手动 AABB：
  - 玩家 `velocity.y > 0` 且玩家脚底在敌人上半部（脚底 y 在敌人 rect 顶部到顶部+8 之间）→ 踩死。
  - 否则 → 玩家受伤。

## 10. 文件分工（写入范围互不重叠）
| 人 | 文件 |
|---|---|
| A | `godot/scripts/player.gd`、`godot/scripts/enemy.gd` |
| B | `godot/scripts/level_builder.gd`、`godot/scripts/block.gd` |
| C | `godot/scripts/ui.gd` |
| Lead | `godot/scripts/main.gd`、`godot/main.tscn`、`godot/smoke_test.gd`、`godot/smoke_test.tscn`、`godot/project.godot` |

**不要**修改别人负责的文件；需要对方新增接口时，在自己的脚本里用兼容方式（`has_method`/`call`）处理，
并在交付说明里写明。
