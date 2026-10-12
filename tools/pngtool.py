"""纯 Python 的极简 PNG 读写（避免额外依赖）。

只支持 8bit / 无隔行（非 Adam7）的 PNG，覆盖常见导出格式：
  colorType 0 灰度、2 RGB、3 调色板、4 灰度+Alpha、6 RGBA。
用途：读取源图标 -> 生成 HarmonyOS 分层图标的前景/背景。
"""
import struct
import zlib


def read_png(path):
    with open(path, 'rb') as f:
        data = f.read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('not a png: ' + path)
    pos = 8
    width = height = bitdepth = colortype = -1
    interlace = 0
    idat = bytearray()
    plte = b''
    trns = b''
    while pos + 8 <= len(data):
        (length,) = struct.unpack('>I', data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length  # len + type + data + crc
        if ctype == b'IHDR':
            width, height, bitdepth, colortype, _c, _f, interlace = struct.unpack('>IIBBBBB', chunk)
        elif ctype == b'PLTE':
            plte = chunk
        elif ctype == b'tRNS':
            trns = chunk
        elif ctype == b'IDAT':
            idat += chunk
        elif ctype == b'IEND':
            break
    if bitdepth != 8:
        raise ValueError('only 8-bit png supported, got %d' % bitdepth)
    if interlace != 0:
        raise ValueError('interlaced png not supported')
    raw = zlib.decompress(bytes(idat))
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colortype]
    stride = width * channels
    out = bytearray(width * height * 4)
    prev = bytearray(stride)
    cur = bytearray(stride)
    p = 0
    for y in range(height):
        ft = raw[p]
        p += 1
        cur[:] = raw[p:p + stride]
        p += stride
        if ft == 1:
            for i in range(channels, stride):
                cur[i] = (cur[i] + cur[i - channels]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                cur[i] = (cur[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                a = cur[i - channels] if i >= channels else 0
                cur[i] = (cur[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = cur[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                pa = abs(b - c)
                pb = abs(a - c)
                pc = abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                cur[i] = (cur[i] + pr) & 0xFF
        prev[:] = cur
        base = y * width * 4
        for x in range(width):
            s = x * channels
            d = base + x * 4
            if colortype == 6:
                out[d] = cur[s]
                out[d + 1] = cur[s + 1]
                out[d + 2] = cur[s + 2]
                out[d + 3] = cur[s + 3]
            elif colortype == 2:
                out[d] = cur[s]
                out[d + 1] = cur[s + 1]
                out[d + 2] = cur[s + 2]
                out[d + 3] = 255
            elif colortype == 0:
                out[d] = out[d + 1] = out[d + 2] = cur[s]
                out[d + 3] = 255
            elif colortype == 4:
                out[d] = out[d + 1] = out[d + 2] = cur[s]
                out[d + 3] = cur[s + 1]
            else:  # palette
                idx = cur[s]
                out[d] = plte[idx * 3]
                out[d + 1] = plte[idx * 3 + 1]
                out[d + 2] = plte[idx * 3 + 2]
                out[d + 3] = trns[idx] if idx < len(trns) else 255
    return width, height, bytes(out)


def write_png(path, width, height, rgba):
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)
        raw += rgba[y * stride:(y + 1) * stride]
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    body = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(body)


def sample(width, height, rgba, pts):
    out = []
    for (x, y) in pts:
        i = (y * width + x) * 4
        out.append((x, y, rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]))
    return out


def resize_bilinear(sw, sh, src, dw, dh):
    dst = bytearray(dw * dh * 4)
    xr = (sw - 1) / max(1, dw - 1)
    yr = (sh - 1) / max(1, dh - 1)
    for y in range(dh):
        fy = y * yr
        y0 = int(fy)
        y1 = min(y0 + 1, sh - 1)
        wy = fy - y0
        r0 = y0 * sw * 4
        r1 = y1 * sw * 4
        drow = y * dw * 4
        for x in range(dw):
            fx = x * xr
            x0 = int(fx)
            x1 = min(x0 + 1, sw - 1)
            wx = fx - x0
            i00 = r0 + x0 * 4
            i01 = r0 + x1 * 4
            i10 = r1 + x0 * 4
            i11 = r1 + x1 * 4
            d = drow + x * 4
            for c in range(4):
                a = src[i00 + c] * (1 - wx) + src[i01 + c] * wx
                b = src[i10 + c] * (1 - wx) + src[i11 + c] * wx
                dst[d + c] = int(a * (1 - wy) + b * wy + 0.5)
    return bytes(dst)


def paste_center(canvas_w, canvas_h, canvas, img_w, img_h, img):
    off_x = (canvas_w - img_w) // 2
    off_y = (canvas_h - img_h) // 2
    for y in range(img_h):
        cy = off_y + y
        if cy < 0 or cy >= canvas_h:
            continue
        srow = y * img_w * 4
        drow = (cy * canvas_w + off_x) * 4
        canvas[drow:drow + img_w * 4] = img[srow:srow + img_w * 4]


def solid(w, h, r, g, b, a=255):
    return bytes([r, g, b, a]) * (w * h)
