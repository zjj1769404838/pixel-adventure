#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成《像素冒险》应用图标（原创拼装，纯像素风）。

素材来源全部为本工程自有资源：
  godot/assets/sprites/hero_f0.png      32x32  红帽主角
  godot/assets/sprites/tile_ground.png  16x16  草地/泥土地块
  godot/assets/sprites/tile_brick.png   16x16  砖块
  godot/assets/sprites/pickup_coin_f0.png 16x16 金币

做法：在 48x48 的低分辨率画布上用 NEAREST 原尺寸拼装场景，再整体 NEAREST 放大
到 192 与 432（192 = 48*4，432 = 48*9），保证输出是真像素画（无抗锯齿、
无插值）。圆角用 ImageDraw.rounded_rectangle 硬边绘制，角外 alpha = 0。

用法（在工程根目录执行）：
    D:/apps/Python313/python.exe scripts/gen_icon.py
可选：
    D:/apps/Python313/python.exe scripts/gen_icon.py --project D:/path/to/game-4
"""

import argparse
import os
import sys

from PIL import Image, ImageDraw

BASE = 48          # 拼装用的低分辨率画布边长
TARGETS = (192, 432)
SKY = (92, 158, 219, 255)   # 天空底色（自选，与游戏 Web 预设背景同一系）

SPRITE_DIR = os.path.join("godot", "assets", "sprites")


def load_sprite(rel_dir, name):
    """读取精灵并转成 RGBA。返回 (PIL.Image, 路径)。"""
    path = os.path.join(rel_dir, name)
    if not os.path.isfile(path):
        raise SystemExit("缺少素材文件: %s" % path)
    return Image.open(path).convert("RGBA"), path


def rounded_mask(size, radius):
    """生成硬边圆角 alpha 掩码（无抗锯齿，保持像素风）。"""
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def compose(base_dir):
    """在 48x48 画布上拼装图标场景，返回 RGBA 图像。"""
    canvas = Image.new("RGBA", (BASE, BASE), SKY)

    # 地面：三个地块铺满底行（y = 32..47）
    ground_tile, ground_path = load_sprite(os.path.join(base_dir, SPRITE_DIR), "tile_ground.png")
    for col in range(3):
        canvas.alpha_composite(ground_tile, (col * 16, 32))

    # 左右两侧砖块栈（坐在地面上，砖块 16x16 放在 y = 16..31）
    brick_tile, brick_path = load_sprite(os.path.join(base_dir, SPRITE_DIR), "tile_brick.png")
    canvas.alpha_composite(brick_tile, (0, 16))
    canvas.alpha_composite(brick_tile, (32, 16))

    # 主角：32x32 原尺寸贴入，内容像素落在 x = 16..31，脚下正好接地面
    hero, hero_path = load_sprite(os.path.join(base_dir, SPRITE_DIR), "hero_f0.png")
    canvas.alpha_composite(hero, (6, 0))

    # 金币：放在右侧砖块顶上
    coin, coin_path = load_sprite(os.path.join(base_dir, SPRITE_DIR), "pickup_coin_f0.png")
    canvas.alpha_composite(coin, (32, 0))

    # 圆角遮罩（角外透明，alpha = 0）
    mask = rounded_mask(BASE, radius=7)
    canvas.putalpha(
        Image.composite(canvas.getchannel("A"), Image.new("L", (BASE, BASE), 0), mask)
    )

    for p in (ground_path, brick_path, hero_path, coin_path):
        sys.stdout.write("  素材: %s\n" % p)
    return canvas


def upscale(base_img, size):
    """NEAREST 放大到目标尺寸。"""
    scale = size // BASE
    if size % BASE != 0:
        raise SystemExit("目标尺寸 %d 不是 48 的整数倍，无法用 NEAREST 等比放大" % size)
    return base_img.resize((size, size), Image.NEAREST)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_project = os.path.dirname(here)
    ap = argparse.ArgumentParser(description="生成像素冒险应用图标")
    ap.add_argument("--project", default=default_project, help="工程根目录（默认取脚本上级目录）")
    ap.add_argument("--out-dir", default=None, help="输出目录（默认 <project>/godot/assets）")
    args = ap.parse_args()

    project = os.path.abspath(args.project)
    out_dir = args.out_dir or os.path.join(project, "godot", "assets")
    os.makedirs(out_dir, exist_ok=True)

    print("工程根目录: %s" % project)
    base_img = compose(project)

    for size in TARGETS:
        out_path = os.path.join(out_dir, "icon_%d.png" % size)
        final = upscale(base_img, size)
        final.save(out_path, "PNG")

        # 自检：尺寸 / 模式 / 透明区域 alpha 必须为 0
        check = Image.open(out_path)
        assert check.size == (size, size), "尺寸错误: %s" % (check.size,)
        assert check.mode == "RGBA", "模式错误: %s" % check.mode
        alpha = check.getchannel("A")
        lo, hi = alpha.getextrema()
        assert lo == 0, "不存在全透明像素 (alpha_min=%d)" % lo
        assert hi == 255, "没有不透明像素 (alpha_max=%d)" % hi
        print("已写出 %s  %dx%d RGBA  字节数=%d" % (
            out_path, size, size, os.path.getsize(out_path)))


if __name__ == "__main__":
    main()
