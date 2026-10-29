# -*- coding: utf-8 -*-
"""gen_tiles.py —— 程序化生成 16x16 像素地块（原创图形，非任何受版权保护的素材）。

产出到 assets/raw/ 下，文件名与 asset_manifest.json 里的实体名一致，
随后由 postprocess_assets.py 做量化/缩放/校验（tile 走整幅 NEAREST resize）。

调色板为自定 16 色，与角色素材（snes16）同调性。
"""
import os
import sys

from PIL import Image

RAW = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "assets", "raw")

# ---- 自定 16 色调色板 ----
P = {
    "black": (26, 22, 34),
    "dark": (58, 44, 66),
    "soil": (122, 82, 56),
    "soil_d": (92, 60, 42),
    "soil_l": (156, 110, 74),
    "grass": (86, 176, 84),
    "grass_d": (58, 130, 62),
    "grass_l": (134, 208, 110),
    "brick": (196, 96, 56),
    "brick_d": (146, 62, 38),
    "brick_l": (232, 148, 88),
    "gold": (244, 196, 68),
    "gold_d": (188, 140, 32),
    "gold_l": (255, 232, 150),
    "stone": (140, 144, 160),
    "stone_d": (92, 96, 116),
    "stone_l": (188, 192, 208),
    "white": (244, 244, 248),
}


def new_img():
    return Image.new("RGBA", (16, 16), (0, 0, 0, 0))


def put(im, x, y, c):
    if 0 <= x < 16 and 0 <= y < 16:
        im.putpixel((x, y), c + (255,))


def rect(im, x0, y0, x1, y1, c):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            put(im, x, y, c)


def make_ground():
    """泥土块 + 顶部草皮。"""
    im = new_img()
    rect(im, 0, 0, 15, 15, P["soil"])
    # 顶部草皮三行
    rect(im, 0, 0, 15, 2, P["grass"])
    rect(im, 0, 0, 15, 0, P["grass_l"])
    for x in range(0, 16, 3):
        put(im, x, 2, P["grass_d"])
        put(im, (x + 1) % 16, 3, P["grass_d"])
    # 泥土颗粒
    for x, y in ((2, 6), (7, 8), (11, 5), (13, 9), (4, 11), (9, 13), (1, 14), (6, 15)):
        put(im, x, y, P["soil_d"])
    for x, y in ((5, 5), (10, 7), (3, 9), (12, 12), (8, 10)):
        put(im, x, y, P["soil_l"])
    # 底部暗边
    rect(im, 0, 15, 15, 15, P["soil_d"])
    return im


def make_soil():
    """泥土层：地面顶层的下方使用，不带草皮。"""
    im = new_img()
    rect(im, 0, 0, 15, 15, P["soil"])
    # 顶部一道暗色，暗示被草皮压住
    rect(im, 0, 0, 15, 0, P["soil_d"])
    # 泥土颗粒
    for x, y in ((2, 6), (7, 8), (11, 5), (13, 9), (4, 11), (9, 13), (1, 14), (6, 3)):
        put(im, x, y, P["soil_d"])
    for x, y in ((5, 5), (10, 7), (3, 9), (12, 12), (8, 10)):
        put(im, x, y, P["soil_l"])
    # 底部暗边
    rect(im, 0, 15, 15, 15, P["soil_d"])
    return im


def make_brick():
    """橙砖块：4 行错缝砖。"""
    im = new_img()
    rect(im, 0, 0, 15, 15, P["brick"])
    rect(im, 0, 0, 15, 15, P["brick_d"])  # 先铺暗色，再画亮砖面
    rows = [(0, 7, 0), (8, 15, 8)]
    for y0, y1, off in rows:
        for y in range(y0, y1 + 1):
            for x in range(16):
                put(im, x, y, P["brick"])
            # 砖面高光
            for x in range(16):
                if y == y0:
                    put(im, x, y, P["brick_l"])
        # 竖缝
        for bx in (off, (off + 8) % 16):
            for y in range(y0, y1 + 1):
                put(im, bx, y, P["brick_d"])
    # 横缝
    rect(im, 0, 7, 15, 7, P["brick_d"])
    rect(im, 0, 15, 15, 15, P["brick_d"])
    return im


def make_question():
    """问号块：金色方块 + 深色边框 + 像素问号。"""
    im = new_img()
    rect(im, 0, 0, 15, 15, P["gold"])
    rect(im, 0, 0, 15, 0, P["gold_l"])
    rect(im, 0, 15, 15, 15, P["gold_d"])
    rect(im, 0, 0, 0, 15, P["gold_d"])
    rect(im, 15, 0, 15, 15, P["gold_d"])
    rect(im, 1, 1, 14, 1, P["gold_l"])
    # 问号（5x7 像素）
    q = [
        "  ###  ",
        " #   # ",
        "     # ",
        "    #  ",
        "   #   ",
        "   #   ",
        "        ",
    ]
    for r, row in enumerate(q):
        for c, ch in enumerate(row):
            if ch == "#":
                put(im, 5 + c, 4 + r, P["gold_d"])
    # 问号点
    put(im, 7, 11, P["gold_d"])
    put(im, 7, 12, P["gold_d"])
    # 四角铆钉
    for x, y in ((2, 2), (13, 2), (2, 13), (13, 13)):
        put(im, x, y, P["gold_l"])
    return im


def make_solid():
    """灰色实心石块。"""
    im = new_img()
    rect(im, 0, 0, 15, 15, P["stone"])
    rect(im, 0, 0, 15, 1, P["stone_l"])
    rect(im, 0, 0, 1, 15, P["stone_l"])
    rect(im, 0, 15, 15, 15, P["stone_d"])
    rect(im, 15, 0, 15, 15, P["stone_d"])
    for x, y in ((4, 5), (9, 4), (6, 9), (11, 10), (3, 12)):
        put(im, x, y, P["stone_d"])
    for x, y in ((5, 5), (10, 4), (7, 9)):
        put(im, x, y, P["stone_l"])
    return im


def main():
    os.makedirs(RAW, exist_ok=True)
    makers = {
        "tile_ground": make_ground,
        "tile_dirt": make_soil,
        "tile_brick": make_brick,
        "tile_question": make_question,
        "tile_solid": make_solid,
    }
    for name, fn in makers.items():
        p = os.path.join(RAW, name + ".png")
        fn().save(p)
        print("OK", name, "->", p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
