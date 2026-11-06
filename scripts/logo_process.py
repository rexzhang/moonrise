#!/usr/bin/env python3
"""MoonRise logo 处理管线（Pillow）

用法: .venv/bin/python scripts/logo_process.py <source.png> [--logo-only]
  默认: 双屏定位 → 白底板抠图 → 定稿裁剪居中 → 深墨合成 App 图标 → iconset 十尺寸
  --logo-only: 仅输出 assets/brand/logo/（透明品牌导出，不动 iconset）

裁切标准: 内容左右各留 10px 空白，以此宽度为正方形边长，内容垂直居中。
深墨合成: squircle（824，rx185）平涂 #101318 + 对角光照（左上提亮→右下压暗），
          内容按 758 盒居中。alpha 边界检测不可用于本图（烘焙光斑会污染边界）。
"""
import sys
from pathlib import Path
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "assets/brand"
CROP = (123, 135, 1167, 1000)     # 定稿裁剪（PIL box：左 123 / 上 135 / 右 1167 / 下 1000）
KEEP_PAD = 8                      # 双屏矩形外扩保留区
SQ_X0, SQ_Y0 = 100, 100           # squircle 左上（1024 画布内 824 区域）
SQ_SIZE = 824
SQ_CENTER = (512, 512)
SQ_HALF = SQ_SIZE // 2
SQ_R = 185                        # 圆角半径
CONTENT_BOX = 758                 # squircle 内内容盒


def detect_and_clear(img):
    """定位双屏色域矩形，清除保留区外的白底板/光斑/灰雾"""
    w, h = img.size
    px = img.load()
    moon = [w, -1, h, -1]
    sun = [w, -1, h, -1]
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a <= 200:
                continue
            if b > 130 and b > r + 40:
                moon[0] = min(moon[0], x); moon[1] = max(moon[1], x)
                moon[2] = min(moon[2], y); moon[3] = max(moon[3], y)
            elif r > 180 and r > b + 60:
                sun[0] = min(sun[0], x); sun[1] = max(sun[1], x)
                sun[2] = min(sun[2], y); sun[3] = max(sun[3], y)
    if moon[1] < 0 or sun[1] < 0:
        sys.exit("❌ 未检测到双屏色块")
    print(f"月屏（蓝）: x[{moon[0]},{moon[1]}] y[{moon[2]},{moon[3]}]")
    print(f"日落屏（暖）: x[{sun[0]},{sun[1]}] y[{sun[2]},{sun[3]}]")

    moon_rect = (max(0, moon[0] - KEEP_PAD), max(0, moon[2] - KEEP_PAD),
                 min(w, moon[1] + KEEP_PAD), min(h, moon[3] + KEEP_PAD))
    sun_rect = (max(0, sun[0] - KEEP_PAD), max(0, sun[2] - KEEP_PAD),
                min(w, sun[1] + KEEP_PAD), min(h, sun[3] + KEEP_PAD))

    for y in range(h):
        for x in range(w):
            in_moon = moon_rect[0] <= x <= moon_rect[2] and moon_rect[1] <= y <= moon_rect[3]
            in_sun = sun_rect[0] <= x <= sun_rect[2] and sun_rect[1] <= y <= sun_rect[3]
            if not in_moon and not in_sun:
                px[x, y] = (0, 0, 0, 0)
    return img


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    logo_only = "--logo-only" in sys.argv[2:]
    if src is None or not src.is_file():
        sys.exit("❌ 请提供源图路径")

    img = Image.open(src).convert("RGBA")
    detect_and_clear(img)
    clean_path = OUT / "logo/moonrise-logo-source-clean.png"
    clean_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(clean_path)
    print("✓ 白底板抠图完成 → logo/moonrise-logo-source-clean.png")

    cropped = img.crop(CROP)
    side = cropped.width + 20
    master = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    master.paste(cropped, (10, (side - cropped.height) // 2))
    master_path = OUT / "logo/moonrise-icon-master.png"
    master.save(master_path)
    print(f"✓ master {side}×{side}")
    for size in (1024, 512, 256, 128):
        master.resize((size, size), Image.LANCZOS).save(OUT / f"logo/moonrise-icon-{size}.png")
        print(f"✓ logo/moonrise-icon-{size}.png @{size}")

    if logo_only:
        print("完成（--logo-only：iconset 未动）")
        return

    # 深墨满幅合成最终 App 图标：墨色铺满 1024 全画布（四角按系统圆角 228 烘焙，
    # 仅角落极小弧区透明），对角光照（左上提亮 → 右下压暗），内容占画布 ~81% 居中
    app = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    mask = Image.new("L", (1024, 1024), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 1023, 1023), radius=228, fill=255)
    base = Image.new("RGBA", (1024, 1024))
    bpx = base.load()
    for y in range(1024):
        t = min(max((x_span := (x + y - 100)) / 1648, 0.0), 1.0) if False else min(max((x + y - 100) / 1648, 0.0), 1.0)
        k = 1 + 0.12 * (1 - t) - 0.16 * t
        for x in range(1024):
            t = min(max((x + y - 100) / 1648, 0.0), 1.0)
            k = 1 + 0.12 * (1 - t) - 0.16 * t
            bpx[x, y] = (min(255, int(16 * k)), min(255, int(19 * k)), min(255, int(24 * k)), 255)
    base.putalpha(mask)
    app.paste(base, (0, 0))

    box = 830
    scale = box / cropped.width
    tw, th = int(cropped.width * scale), int(cropped.height * scale)
    art = cropped.resize((tw, th), Image.LANCZOS)
    app.paste(art, ((1024 - tw) // 2, (1024 - th) // 2), art)
    app_path = OUT / "logo/moonrise-icon-app-1024.png"
    app.save(app_path)
    app.resize((256, 256), Image.LANCZOS).save(OUT / "logo/moonrise-icon-app-256.png")
    print("✓ 深墨合成 App 图标 → logo/moonrise-icon-app-{1024,256}.png")

    iconset = OUT / "MoonRise.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    for name, size in [("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
                       ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
                       ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
                       ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
                       ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)]:
        app.resize((size, size), Image.LANCZOS).save(iconset / name)
        print(f"✓ MoonRise.iconset/{name} @{size}")
    print("完成：bash scripts/install-app.sh 重编译 .icns 并重装")


if __name__ == "__main__":
    main()
