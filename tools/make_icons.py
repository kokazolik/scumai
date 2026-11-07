"""Рисует белые значки игры в icons/*.png (128x128). Запуск: python3 tools/make_icons.py
Каждый значок задан в сетке 100x100, рисуется в 8 раз крупнее и уменьшается для сглаживания.
В игре значки перекрашиваются (Button icon color / modulate)."""
import math
import os
from PIL import Image, ImageDraw

S = 8
OUT = os.path.join(os.path.dirname(__file__), "..", "icons")
W = (255, 255, 255, 255)
X = (0, 0, 0, 0)  # стирание


class Pen:
    def __init__(self):
        self.im = Image.new("RGBA", (100 * S, 100 * S), X)
        self.d = ImageDraw.Draw(self.im)

    def p(self, x, y):
        return (x * S, y * S)

    def circle(self, x, y, r, c=W):
        self.d.ellipse([(x - r) * S, (y - r) * S, (x + r) * S, (y + r) * S], fill=c)

    def ring(self, x, y, r, w, c=W):
        self.d.ellipse([(x - r) * S, (y - r) * S, (x + r) * S, (y + r) * S], outline=c, width=int(w * S))

    def ellipse(self, x0, y0, x1, y1, c=W):
        self.d.ellipse([x0 * S, y0 * S, x1 * S, y1 * S], fill=c)

    def rect(self, x0, y0, x1, y1, r=0, c=W):
        self.d.rounded_rectangle([x0 * S, y0 * S, x1 * S, y1 * S], radius=r * S, fill=c)

    def frame(self, x0, y0, x1, y1, r, w, c=W):
        self.d.rounded_rectangle([x0 * S, y0 * S, x1 * S, y1 * S], radius=r * S, outline=c, width=int(w * S))

    def poly(self, pts, c=W):
        self.d.polygon([self.p(*q) for q in pts], fill=c)

    def line(self, pts, w, c=W):
        pts = [self.p(*q) for q in pts]
        self.d.line(pts, fill=c, width=int(w * S))
        for q in pts:
            r = w * S / 2
            self.d.ellipse([q[0] - r, q[1] - r, q[0] + r, q[1] + r], fill=c)

    def arc(self, x, y, r, a0, a1, w, c=W, caps=True):
        self.d.arc([(x - r) * S, (y - r) * S, (x + r) * S, (y + r) * S], a0, a1, fill=c, width=int(w * S))
        if caps:
            rm = r - w / 2
            for a in (a0, a1):
                t = math.radians(a)
                self.circle(x + rm * math.cos(t), y + rm * math.sin(t), w / 2, c)

    def star(self, x, y, ro, ri, n=5, rot=-90, c=W):
        pts = []
        for i in range(n * 2):
            r = ro if i % 2 == 0 else ri
            a = math.radians(rot + i * 180 / n)
            pts.append((x + r * math.cos(a), y + r * math.sin(a)))
        self.poly(pts, c)

    def save(self, name):
        self.im.resize((128, 128), Image.LANCZOS).save(os.path.join(OUT, name + ".png"))


ICONS = {}


def icon(f):
    ICONS[f.__name__] = f
    return f


# ---------- интерфейс ----------

@icon
def menu(g):
    for y in (26, 50, 74):
        g.line([(20, y), (80, y)], 11)


@icon
def back(g):
    g.line([(62, 16), (32, 50), (62, 84)], 13)


@icon
def phone(g):  # старый телефон
    g.rect(10, 18, 90, 34, 8)
    g.rect(10, 22, 30, 44, 7)
    g.rect(70, 22, 90, 44, 7)
    g.poly([(30, 40), (70, 40), (86, 84), (14, 84)])
    g.rect(14, 76, 86, 90, 6)
    g.ring(50, 62, 14, 5, X)
    g.circle(50, 62, 4, X)


@icon
def handset(g):  # трубка, положить
    g.arc(50, 70, 36, 200, 340, 15, caps=False)
    g.rect(8, 50, 34, 72, 8)
    g.rect(66, 50, 92, 72, 8)


@icon
def ring_call(g):  # звонок: трубка и волны
    g.arc(50, 74, 34, 200, 340, 14, caps=False)
    g.rect(10, 56, 34, 76, 8)
    g.rect(66, 56, 90, 76, 8)
    g.arc(50, 46, 14, 220, 320, 6)
    g.arc(50, 46, 27, 225, 315, 6)


@icon
def terminal(g):
    g.rect(24, 6, 76, 94, 12)
    g.rect(32, 15, 68, 40, 4, X)
    for row in range(3):
        for col in range(3):
            x = 34 + col * 12
            y = 50 + row * 12
            g.rect(x, y, x + 8, y + 7, 2, X)


@icon
def star(g):
    g.star(50, 53, 44, 19)


@icon
def sparkles(g):
    g.star(42, 56, 36, 9, 4, 0)
    g.star(76, 22, 16, 4, 4, 0)
    g.star(80, 80, 10, 3, 4, 0)


@icon
def cart(g):
    g.line([(6, 18), (20, 18), (30, 66), (78, 66)], 8)
    g.poly([(22, 26), (92, 26), (82, 56), (28, 56)])
    g.circle(36, 82, 8)
    g.circle(72, 82, 8)


@icon
def help(g):
    g.arc(50, 34, 20, 170, 400, 12)
    g.line([(60, 48), (50, 56), (50, 64)], 12)
    g.circle(50, 84, 8)


@icon
def key(g):
    g.ring(30, 50, 18, 11)
    g.line([(48, 50), (88, 50)], 11)
    g.line([(76, 50), (76, 66)], 10)
    g.line([(88, 50), (88, 62)], 10)


@icon
def save(g):
    g.poly([(14, 10), (74, 10), (90, 26), (90, 90), (10, 90), (10, 14)])
    g.rect(26, 10, 66, 34, 2, X)
    g.rect(52, 14, 60, 30, 1)
    g.rect(22, 52, 78, 82, 4, X)
    g.line([(30, 62), (70, 62)], 4)
    g.line([(30, 72), (62, 72)], 4)


@icon
def refresh(g):  # новая игра: плюс в круге
    g.circle(50, 50, 44)
    g.line([(50, 28), (50, 72)], 11, X)
    g.line([(28, 50), (72, 50)], 11, X)


@icon
def copy(g):
    g.frame(8, 8, 62, 62, 10, 9)
    g.rect(34, 34, 92, 92, 12)
    g.rect(43, 43, 83, 83, 6, X)


@icon
def send(g):
    g.poly([(8, 14), (94, 50), (8, 86), (20, 50)])
    g.poly([(20, 50), (60, 50), (20, 54)], X)


@icon
def flame(g):
    g.circle(50, 64, 30)
    g.poly([(22, 54), (52, 2), (78, 54)])
    g.circle(50, 72, 12, X)
    g.poly([(39, 68), (51, 40), (61, 68)], X)


@icon
def coin(g):
    g.circle(50, 50, 44)
    g.ring(50, 50, 36, 4, X)
    g.line([(42, 28), (42, 74)], 7, X)
    g.arc(46, 40, 12, 270, 450, 7, X)
    g.line([(42, 29), (46, 29)], 7, X)
    g.line([(42, 51), (46, 51)], 7, X)
    g.line([(34, 62), (56, 62)], 6, X)


@icon
def target(g):
    g.ring(50, 50, 42, 9)
    g.ring(50, 50, 24, 9)
    g.circle(50, 50, 8)


@icon
def crown(g):
    g.poly([(8, 30), (30, 52), (50, 18), (70, 52), (92, 30), (82, 76), (18, 76)])
    g.rect(18, 80, 82, 90, 3)
    for x, y in ((8, 28), (50, 15), (92, 28)):
        g.circle(x, y, 7)


@icon
def check(g):
    g.line([(14, 52), (38, 76), (86, 24)], 15)


@icon
def lock(g):
    g.arc(50, 40, 22, 180, 360, 10, caps=False)
    g.line([(28, 40), (28, 46)], 10)
    g.line([(72, 40), (72, 46)], 10)
    g.rect(16, 44, 84, 92, 10)
    g.circle(50, 62, 7, X)
    g.rect(46, 64, 54, 78, 2, X)


@icon
def card(g):
    g.rect(6, 20, 94, 80, 10)
    g.rect(6, 32, 94, 44, 0, X)
    g.rect(16, 56, 40, 68, 3, X)


@icon
def gift(g):
    g.rect(14, 46, 86, 92, 6)
    g.rect(8, 30, 92, 46, 5)
    g.rect(45, 30, 55, 92, 0, X)
    g.rect(14, 46, 86, 50, 0, X)
    g.ring(38, 20, 10, 6)
    g.ring(62, 20, 10, 6)


@icon
def trophy(g):
    g.poly([(24, 10), (76, 10), (72, 44), (60, 58), (40, 58), (28, 44)])
    g.arc(22, 26, 14, 90, 270, 7, caps=False)
    g.arc(78, 26, 14, 270, 450, 7, caps=False)
    g.rect(44, 56, 56, 74, 0)
    g.rect(28, 74, 72, 90, 4)


@icon
def chart(g):
    for i, h in enumerate((30, 50, 70)):
        x = 14 + i * 26
        g.rect(x, 88 - h, x + 18, 88, 4)
    g.line([(12, 40), (40, 26), (56, 34), (86, 10)], 6)


@icon
def mic(g):
    g.rect(36, 6, 64, 60, 14)
    g.arc(50, 42, 26, 0, 180, 7)
    g.line([(50, 70), (50, 86)], 7)
    g.line([(34, 88), (66, 88)], 7)


# ---------- навыки ----------

@icon
def heart(g):
    g.circle(31, 38, 23)
    g.circle(69, 38, 23)
    g.poly([(10, 46), (90, 46), (50, 90)])
    g.poly([(30, 20), (70, 20), (50, 54)])


@icon
def speech(g):
    g.rect(6, 12, 94, 72, 22)
    g.poly([(22, 66), (44, 66), (16, 92)])
    for x in (30, 50, 70):
        g.circle(x, 42, 7, X)


@icon
def percent(g):
    g.ring(28, 28, 14, 9)
    g.ring(72, 72, 14, 9)
    g.line([(78, 14), (22, 86)], 10)


@icon
def snowflake(g):
    for a in (90, 30, 150, 270, 210, 330):
        t = math.radians(a)
        g.line([(50, 50), (50 + 42 * math.cos(t), 50 + 42 * math.sin(t))], 8)
        ex, ey = 50 + 26 * math.cos(t), 50 + 26 * math.sin(t)
        for b in (45, -45):
            tb = math.radians(a + b)
            g.line([(ex, ey), (ex + 14 * math.cos(tb), ey + 14 * math.sin(tb))], 6)


@icon
def clock(g):
    g.ring(50, 50, 42, 10)
    g.line([(50, 26), (50, 52), (68, 62)], 9)


@icon
def hourglass(g):
    g.rect(18, 6, 82, 16, 4)
    g.rect(18, 84, 82, 94, 4)
    g.poly([(24, 16), (76, 16), (54, 50), (76, 84), (24, 84), (46, 50)])
    g.poly([(34, 22), (66, 22), (50, 44)], X)
    g.poly([(50, 62), (64, 78), (36, 78)], X)
    g.poly([(50, 66), (60, 78), (40, 78)])


# ---------- схемы ----------

@icon
def megaphone(g):  # объявления
    g.poly([(14, 38), (52, 38), (86, 14), (86, 86), (52, 62), (14, 62)])
    g.rect(8, 36, 22, 64, 4)
    g.poly([(26, 62), (44, 62), (50, 90), (34, 90)])


@icon
def house(g):
    g.poly([(50, 8), (94, 46), (6, 46)])
    g.rect(16, 42, 84, 92, 4)
    g.rect(42, 62, 58, 92, 3, X)
    g.rect(66, 14, 78, 34, 1)


@icon
def parcel(g):
    g.poly([(50, 6), (92, 26), (92, 74), (50, 94), (8, 74), (8, 26)])
    g.line([(8, 26), (50, 46), (92, 26)], 5, X)
    g.line([(50, 46), (50, 94)], 5, X)
    g.poly([(26, 16), (68, 36), (68, 50), (60, 46), (60, 40), (18, 20)], X)


@icon
def briefcase(g):
    g.frame(34, 8, 66, 30, 8, 8)
    g.rect(6, 26, 94, 88, 10)
    g.rect(6, 50, 94, 56, 0, X)
    g.rect(42, 44, 58, 62, 3)


@icon
def gradcap(g):
    g.poly([(50, 12), (96, 34), (50, 56), (4, 34)])
    g.poly([(24, 46), (76, 46), (76, 72), (50, 84), (24, 72)])
    g.line([(86, 38), (86, 70)], 5)
    g.circle(86, 74, 6)


@icon
def wand(g):
    g.line([(14, 86), (60, 40)], 11)
    g.star(70, 30, 26, 10)
    g.star(24, 22, 10, 3, 4, 0)
    g.star(86, 76, 8, 3, 4, 0)


@icon
def pill(g):
    g.line([(28, 72), (72, 28)], 34)
    g.line([(36, 36), (64, 64)], 5, X)
    g.line([(26, 60), (36, 50)], 5, X)


@icon
def crystal(g):
    g.circle(50, 42, 34)
    g.arc(50, 42, 24, 200, 250, 6, X)
    g.poly([(26, 74), (74, 74), (84, 94), (16, 94)])


@icon
def diamond_ring(g):  # принц
    g.ring(50, 64, 26, 9)
    g.poly([(34, 22), (66, 22), (76, 32), (50, 50), (24, 32)])
    g.line([(34, 22), (42, 32), (50, 22), (58, 32), (66, 22)], 3, X)


@icon
def scroll(g):  # наследство
    g.poly([(14, 6), (64, 6), (86, 28), (86, 94), (14, 94)])
    g.poly([(64, 6), (64, 28), (86, 28)], X)
    g.poly([(64, 10), (82, 28), (64, 28)])
    for y in (34, 46, 58):
        g.line([(26, y), (60, y)], 5, X)
    g.circle(66, 76, 11, X)
    g.circle(66, 76, 7)


@icon
def bitcoin(g):
    g.circle(50, 50, 44)
    g.line([(40, 26), (40, 74)], 8, X)
    g.arc(48, 38, 11, 270, 450, 8, X)
    g.arc(50, 61, 13, 270, 450, 8, X)
    g.line([(34, 27), (48, 27)], 8, X)
    g.line([(34, 74), (50, 74)], 8, X)
    g.line([(46, 18), (46, 26)], 5, X)
    g.line([(46, 74), (46, 82)], 5, X)


@icon
def pyramid(g):
    g.poly([(50, 6), (96, 90), (4, 90)])
    for y in (36, 60):
        g.rect(0, y, 100, y + 6, 0, X)


@icon
def cloud(g):
    g.circle(34, 56, 20)
    g.circle(56, 42, 26)
    g.circle(76, 60, 16)
    g.rect(14, 56, 92, 76, 10)


@icon
def moon(g):
    g.circle(50, 50, 42)
    g.circle(70, 36, 34, X)
    g.star(78, 70, 9, 3, 4, 0)


@icon
def rocket(g):
    g.ellipse(34, 6, 66, 76)
    g.poly([(34, 50), (16, 76), (34, 72)])
    g.poly([(66, 50), (84, 76), (66, 72)])
    g.circle(50, 34, 8, X)
    g.poly([(40, 78), (60, 78), (50, 96)])


@icon
def sun(g):
    g.circle(50, 50, 22)
    for i in range(8):
        t = math.radians(i * 45)
        g.line([(50 + 32 * math.cos(t), 50 + 32 * math.sin(t)), (50 + 44 * math.cos(t), 50 + 44 * math.sin(t))], 8)


@icon
def infinity(g):
    pts = []
    for i in range(121):
        t = i / 120 * 2 * math.pi
        k = 1 + math.sin(t) ** 2
        pts.append((50 + 42 * math.cos(t) / k, 50 + 42 * math.sin(t) * math.cos(t) / k))
    g.line(pts, 11)


# ---------- оплата и улучшения ----------

@icon
def smartphone(g):
    g.rect(26, 4, 74, 96, 12)
    g.rect(32, 16, 68, 78, 3, X)
    g.circle(50, 87, 4, X)


@icon
def safe(g):
    g.rect(6, 8, 94, 86, 10)
    g.ring(50, 46, 22, 7, X)
    g.line([(50, 30), (50, 62)], 5, X)
    g.line([(34, 46), (66, 46)], 5, X)
    g.rect(14, 86, 28, 94, 2)
    g.rect(72, 86, 86, 94, 2)


@icon
def bank(g):
    g.poly([(50, 4), (96, 28), (4, 28)])
    g.rect(6, 30, 94, 38, 2)
    for x in (14, 34, 56, 76):
        g.rect(x, 42, x + 10, 78, 2)
    g.rect(4, 82, 96, 92, 2)


@icon
def book(g):
    g.poly([(6, 18), (46, 26), (46, 90), (6, 82)])
    g.poly([(54, 26), (94, 18), (94, 82), (54, 90)])
    for y in (40, 52, 64):
        g.line([(14, y - 6), (38, y)], 4, X)
        g.line([(62, y), (86, y - 6)], 4, X)


@icon
def cup(g):
    g.rect(12, 36, 70, 88, 14)
    g.rect(12, 36, 70, 52, 0)
    g.ring(76, 60, 14, 8)
    g.arc(32, 18, 8, 90, 270, 5)
    g.arc(52, 18, 8, 90, 270, 5)


@icon
def antenna(g):  # подменный номер
    g.rect(32, 36, 68, 96, 9)
    g.rect(38, 46, 62, 80, 2, X)
    g.arc(50, 30, 16, 220, 320, 6)
    g.arc(50, 30, 30, 220, 320, 6)


@icon
def scales(g):
    g.line([(50, 10), (50, 84)], 8)
    g.rect(28, 82, 72, 92, 4)
    g.line([(14, 22), (86, 22)], 7)
    g.line([(16, 24), (6, 54)], 3)
    g.line([(16, 24), (26, 54)], 3)
    g.line([(84, 24), (74, 54)], 3)
    g.line([(84, 24), (94, 54)], 3)
    g.d.chord([0 * S, 40 * S, 32 * S, 70 * S], 0, 180, fill=W)
    g.d.chord([68 * S, 40 * S, 100 * S, 70 * S], 0, 180, fill=W)


@icon
def database(g):
    for y in (70, 46, 22):
        g.rect(14, y - 10, 86, y + 14, 0)
        g.ellipse(14, y + 4, 86, y + 22)
        g.ellipse(14, y - 18, 86, y + 2)
        g.d.arc([14 * S, (y + 4) * S, 86 * S, (y + 22) * S], 0, 180, fill=X, width=4 * S)
    g.ellipse(22, 7, 78, 17, X)
    g.ellipse(26, 9, 74, 15)


@icon
def mask(g):
    g.poly([(10, 14), (50, 22), (90, 14), (86, 56), (50, 92), (14, 56)])
    g.circle(48, 70, 40, X) if False else None
    g.ellipse(24, 38, 42, 50, X)
    g.ellipse(58, 38, 76, 50, X)
    g.arc(50, 56, 18, 20, 160, 6, X)


@icon
def building(g):
    g.rect(14, 4, 66, 96, 4)
    g.rect(66, 36, 90, 96, 3)
    for row in range(6):
        for col in range(3):
            x = 22 + col * 15
            y = 12 + row * 13
            g.rect(x, y, x + 8, y + 7, 1, X)
    g.rect(72, 46, 84, 54, 1, X)
    g.rect(72, 62, 84, 70, 1, X)
    g.rect(72, 78, 84, 86, 1, X)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, f in ICONS.items():
        g = Pen()
        f(g)
        g.save(name)
    # лист для проверки
    names = list(ICONS)
    cols = 10
    sheet = Image.new("RGBA", (cols * 140, ((len(names) + cols - 1) // cols) * 140), (40, 50, 90, 255))
    for i, n in enumerate(names):
        im = Image.open(os.path.join(OUT, n + ".png"))
        sheet.alpha_composite(im, ((i % cols) * 140 + 6, (i // cols) * 140 + 6))
    sheet.save(os.environ.get("SHEET", "/tmp/icons_sheet.png"))
    print(len(names), "icons")
