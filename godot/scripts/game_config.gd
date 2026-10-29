class_name GameConfig
extends RefCounted
##
## 全局数值表。数值基线来自 references/godot_recipes.md §10，
## 按 tile=16、画布 640x360 的横版平台跳跃手感做了校准。
##

# ---- 画布与关卡 ----
const TILE := 16
const VIEW_W := 640
const VIEW_H := 360
const LEVEL_ROWS := 23
const LEVEL_COLS := 210
const GROUND_TOP := 18
const WORLD_W := LEVEL_COLS * TILE      # 3360
const WORLD_H := LEVEL_ROWS * TILE      # 368

# ================================================================
# 调参指南（改这里，不要散落到各脚本）
# ----------------------------------------------------------------
# 移动速度 SPEED
#   当前 120 px/s（世界单位/秒，tile=16 时约 7.5 格/秒）
#   推荐区间 100~130。低于 100 会显得迟钝，高于 140 角色会「刹不住」，
#   在 96px 宽的深坑前容易冲过头。
#   影响范围：走跑速度、与坑宽的匹配、敌人相对压迫感、关卡耗时。
#   调整原则：改 SPEED 时要同步按比例调整 GRUNT_SPEED / FLYER_SPEED，
#   保持「敌人速度 / 玩家速度」的比值不变，否则难度会悄悄漂移。
#
# 镜头 CAMERA_ZOOM
#   当前 1.5（>1 为拉近）。1.0 = 原始比例，1.5 = 视野缩小到 426x240 世界像素，
#   角色 16px 显示成 24px，辨认度明显提升。
#   推荐区间 1.3~1.6。再大就会把「下一个坑看不到」，破坏关卡节奏。
#   影响范围：同屏可见范围、角色在屏占比、HUD 与场景的拥挤度。
#
# 跳跃 JUMP_V / GRAVITY / RISE_GRAVITY_SCALE / JUMP_CUT
#   当前 -430 / 1300 / 0.66 / 0.45（可变跳高 + 滞空控制）
#   满跳高度约 104px，滞空约 0.9s。
#   **改动 SPEED 时必须复核「滞空水平位移 >= 最宽深坑宽度(96px)」**：
#   120 px/s × 0.9s ≈ 108px，刚好越过 96px 的坑；这是速度上限的真正约束。
#
# 角色可视大小
#   素材 32px，Sprite 缩放 0.5 → 世界 16px，碰撞体 12x15。
#   想让角色更大优先调 CAMERA_ZOOM，不要动 SPRITE_SCALE，
#   否则精灵与碰撞体错位，踩踏判定会偏。
# ================================================================

# ---- 玩家手感三件套 ----
const SPEED := 120.0          # 最大水平速度 px/s（推荐 100~130，见调参指南）
const ACCEL := 1400.0         # 地面加速度
const AIR_ACCEL := 900.0      # 空中加速度（略小，手感更飘）
const FRICTION := 1800.0      # 地面摩擦
const JUMP_V := -430.0        # 起跳初速度
const GRAVITY := 1300.0       # 重力
const RISE_GRAVITY_SCALE := 0.66  # 上升且按住跳跃键时的重力倍率（可变跳高）
const MAX_FALL := 520.0       # 最大下落速度
const JUMP_CUT := 0.45        # 松开跳跃键时上升速度的保留比例（滞空控制）
const COYOTE := 0.10          # 土狼时间
const BUFFER := 0.12          # 跳跃缓冲
const STOMP_BOUNCE := -330.0  # 踩敌人后的弹跳
const INVULN := 0.8           # 受伤后的无敌时间
const START_HP := 3
const MAX_HP := 5

# ---- 镜头 ----
# 拉近系数：>1 拉近（视野变小、角色变大），<1 拉远。
const CAMERA_ZOOM := 1.5      # 推荐 1.15~1.35
# 缩放后的实际可见世界尺寸（供相机边界与 UI 布局使用）
const VIEW_W_ZOOM := float(VIEW_W) / CAMERA_ZOOM
const VIEW_H_ZOOM := float(VIEW_H) / CAMERA_ZOOM

# ---- 玩家碰撞体 ----
const PLAYER_W := 12.0
const PLAYER_H := 15.0

# ---- 敌人 ----
# 敌人速度按玩家速度同步下调（150→120 时按 0.8 比例折算），
# 保持「敌人速度 / 玩家速度」比值不变，避免手感调整后难度悄悄漂移。
const GRUNT_SPEED := 34.0
const GRUNT_GRAVITY := 1300.0
const FLYER_SPEED := 42.0
const FLYER_AMP := 20.0
const FLYER_SPEED_Y := 60.0

# ---- 计分 ----
const SCORE_COIN := 100
const SCORE_ENEMY := 200
const SCORE_TIME := 10      # 每存活 1 秒的奖励分

# ---- 检查点 ----
# 关卡中途存档点所在的列号（必须落在实心地面上，且上方 6 格为空）
const CHECKPOINT_COLS := [36, 73, 109, 139, 165]
# 检查点旗立在地面上：脚底 y = GROUND_TOP * TILE
const CHECKPOINT_GROUND_Y := float(GROUND_TOP * TILE)

# ---- 资源路径 ----
const SPRITES := "res://assets/sprites/"
const SFX_DIR := "res://assets/sfx/"

const FRAME_HERO := ["hero_f0.png", "hero_f1.png", "hero_f2.png", "hero_f3.png"]
const FRAME_HERO_JUMP := ["hero_jump_f0.png", "hero_jump_f1.png"]
const FRAME_GRUNT := ["enemy_grunt_f0.png", "enemy_grunt_f1.png"]
const FRAME_FLYER := ["enemy_flyer_f0.png", "enemy_flyer_f1.png"]
const FRAME_COIN := ["pickup_coin_f0.png", "pickup_coin_f1.png", "pickup_coin_f2.png", "pickup_coin_f3.png"]
const FRAME_FX_BRICK := ["fx_brick_f0.png", "fx_brick_f1.png"]
const TEX_GROUND := "tile_ground.png"
const TEX_DIRT := "tile_dirt.png"
const TEX_SOLID := "tile_solid.png"
const TEX_BRICK := "tile_brick.png"
const TEX_QUESTION := "tile_question.png"
const TEX_HEART := "ui_heart.png"
const TEX_FLAG := "flag_goal.png"
const TEX_MUSHROOM := "pickup_mushroom.png"
