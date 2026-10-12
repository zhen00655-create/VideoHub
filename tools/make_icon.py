"""由一张源 PNG 生成 HarmonyOS 分层图标所需的 foreground / background / 启动图。

用法: python make_icon.py <源png>

产出（覆盖写入）：
  AppScope/resources/base/media/foreground.png
  AppScope/resources/base/media/background.png
  entry/src/main/resources/base/media/foreground.png
  entry/src/main/resources/base/media/background.png
  entry/src/main/resources/base/media/startIcon.png   (前景合成到背景后的不透明图)

分层图标规范：画布 1024x1024，前景内容控制在中间约 66% 的安全区内，
避免被启动器裁成圆形/圆角方形时切到边缘。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngtool

CANVAS = 1024
# 前景整体缩放：512 -> 768，内容实际占画布约 71%，落在安全区内
FOREGROUND_SCALE = 1.5
# 背景色取自源图标卡片主体色（#4B29A2）
BG_R, BG_G, BG_B = 75, 41, 162

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def build(src_path):
    sw, sh, spx = pngtool.read_png(src_path)
    print('source: %dx%d' % (sw, sh))

    # 前景：等比放大后居中贴到透明画布
    fw = int(round(sw * FOREGROUND_SCALE))
    fh = int(round(sh * FOREGROUND_SCALE))
    fg_img = pngtool.resize_bilinear(sw, sh, spx, fw, fh)
    fg = bytearray(CANVAS * CANVAS * 4)
    pngtool.paste_center(CANVAS, CANVAS, fg, fw, fh, fg_img)
    fg = bytes(fg)

    # 背景：纯色
    bg = pngtool.solid(CANVAS, CANVAS, BG_R, BG_G, BG_B, 255)

    # 启动图：前景 alpha 合成到背景上（startWindowIcon 只接受单张不透明图）
    comp = bytearray(CANVAS * CANVAS * 4)
    for i in range(0, len(comp), 4):
        a = fg[i + 3]
        if a == 0:
            comp[i] = BG_R
            comp[i + 1] = BG_G
            comp[i + 2] = BG_B
        elif a == 255:
            comp[i] = fg[i]
            comp[i + 1] = fg[i + 1]
            comp[i + 2] = fg[i + 2]
        else:
            ia = 255 - a
            comp[i] = (fg[i] * a + BG_R * ia) // 255
            comp[i + 1] = (fg[i + 1] * a + BG_G * ia) // 255
            comp[i + 2] = (fg[i + 2] * a + BG_B * ia) // 255
        comp[i + 3] = 255

    targets = [
        (os.path.join(ROOT, 'AppScope', 'resources', 'base', 'media'), True),
        (os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'media'), True),
    ]
    for d, with_start in targets:
        if not os.path.isdir(d):
            print('skip (no dir):', d)
            continue
        pngtool.write_png(os.path.join(d, 'foreground.png'), CANVAS, CANVAS, fg)
        pngtool.write_png(os.path.join(d, 'background.png'), CANVAS, CANVAS, bg)
        if with_start:
            pngtool.write_png(os.path.join(d, 'startIcon.png'), CANVAS, CANVAS, bytes(comp))
        print('written:', d)


if __name__ == '__main__':
    src = sys.argv[1] if len(sys.argv) > 1 else r'E:\download\movies_icon-icons.com_76714.png'
    build(src)
