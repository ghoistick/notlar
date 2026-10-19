from PIL import Image, ImageDraw
import math

S = 1024  # çizim çözünürlüğü; küçük boyutlar bundan küçültülür

CINI = (30, 90, 168)        # çini mavisi
CINI_DARK = (22, 66, 128)
PAPER = (247, 247, 242)
PAPER_SHADE = (222, 226, 232)
INK = (29, 39, 51)          # lacivert mürekkep

def rounded_square(draw, box, r, fill):
    draw.rounded_rectangle(box, radius=r, fill=fill)

def make(size_hint=S):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Zemin: çini mavisi, yumuşak köşeli kare
    m = 40
    rounded_square(d, (m, m, S - m, S - m), 210, CINI)
    # Altta hafif koyu bant: derinlik
    band = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(band)
    bd.rounded_rectangle((m, m, S - m, S - m), radius=210, fill=CINI_DARK)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rectangle((0, int(S * 0.78), S, S), fill=255)


    # Kâğıt: hafif eğik, sağ üst köşesi kıvrık
    pw, ph = 560, 700
    cx, cy = S / 2 + 6, S / 2 + 4
    fold = 150
    paper = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    pd = ImageDraw.Draw(paper)
    x0, y0 = cx - pw / 2, cy - ph / 2
    x1, y1 = cx + pw / 2, cy + ph / 2
    body = [(x0, y0), (x1 - fold, y0), (x1, y0 + fold), (x1, y1), (x0, y1)]
    pd.polygon(body, fill=PAPER)
    # Kıvrık köşe
    pd.polygon([(x1 - fold, y0), (x1 - fold, y0 + fold), (x1, y0 + fold)], fill=PAPER_SHADE)

    # Mürekkep satırları: farklı uzunluklarda, hafif dalgalı karalama
    lw = 34
    lines = [(0.0, 0.78), (0.0, 0.62), (0.0, 0.84), (0.0, 0.45)]
    top = y0 + 170
    gap = 112
    for i, (start, length) in enumerate(lines):
        y = top + i * gap
        xs = x0 + 70
        xe = xs + (pw - 140) * length
        pts = []
        steps = 120
        for k in range(steps + 1):
            t = k / steps
            x = xs + (xe - xs) * t
            wobble = math.sin(t * math.pi * 3 + i) * 4
            pts.append((x, y + wobble))
        # Fırça: yol boyunca sık aralıklı daireler, pürüzsüz kalın çizgi
        for k in range(len(pts) - 1):
            (ax, ay), (bx, by) = pts[k], pts[k + 1]
            n = 6
            for j in range(n):
                t = j / n
                px, py = ax + (bx - ax) * t, ay + (by - ay) * t
                pd.ellipse((px - lw / 2, py - lw / 2, px + lw / 2, py + lw / 2), fill=INK)
        px, py = pts[-1]
        pd.ellipse((px - lw / 2, py - lw / 2, px + lw / 2, py + lw / 2), fill=INK)

    paper = paper.rotate(-6, resample=Image.BICUBIC, center=(cx, cy))

    # Kâğıdın gölgesi
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.paste((10, 30, 60, 90), (0, 0), paper.split()[3])
    from PIL import ImageFilter
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    img.alpha_composite(shadow, (8, 18))
    img.alpha_composite(paper)
    return img

big = make()
big.save("musvedde_1024.png")
sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
big.save("app_icon.ico", sizes=[(s, s) for s in sizes])

# Önizleme: farklı boyutlar yan yana
prev = Image.new("RGBA", (1100, 300), (245, 246, 244, 255))
x = 20
for s in [256, 128, 64, 48, 32, 16]:
    im = big.resize((s, s), Image.LANCZOS)
    prev.alpha_composite(im, (x, 150 - s // 2))
    x += s + 40
dark = Image.new("RGBA", (1100, 300), (18, 23, 29, 255))
x = 20
for s in [256, 128, 64, 48, 32, 16]:
    im = big.resize((s, s), Image.LANCZOS)
    dark.alpha_composite(im, (x, 150 - s // 2))
    x += s + 40
both = Image.new("RGBA", (1100, 600))
both.paste(prev, (0, 0)); both.paste(dark, (0, 300))
both.save("preview.png")
print("ok")
