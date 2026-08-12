#!/usr/bin/env python3
"""Generate the huge-pages post figures as self-contained SVG.

Palette matches the site's dark hacker theme and the existing inline
visualization in _posts/2025-12-11-pg_dump-Format.md.
"""
import math
import os

OUT = "/Users/maratbogatyrev/repo/boosterKRD.github.io/assets/posts"

BG = "#1a1a1a"
GREEN = "#b5e853"
WHITE = "#ffffff"
DIM = "#9aa0a6"
RED = "#e57373"
REDD = "#c62828"
AMBER = "#ffb74d"
BLUE = "#64b5f6"
PANEL = "#242424"
STROKE = "#3a3a3a"
FONT = "Menlo,Consolas,'DejaVu Sans Mono',monospace"


def head(w, h):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
        f'width="{w}" height="{h}" font-family="{FONT}" role="img">\n'
        f'<rect x="0" y="0" width="{w}" height="{h}" fill="{BG}" rx="8"/>\n'
        '<defs>\n'
        f'<marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" '
        f'markerHeight="6" orient="auto-start-reverse">'
        f'<path d="M0,0 L10,5 L0,10 z" fill="{DIM}"/></marker>\n'
        f'<marker id="ag" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" '
        f'markerHeight="6" orient="auto-start-reverse">'
        f'<path d="M0,0 L10,5 L0,10 z" fill="{GREEN}"/></marker>\n'
        f'<marker id="ar" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" '
        f'markerHeight="6" orient="auto-start-reverse">'
        f'<path d="M0,0 L10,5 L0,10 z" fill="{RED}"/></marker>\n'
        '</defs>\n'
    )


def txt(x, y, s, fill=WHITE, size=13, anchor="middle", weight="normal", style=""):
    st = f' font-style="{style}"' if style else ""
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return (f'<text x="{x}" y="{y}" fill="{fill}" font-size="{size}" '
            f'text-anchor="{anchor}" font-weight="{weight}"{st}>{s}</text>\n')


def box(x, y, w, h, label, stroke=STROKE, fill=PANEL, tc=WHITE, size=13, rx=6, sw=1.5):
    o = (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}" '
         f'stroke="{stroke}" stroke-width="{sw}" rx="{rx}"/>\n')
    lines = label.split("|")
    n = len(lines)
    for i, ln in enumerate(lines):
        ty = y + h / 2 + size * 0.36 + (i - (n - 1) / 2) * (size + 4)
        o += txt(x + w / 2, ty, ln, tc, size)
    return o


def arrow(x1, y1, x2, y2, color=DIM, marker="a", dash=None, sw=1.8):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    return (f'<path d="M{x1},{y1} L{x2},{y2}" stroke="{color}" stroke-width="{sw}" '
            f'fill="none" marker-end="url(#{marker})"{d}/>\n')


def write(name, body):
    p = os.path.join(OUT, name)
    with open(p, "w") as f:
        f.write(body + "</svg>\n")
    print("wrote", p)


# ---------------------------------------------------------------- Fig 1
def fig1():
    W, H = 760, 300
    s = head(W, H)
    s += txt(W / 2, 32, "Address translation", GREEN, 16, weight="bold")
    y = 70
    s += box(30, y, 150, 52, "virtual|address")
    s += arrow(180, y + 26, 240, y + 26)
    s += box(240, y, 120, 52, "TLB", GREEN)
    # hit path
    s += arrow(360, y + 26, 430, y + 26, GREEN, "ag")
    s += txt(395, y + 16, "hit", GREEN, 12)
    s += box(430, y, 160, 52, "physical|address", GREEN)
    s += txt(300, y + 78, "miss", RED, 12)
    # miss path down
    s += arrow(300, y + 52, 300, y + 110, RED, "ar")
    y2 = 190
    s += box(215, y2, 170, 56, "page walk|(4 memory reads)", RED, "#2b1c1c", WHITE)
    s += arrow(385, y2 + 28, 445, y2 + 28, RED, "ar")
    s += box(445, y2, 90, 56, "PTE", RED, "#2b1c1c")
    # back up to physical
    s += arrow(535, y2 + 28, 590, y2 + 28, RED, "ar")
    s += f'<path d="M590,{y2+28} L620,{y2+28} L620,{y+26} L595,{y+26}" stroke="{RED}" stroke-width="1.8" fill="none" marker-end="url(#ar)"/>\n'
    s += txt(W / 2, 285, "the highlighted branch is what huge pages eliminate",
             DIM, 12, style="italic")
    write("hugepages-01-translation.svg", s)


# ---------------------------------------------------------------- Fig 2
def fig2():
    W, H = 820, 400
    s = head(W, H)
    s += txt(W / 2, 32, "One physical region, three private page tables", GREEN, 16, weight="bold")
    xs = [60, 320, 580]
    names = ["backend 1", "backend 2", "backend 3"]
    for x, n in zip(xs, names):
        s += box(x, 60, 180, 44, n, GREEN)
        s += arrow(x + 90, 104, x + 90, 134)
        s += box(x, 134, 180, 52, "page table|~32 MB", STROKE, PANEL, AMBER)
    # converge
    for x in xs:
        s += f'<path d="M{x+90},186 L{x+90},228 L410,228 L410,262" stroke="{DIM}" stroke-width="1.8" fill="none" marker-end="url(#a)"/>\n'
    s += box(160, 262, 500, 62, "shared_buffers — 16 GB (one physical copy)", GREEN, "#1e2a12", GREEN, 14)
    s += txt(W / 2, 356, "backend 2 touches the same physical page as backend 1", DIM, 13)
    s += txt(W / 2, 376, "and still takes a minor fault — its own table is empty there", RED, 13)
    write("hugepages-02-process-model.svg", s)


# ---------------------------------------------------------------- Fig 3
def fig3():
    W, H = 780, 330
    s = head(W, H)
    s += txt(W / 2, 32, "First touch of a page inside shared_buffers", GREEN, 16, weight="bold")
    steps = [
        ("3", "backend touches|an address", DIM),
        ("4", "TLB|miss", RED),
        ("5", "page walk|not present", RED),
        ("6", "minor fault|kernel fills PTE", AMBER),
        ("7", "retry|TLB hit", GREEN),
    ]
    x = 28
    w, gap = 132, 16
    for i, (num, label, col) in enumerate(steps):
        s += f'<circle cx="{x+14}" cy="88" r="12" fill="{col}"/>\n'
        s += txt(x + 14, 93, num, BG, 12, weight="bold")
        s += box(x, 106, w, 62, label, col, PANEL, WHITE, 12)
        if i < len(steps) - 1:
            s += arrow(x + w, 137, x + w + gap - 2, 137, col,
                       "ag" if col == GREEN else ("ar" if col == RED else "a"))
        x += w + gap
    last = 28 + 4 * (w + gap)
    s += f'<path d="M{last+w/2},168 L{last+w/2},232 L{28+w/2},232 L{28+w/2},174" stroke="{GREEN}" stroke-width="1.8" fill="none" stroke-dasharray="5,4" marker-end="url(#ag)"/>\n'
    s += txt(W / 2, 252, "every later access to this page: TLB hit, no fault", GREEN, 13)
    s += txt(W / 2, 296, "only the FIRST touch is expensive — but each backend pays it separately",
             DIM, 12, style="italic")
    write("hugepages-03-fault-path.svg", s)


# ---------------------------------------------------------------- Fig 5
def fig5():
    W, H = 800, 340
    s = head(W, H)
    s += txt(W / 2, 30, "Page-table memory for a 16 GB shared_buffers", GREEN, 16, weight="bold")
    s += txt(W / 2, 50, "logarithmic scale", DIM, 12, style="italic")
    rows = [(10, 0.31 * 1024, 0.62), (50, 1.56 * 1024, 3.12),
            (100, 3.12 * 1024, 6.25), (500, 15.62 * 1024, 31.25)]
    x0, x1 = 150, 640
    lo, hi = math.log10(0.5), math.log10(16000.0)

    def px(mb):
        return x0 + (math.log10(mb) - lo) / (hi - lo) * (x1 - x0)

    y = 80
    for n, m4, m2 in rows:
        s += txt(x0 - 14, y + 24, f"{n} backends", WHITE, 12, anchor="end")
        s += f'<rect x="{x0}" y="{y}" width="{px(m4)-x0:.1f}" height="18" fill="{REDD}" rx="3"/>\n'
        s += txt(px(m4) + 8, y + 14, f"{m4/1024:.2f} GB", RED, 11, anchor="start")
        s += f'<rect x="{x0}" y="{y+22}" width="{px(m2)-x0:.1f}" height="18" fill="{GREEN}" rx="3"/>\n'
        s += txt(px(m2) + 8, y + 36, f"{m2:.2f} MB", GREEN, 11, anchor="start")
        y += 56
    s += f'<line x1="{x0}" y1="72" x2="{x0}" y2="{y-10}" stroke="{STROKE}" stroke-width="1"/>\n'
    ly = H - 26
    s += f'<rect x="{x0}" y="{ly-11}" width="26" height="12" fill="{REDD}" rx="2"/>\n'
    s += txt(x0 + 34, ly, "4 KB pages", WHITE, 12, anchor="start")
    s += f'<rect x="{x0+150}" y="{ly-11}" width="26" height="12" fill="{GREEN}" rx="2"/>\n'
    s += txt(x0 + 184, ly, "2 MB huge pages", WHITE, 12, anchor="start")
    write("hugepages-05-scaling.svg", s)


# ---------------------------------------------------------------- Fig 6
def fig7():
    W, H = 640, 330
    s = head(W, H)
    s += txt(W / 2, 32, "Page-table sharing at the PMD level", GREEN, 16, weight="bold")
    s += box(70, 62, 190, 40, "backend 1", GREEN)
    s += box(380, 62, 190, 40, "backend 2", GREEN)
    s += arrow(165, 102, 165, 128)
    s += arrow(475, 102, 475, 128)
    s += box(70, 128, 190, 46, "private upper levels")
    s += box(380, 128, 190, 46, "private upper levels")
    s += f'<path d="M165,174 L165,200 L320,200 L320,222" stroke="{GREEN}" stroke-width="1.8" fill="none" marker-end="url(#ag)"/>\n'
    s += f'<path d="M475,174 L475,200 L320,200 L320,222" stroke="{GREEN}" stroke-width="1.8" fill="none" marker-end="url(#ag)"/>\n'
    s += box(150, 222, 340, 48, "shared PMD table — 1 entry = 2 MB", GREEN, "#1e2a12", GREEN)
    s += txt(W / 2, 300, "kernel-version dependent — verify on your own box", AMBER, 12, style="italic")
    write("hugepages-06-pmd-sharing.svg", s)


# ---------------------------------------------------------------- Fig 7
def fig8():
    W, H = 820, 330
    s = head(W, H)
    s += txt(W / 2, 30, "What a pooler changes", GREEN, 16, weight="bold")
    s += f'<line x1="410" y1="52" x2="410" y2="264" stroke="{STROKE}" stroke-width="1" stroke-dasharray="4,4"/>\n'
    # left
    s += txt(200, 74, "without a pooler", RED, 13, weight="bold")
    s += box(90, 88, 220, 40, "500 clients")
    s += arrow(200, 128, 200, 152, RED, "ar")
    s += box(90, 152, 220, 44, "500 backends", RED)
    s += arrow(200, 196, 200, 218, RED, "ar")
    s += box(90, 218, 220, 46, "500 page tables|15.6 GB", RED, "#2b1c1c", RED, 12)
    # right
    s += txt(615, 74, "with a pooler", GREEN, 13, weight="bold")
    s += box(505, 88, 220, 40, "500 clients")
    s += arrow(615, 128, 615, 152, GREEN, "ag")
    s += box(505, 152, 220, 44, "30 backends  (pool_size)", GREEN)
    s += arrow(615, 196, 615, 218, GREEN, "ag")
    s += box(505, 218, 220, 46, "30 page tables|960 MB", GREEN, "#1e2a12", GREEN, 12)
    s += txt(W / 2, 300, "the same shared_buffers underneath both", DIM, 12, style="italic")
    write("hugepages-07-pooler.svg", s)


for f in (fig1, fig2, fig3, fig5, fig7, fig8):
    f()
