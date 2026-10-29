# -*- coding: utf-8 -*-
"""gen_level_texture.py —— 把关卡地形烘焙成一张大图（离线预渲染）。

目的：Godot 运行时不再为每一格地形创建 Sprite2D（关卡 210x23，地形约 996 格，
低端 Android 上逐节点建树与逐帧遍历都很贵），改为一整张 Sprite2D。

输入：
  godot/scripts/level_data.gd      —— ASCII 网格（const ROWS := [...]）
  godot/assets/sprites/tile_*.png  —— 运行时真正加载的地块贴图（16x16）

输出：
  godot/assets/sprites/level_terrain.png —— 210*16 x 23*16 = 3360 x 368 的 RGBA 大图

贴图选择规则与 godot/scripts/level_builder.gd 的 _ground_tex() 严格一致：
  某格是 '#'：
      r <= 0                              -> tile_ground
      上一行同一列是 '#' 或 'X'           -> tile_dirt（被埋在下面）
      否则                                 -> tile_ground（表层草皮）
  某格是 'X'：                            -> tile_solid（灰色实心石块）
  其余字符（. B ? = P G E F C M）：透明，不画。

贴图一律从 godot/assets/sprites/ 读取，保证拼出来的像素与引擎里显示的完全一致
（assets/raw/ 是程序化原图，assets/final/ 是量化版，运行时用的是 godot/assets/sprites/）。

注意：变量名不要用 image / crop（工程踩过被 numpy 覆盖的坑）。
"""
import os
import re
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GODOT = os.path.join(ROOT, "godot")
LEVEL_DATA = os.path.join(GODOT, "scripts", "level_data.gd")
SPRITES = os.path.join(GODOT, "assets", "sprites")
OUT_PNG = os.path.join(SPRITES, "level_terrain.png")

TILE = 16


def read_rows(path):
    """从 level_data.gd 的 const ROWS := [...] 里读出 ASCII 网格。"""
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    if "const ROWS := [" not in src:
        raise SystemExit("level_data.gd 里找不到 const ROWS := [...]")
    block = src.split("const ROWS := [", 1)[1].split("]", 1)[0]
    rows = re.findall(r'"([^"]*)"', block)
    if not rows:
        raise SystemExit("level_data.gd 里没解析到任何行")
    return rows


def ground_tex(rows, c, r):
    """与 level_builder.gd 的 _ground_tex() 完全一致的贴图选择规则。"""
    if r <= 0:
        return "tile_ground"
    above = rows[r - 1]
    if c < len(above):
        ch = above[c]
        if ch == "#" or ch == "X":
            return "tile_dirt"
    return "tile_ground"


def load_tiles():
    """读运行时用的三张地块贴图。"""
    tiles = {}
    for name in ("tile_ground", "tile_dirt", "tile_solid"):
        p = os.path.join(SPRITES, name + ".png")
        if not os.path.exists(p):
            raise SystemExit("缺少地块贴图: " + p)
        t = Image.open(p).convert("RGBA")
        if t.size != (TILE, TILE):
            raise SystemExit("%s 尺寸应为 %dx%d，实际 %dx%d"
                             % (name, TILE, TILE, t.size[0], t.size[1]))
        tiles[name] = t
    return tiles


def main():
    rows = read_rows(LEVEL_DATA)
    h = len(rows)
    w = max(len(r) for r in rows)
    for i, r in enumerate(rows):
        if len(r) != w:
            raise SystemExit("第 %d 行长度 %d 与其它行 %d 不一致" % (i, len(r), w))

    tiles = load_tiles()
    canvas = Image.new("RGBA", (w * TILE, h * TILE), (0, 0, 0, 0))

    counts = {"tile_ground": 0, "tile_dirt": 0, "tile_solid": 0}
    for r in range(h):
        row = rows[r]
        for c in range(w):
            ch = row[c]
            if ch == "#":
                key = ground_tex(rows, c, r)
            elif ch == "X":
                key = "tile_solid"
            else:
                continue
            counts[key] += 1
            canvas.paste(tiles[key], (c * TILE, r * TILE))

    expect = (w * TILE, h * TILE)
    if canvas.size != expect:
        raise SystemExit("输出尺寸错误: %dx%d != %dx%d"
                         % (canvas.size[0], canvas.size[1], expect[0], expect[1]))

    canvas.save(OUT_PNG)
    print("OK 网格 %d 列 x %d 行 -> %dx%d 像素" % (w, h, canvas.size[0], canvas.size[1]))
    print("OK 输出 %s" % OUT_PNG)
    total = sum(counts.values())
    for key in ("tile_ground", "tile_dirt", "tile_solid"):
        print("   %-12s %d 张" % (key, counts[key]))
    print("   %-12s %d 格" % ("合计", total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
