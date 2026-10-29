# -*- coding: utf-8 -*-
"""gen_level.py —— 用 ASCII 网格生成关卡数据（原创关卡设计，非任何商业游戏关卡）。

输出：godot/scripts/level_data.gd  （const ROWS := [...]）
网格字符：
  '.' 空   '#' 地面(草皮土块)  'X' 灰色实心块  'B' 可破坏砖块  '?' 问号块
  '=' 单向平台  'P' 玩家出生点    'E' 地面敌人    'F' 飞行敌人
  'C' 金币      'M' 蘑菇         'G' 终点旗
行 0 在上；GROUND_TOP 行为地面表层，其下为实心泥土。
"""
import os

W, H = 210, 23
GROUND_TOP = 18
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "godot", "scripts", "level_data.gd")

g = [['.'] * W for _ in range(H)]


def put(x, y, ch):
    if 0 <= x < W and 0 <= y < H:
        g[y][x] = ch


def fill(x0, x1, y, ch):
    for x in range(x0, x1 + 1):
        put(x, y, ch)


# ---------------- 地面（整行实心，再挖坑） ----------------
for x in range(W):
    for y in range(GROUND_TOP, H):
        g[y][x] = '#'

PITS = [(29, 34), (62, 67), (96, 101), (131, 137), (166, 171)]
for a, b in PITS:
    for x in range(a, b + 1):
        for y in range(GROUND_TOP, H):
            g[y][x] = '.'

# 两侧围墙
for y in range(H):
    put(0, y, 'X')
    put(W - 1, y, 'X')

# ---------------- 平台（单向） ----------------
PLATFORMS = [
    (29, 31, 15), (33, 34, 13),
    (62, 64, 15), (66, 67, 12),
    (96, 98, 15), (100, 101, 12),
    (131, 133, 16), (135, 137, 13),
    (166, 168, 15), (170, 171, 12),
]
for a, b, r in PLATFORMS:
    fill(a, b, r, '=')

# ---------------- 台阶（灰色实心） ----------------
STAIRS = [(42, 4), (56, 3), (78, 5), (110, 4), (145, 3), (178, 5)]
for x0, n in STAIRS:
    for i in range(n):
        for y in range(GROUND_TOP - 1 - i, GROUND_TOP):
            put(x0 + i, y, 'X')

# ---------------- 砖块 / 问号块 ----------------
BLOCK_ROWS = [
    (20, 24, 14), (46, 50, 13), (84, 88, 13), (103, 107, 14),
    (113, 118, 12), (152, 157, 13), (186, 190, 12),
]
for a, b, r in BLOCK_ROWS:
    for i, x in enumerate(range(a, b + 1)):
        ch = '?' if (i == 1 or i == 4) else 'B'
        put(x, r, ch)

# 高处的问号块孤岛
fill(72, 73, 11, '?')
fill(73, 73, 11, '?')
fill(121, 122, 11, '?')

# ---------------- 实体 ----------------
put(3, GROUND_TOP - 1, 'P')

ENEMIES = [
    (13, GROUND_TOP - 1, 'E'), (26, GROUND_TOP - 1, 'E'),
    (38, GROUND_TOP - 1, 'E'), (52, GROUND_TOP - 1, 'E'),
    (58, GROUND_TOP - 1, 'E'), (74, GROUND_TOP - 1, 'E'),
    (90, GROUND_TOP - 1, 'E'), (105, GROUND_TOP - 1, 'E'),
    (118, GROUND_TOP - 1, 'E'), (127, GROUND_TOP - 1, 'E'),
    (143, GROUND_TOP - 1, 'E'), (160, GROUND_TOP - 1, 'E'),
    (174, GROUND_TOP - 1, 'E'), (194, GROUND_TOP - 1, 'E'),
    (46, 10, 'F'), (90, 9, 'F'), (123, 10, 'F'), (160, 8, 'F'), (198, 11, 'F'),
]
for x, y, ch in ENEMIES:
    put(x, y, ch)

COINS = [
    (7, 17), (8, 17), (9, 17), (18, 16), (19, 16),
    (30, 14), (31, 14), (32, 14),
    (44, 16), (45, 16), (46, 16),
    (57, 13), (58, 13), (59, 13),
    (63, 14), (64, 14), (66, 11), (67, 11),
    (71, 16), (72, 16),
    (86, 12), (87, 12),
    (97, 14), (98, 14), (100, 11), (101, 11),
    (104, 13), (105, 13), (106, 13),
    (117, 15), (118, 15),
    (132, 15), (133, 15), (135, 12), (136, 12), (137, 12),
    (144, 16), (145, 16),
    (153, 12), (154, 12), (155, 12),
    (167, 14), (168, 14),
    (175, 16), (176, 16),
    (186, 11), (187, 11), (188, 11),
    (196, 16), (197, 16),
]
for x, y in COINS:
    put(x, y, 'C')

put(60, GROUND_TOP - 1, 'M')
put(150, GROUND_TOP - 1, 'M')

# 终点旗：放在 202 列，脚下有实心台
for y in range(GROUND_TOP - 2, GROUND_TOP):
    fill(201, 203, y, 'X')
put(202, GROUND_TOP - 3, 'G')

# ---------------- 输出 ----------------
os.makedirs(os.path.dirname(OUT), exist_ok=True)
lines = []
lines.append("# 自动生成，请勿手改；改关卡请改 scripts/gen_level.py 后重新生成。")
lines.append("# 字符说明： '.'空 '#'地面 'X'实心 'B'砖 '?'问号 '='单向平台")
lines.append("#            'P'出生 'E'地面敌人 'F'飞行敌人 'C'金币 'M'蘑菇 'G'终点")
lines.append("class_name LevelData")
lines.append("extends RefCounted")
lines.append("")
lines.append("const ROWS := [")
for y in range(H):
    lines.append('\t"%s",' % "".join(g[y]))
lines.append("]")
with open(OUT, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

print("关卡写入:", OUT)
for y in range(H):
    print("%2d %s" % (y, "".join(g[y])))
