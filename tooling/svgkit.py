"""
svgkit — a tiny SVG builder for the training diagrams.

Diagrams are laid out on an explicit grid with explicit coordinates. Nothing is
auto-placed: that is deliberate. Auto-layout engines (Mermaid/dot) are what make
architecture diagrams look arbitrary — boxes land wherever the solver puts them,
sites drift, and equivalent servers end up at different sizes and offsets.

Shared visual system:
  - one palette, one type scale
  - uniform box sizes for peer components
  - sites/zones are containers drawn first, contents aligned inside them
  - orthogonal connectors

Two layers of API:

  primitives   rect, text, line, path
  composites   node, container, caption, edge_label   — topology diagrams
               chevrons, matrix, cards, lanes, stack, states, quadrant,
               timeline, split, legend, callout, para  — everything else

Composites that lay out a block of content return the y coordinate they finished
at, so a diagram can be flowed top to bottom without hand-computing every offset:

    y = s.cards(40, 90, W - 80, items, cols=3)
    y = s.callout(40, y + 20, W - 80, "…")

Every diagram should end with s.audit() clean — make_diagrams.py fails the build
on overlapping component boxes, text wider than the box it sits in, or anything
falling off the canvas. Machine-authored diagrams silently overflow otherwise.
"""

# ---------------------------------------------------------------- palette
INK        = "#16202b"
MUTED      = "#5a6b7a"
FAINT      = "#8b9aa8"
LINE       = "#5a6b7a"
BORDER     = "#c9d5de"

SITE_FILL  = "#f6f9fb"; SITE_LINE = "#b9c7d2"
PF_FILL    = "#e2f1f2"; PF_LINE   = "#0e7c86"
PD_FILL    = "#e7f3ec"; PD_LINE   = "#2f7d52"
PRX_FILL   = "#f7ede2"; PRX_LINE  = "#b06a2c"
LB_FILL    = "#ecebf6"; LB_LINE   = "#5b4b9a"
SRC_FILL   = "#f1f3f5"; SRC_LINE  = "#8b9aa8"
WARN_FILL  = "#fdf1e3"; WARN_LINE = "#b06a2c"
USER_FILL  = "#ffffff"; USER_LINE = "#5a6b7a"

OK_FILL    = "#e7f3ec"; OK_LINE   = "#2f7d52"
BAD_FILL   = "#fdecec"; BAD_LINE  = "#b3413e"

FONT = "'Helvetica Neue',Helvetica,Arial,sans-serif"
MONO = "ui-monospace,'SF Mono',Menlo,Consolas,monospace"

# Approximate Helvetica advance widths, as a fraction of font size. Used to size
# boxes to their text and to flag overflow in audit() — a rough model is enough
# to catch the failure that matters (a label wider than the box holding it).
_NARROW = set("iljtIfr.,:;!|'`()[]{}/\\ ")
_WIDE = set("mwMW@%")


def tw(s, size=13, weight="400", family=FONT):
    """Estimated rendered width of a string, in px."""
    total = 0.0
    for ch in s:
        if ch in _NARROW:
            total += 0.30
        elif ch in _WIDE:
            total += 0.86
        elif ch.isupper():
            total += 0.69
        elif ch.isdigit():
            total += 0.56
        else:
            total += 0.53
    if family == MONO:
        total = 0.60 * len(s)
    if weight in ("600", "700", "bold"):
        total *= 1.06
    return total * size


def wrap(s, width, size=11, weight="400"):
    """Greedy word wrap to a pixel width. Returns a list of lines."""
    words, lines, cur = s.split(), [], ""
    for word in words:
        trial = f"{cur} {word}".strip()
        if cur and tw(trial, size, weight) > width:
            lines.append(cur)
            cur = word
        else:
            cur = trial
    if cur:
        lines.append(cur)
    return lines


def _esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


class SVG:
    def __init__(self, w, h, title=""):
        self.w, self.h, self.title = w, h, title
        self.parts = []
        self._boxes = []   # component boxes, for overlap auditing
        self._fits = []    # (text, width, box) triples, for overflow auditing
        self._texts = []   # (text, left, right, baseline, size), for bounds auditing
        self._blocks = []  # bounding box per content composite, for collision auditing

    def _block(self, x, y, w, h, kind, nest=False):
        """Register a composite's footprint so audit() catches blocks laid on top of
        each other. Pass nest=True when a composite is deliberately placed inside
        another (a legend inside a panel, say)."""
        if not nest:
            self._blocks.append((x, y, w, h, kind))

    # ---- primitives ----
    def rect(self, x, y, w, h, fill, stroke, r=7, sw=1.5, dash=None, op=1.0):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.parts.append(
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" '
            f'fill-opacity="{op}" stroke="{stroke}" stroke-width="{sw}"{d}/>')

    def text(self, x, y, s, size=13, fill=INK, anchor="middle", weight="400",
             family=FONT, spacing=None, italic=False):
        ls = f' letter-spacing="{spacing}"' if spacing else ""
        it = ' font-style="italic"' if italic else ""
        self.parts.append(
            f'<text x="{x}" y="{y}" font-family="{family}" font-size="{size}" fill="{fill}" '
            f'text-anchor="{anchor}" font-weight="{weight}"{ls}{it}>{_esc(s)}</text>')
        w = tw(s, size, weight, family)
        left = x if anchor == "start" else (x - w if anchor == "end" else x - w / 2)
        self._texts.append((s, left, left + w, y, size))

    def line(self, x1, y1, x2, y2, stroke=LINE, sw=1.6, dash=None, arrow=True, op=1.0):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        a = ' marker-end="url(#a)"' if arrow else ""
        self.parts.append(
            f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{stroke}" '
            f'stroke-width="{sw}" stroke-opacity="{op}"{d}{a}/>')

    def path(self, d, stroke=LINE, sw=1.6, dash=None, arrow=True, fill="none", both=False, op=1.0):
        da = f' stroke-dasharray="{dash}"' if dash else ""
        a = ' marker-end="url(#a)"' if arrow else ""
        s = ' marker-start="url(#as)"' if both else ""
        self.parts.append(
            f'<path d="{d}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}" '
            f'stroke-opacity="{op}"{da}{a}{s}/>')

    # ---- composites ----
    def node(self, x, y, w, h, label, sub=None, fill="#fff", stroke=BORDER,
             size=13, subsize=11, r=7, sw=1.5, dash=None, badge=None):
        """A component box. Label centred; optional sub-label beneath."""
        self.rect(x, y, w, h, fill, stroke, r=r, sw=sw, dash=dash)
        self._boxes.append((x, y, w, h, label))
        self._fits.append((label, tw(label, size, "600"), (x, y, w, h)))
        if sub:
            self._fits.append((sub, tw(sub, subsize), (x, y, w, h)))
        cx = x + w / 2
        if sub:
            self.text(cx, y + h / 2 - 3, label, size=size, weight="600")
            self.text(cx, y + h / 2 + 14, sub, size=subsize, fill=MUTED)
        else:
            self.text(cx, y + h / 2 + 5, label, size=size, weight="600")
        if badge:
            bw = 8 + 6.2 * len(badge)
            self.rect(x + w - bw - 8, y + 7, bw, 17, "#fff", stroke, r=5, sw=1.2)
            self.text(x + w - bw / 2 - 8, y + 19, badge, size=9.5, fill=stroke,
                      weight="700", spacing="0.06em")

    def container(self, x, y, w, h, label, fill=SITE_FILL, stroke=SITE_LINE, dash="7 5"):
        """A site / zone container. Drawn first; contents placed inside."""
        self.rect(x, y, w, h, fill, stroke, r=11, sw=1.6, dash=dash)
        self.text(x + 16, y + 22, label, size=11.5, fill=MUTED, anchor="start",
                  weight="700", spacing="0.10em")

    def caption(self, x, y, s, size=11, anchor="middle", fill=FAINT, italic=True):
        self.text(x, y, s, size=size, fill=fill, anchor=anchor, italic=italic)

    def edge_label(self, x, y, s, size=10.5, fill=MUTED, bg="#ffffff"):
        """Label sitting on a connector, with a background plate for legibility."""
        w = 7 + 5.9 * len(s)
        self.rect(x - w / 2, y - 11, w, 17, bg, bg, r=4, sw=0)
        self.text(x, y + 1.5, s, size=size, fill=fill, weight="600")

    # ---- content composites -------------------------------------------------
    # These lay out a block and return the y coordinate they finished at, so a
    # diagram can be flowed top to bottom instead of hand-computing offsets.

    def header(self, title, sub=None, y=32):
        """Standard diagram title (+ optional one-line caption). Returns next y."""
        self.text(self.w / 2, y, title, size=17, weight="700")
        if sub:
            self.caption(self.w / 2, y + 18, sub)
            return y + 40
        return y + 26

    def para(self, x, y, s, w, size=11, fill=MUTED, weight="400", anchor="start", lh=None):
        """Wrapped body text. Returns the y after the last line."""
        lh = lh or size * 1.45
        lines = wrap(s, w, size, weight)
        for i, line in enumerate(lines):
            self.text(x, y + i * lh, line, size=size, fill=fill, anchor=anchor, weight=weight)
        return y + (len(lines) - 1) * lh

    def chevrons(self, x, y, w, items, h=58, gap=8, fill=PF_FILL, stroke=PF_LINE,
                 notch=14, size=12, subsize=9.5, nest=False):
        """Left-to-right stage pipeline. items = [label | (label, sub) | (label, sub, fill, stroke)].

        Use for anything that is a sequence of stages: a promotion pipeline, a
        migration path, an onboarding process. Returns the y below the band.
        """
        n = len(items)
        seg = (w - gap * (n - 1)) / n
        for i, item in enumerate(items):
            item = (item,) if isinstance(item, str) else tuple(item)
            label, sub = item[0], (item[1] if len(item) > 1 else None)
            f, st = (item[2], item[3]) if len(item) > 3 else (fill, stroke)
            x0 = x + i * (seg + gap)
            x1 = x0 + seg
            if i == 0:
                d = f"M {x0} {y} L {x1-notch} {y} L {x1} {y+h/2} L {x1-notch} {y+h} L {x0} {y+h} Z"
            else:
                d = (f"M {x0} {y} L {x1-notch} {y} L {x1} {y+h/2} L {x1-notch} {y+h} "
                     f"L {x0} {y+h} L {x0+notch} {y+h/2} Z")
            self.parts.append(f'<path d="{d}" fill="{f}" stroke="{st}" stroke-width="1.5"/>')
            cx = x0 + seg / 2 + (notch / 2 if i else 0)
            inner = seg - notch * 2
            if sub:
                self.text(cx, y + h / 2 - 2, label, size=size, weight="600")
                self.text(cx, y + h / 2 + 15, sub, size=subsize, fill=MUTED)
                self._fits.append((sub, tw(sub, subsize), (x0, y, inner, h)))
            else:
                self.text(cx, y + h / 2 + 5, label, size=size, weight="600")
            self._fits.append((label, tw(label, size, "600"), (x0, y, inner, h)))
        self._block(x, y, w, h, "chevrons", nest)
        return y + h

    def matrix(self, x, y, cols, rows, cells, label_w=190, col_w=None, row_h=32,
               head_h=32, size=10.5, head_size=10, nest=False):
        """Comparison grid — the visual form of a decision table.

        cols  = header labels; rows = row labels
        cells = cells[r][c] as "text" or (text, tone) with tone in
                {ok, bad, warn, none}. Returns the y below the grid.
        """
        col_w = col_w or (self.w - 2 * x - label_w) / len(cols)
        self.rect(x, y, label_w + col_w * len(cols), head_h, "#f2f6f9", BORDER, r=6, sw=1.2)
        for c, col in enumerate(cols):
            cx = x + label_w + c * col_w + col_w / 2
            self.text(cx, y + head_h / 2 + 4, col, size=head_size, weight="700", fill=MUTED,
                      spacing="0.04em")
        yy = y + head_h
        tones = {"ok": (OK_FILL, OK_LINE), "bad": (BAD_FILL, BAD_LINE),
                 "warn": (WARN_FILL, WARN_LINE), None: ("#ffffff", BORDER)}
        for r, row in enumerate(rows):
            self.text(x + 12, yy + row_h / 2 + 4, row, size=size, weight="600", anchor="start")
            self._fits.append((row, tw(row, size, "600"), (x, yy, label_w, row_h)))
            for c in range(len(cols)):
                cell = cells[r][c]
                txt, tone = (cell, None) if isinstance(cell, str) else cell
                f, st = tones[tone]
                cx = x + label_w + c * col_w
                self.rect(cx + 2, yy + 2, col_w - 4, row_h - 4, f, st, r=5, sw=1.1)
                self.text(cx + col_w / 2, yy + row_h / 2 + 4, txt, size=size,
                          fill=st if tone else INK, weight="600" if tone else "400")
                self._fits.append((txt, tw(txt, size), (cx, yy, col_w - 6, row_h)))
            yy += row_h
        self._block(x, y, label_w + col_w * len(cols), yy - y, "matrix", nest)
        return yy

    def cards(self, x, y, w, items, cols=3, gap=14, card_h=None, fill="#ffffff",
              stroke=BORDER, accent=None, size=12, subsize=10, nest=False):
        """Grid of titled cards with wrapped body text — replaces a bullet list.

        items = [(title, body) | (title, body, accent_colour)]. Returns bottom y.
        """
        cw = (w - gap * (cols - 1)) / cols
        body_w = cw - 26
        if card_h is None:
            deepest = max(len(wrap(i[1], body_w, subsize)) for i in items) if items else 1
            card_h = 34 + deepest * subsize * 1.42
        rows = (len(items) + cols - 1) // cols
        for i, item in enumerate(items):
            title, body = item[0], item[1]
            acc = item[2] if len(item) > 2 else accent
            cx = x + (i % cols) * (cw + gap)
            cy = y + (i // cols) * (card_h + gap)
            self.rect(cx, cy, cw, card_h, fill, stroke, r=8, sw=1.4)
            self._boxes.append((cx, cy, cw, card_h, title))
            if acc:
                self.rect(cx, cy + 10, 3.5, card_h - 20, acc, acc, r=2, sw=0)
            self.text(cx + 14, cy + 22, title, size=size, weight="700", anchor="start")
            self._fits.append((title, tw(title, size, "700"), (cx, cy, cw - 14, card_h)))
            self.para(cx + 14, cy + 40, body, body_w, size=subsize)
        self._block(x, y, w, rows * card_h + (rows - 1) * gap, "cards", nest)
        return y + rows * card_h + (rows - 1) * gap

    def lanes(self, x, y, w, lanes, steps, lane_h=42, top=60, step_gap=42, size=12.5, nest=False):
        """Sequence diagram: lane headers, lifelines, numbered messages.

        lanes = [(name, fill, stroke)]
        steps = [(from_index, to_index, label) | (from_i, to_i, label, "dashed")]
        Returns the y below the last lifeline.
        """
        n = len(lanes)
        slot = w / n
        xs = [x + slot * i + slot / 2 for i in range(n)]
        bw = min(slot - 24, 210)
        bottom = y + top + len(steps) * step_gap + 8
        for i, (name, f, st) in enumerate(lanes):
            self.node(xs[i] - bw / 2, y, bw, lane_h, name, fill=f, stroke=st, size=size)
            self.path(f"M {xs[i]} {y+lane_h} L {xs[i]} {bottom}", arrow=False, dash="4 5",
                      stroke=BORDER, sw=1.4)
        for k, step in enumerate(steps):
            a, b, label = step[0], step[1], step[2]
            dash = "5 4" if len(step) > 3 and step[3] == "dashed" else None
            sy = y + top + k * step_gap
            self.line(xs[a], sy, xs[b], sy, sw=1.7, dash=dash)
            self.edge_label((xs[a] + xs[b]) / 2, sy - 9, f"{k+1}  {label}")
        self._block(x, y, w, bottom - y, "lanes", nest)
        return bottom

    def stack(self, x, y, w, layers, lh=44, gap=6, size=12, subsize=9.5, nest=False):
        """Vertical layered stack — what sits on top of what. layers = [(label, sub, fill, stroke)]."""
        for i, layer in enumerate(layers):
            label, sub = layer[0], layer[1]
            f = layer[2] if len(layer) > 2 else "#ffffff"
            st = layer[3] if len(layer) > 3 else BORDER
            self.node(x, y + i * (lh + gap), w, lh, label, sub=sub, fill=f, stroke=st,
                      size=size, subsize=subsize)
        self._block(x, y, w, len(layers) * lh + (len(layers) - 1) * gap, "stack", nest)
        return y + len(layers) * lh + (len(layers) - 1) * gap

    def states(self, x, y, items, w=170, h=58, gap=76, size=12.5, subsize=9.5, nest=False):
        """Row of states for a state machine. Returns the list of (cx, cy, box) so the
        caller can wire transitions with arc()."""
        out = []
        for i, item in enumerate(items):
            label, sub = item[0], (item[1] if len(item) > 1 else None)
            f = item[2] if len(item) > 2 else "#ffffff"
            st = item[3] if len(item) > 3 else BORDER
            bx = x + i * (w + gap)
            self.node(bx, y, w, h, label, sub=sub, fill=f, stroke=st, size=size, subsize=subsize)
            out.append((bx + w / 2, y + h / 2, (bx, y, w, h)))
        n = len(items)
        self._block(x, y, n * w + (n - 1) * gap, h, "states", nest)
        return out

    def arc(self, x1, y1, x2, y2, label=None, lift=56, stroke=LINE, dash=None, fill=MUTED):
        """Curved transition between two points, label riding above the curve.

        Default lift clears a standard 58px state box, so transitions drawn edge to
        edge between adjacent states do not print their label across the boxes.
        """
        mx = (x1 + x2) / 2
        self.path(f"M {x1} {y1} Q {mx} {y1 - lift} {x2} {y2}", stroke=stroke, dash=dash, sw=1.6)
        if label:
            self.edge_label(mx, y1 - lift + 4, label, fill=fill)

    def quadrant(self, x, y, w, h, xaxis, yaxis, items, size=10.5, nest=False):
        """2x2 grid with items plotted at fractional positions.
        items = [(label, fx, fy)] with fx/fy in 0..1 (fy 0 = bottom). Returns bottom y."""
        self.rect(x, y, w, h, "#fbfcfd", BORDER, r=8, sw=1.4)
        self.line(x + w / 2, y, x + w / 2, y + h, stroke=BORDER, sw=1.2, arrow=False, dash="5 4")
        self.line(x, y + h / 2, x + w, y + h / 2, stroke=BORDER, sw=1.2, arrow=False, dash="5 4")
        self.text(x + w / 2, y + h + 26, xaxis, size=10.5, fill=MUTED, weight="600")
        self.parts.append(
            f'<text x="{x-14}" y="{y+h/2}" font-family="{FONT}" font-size="10.5" fill="{MUTED}" '
            f'text-anchor="middle" font-weight="600" transform="rotate(-90 {x-14} {y+h/2})">'
            f'{_esc(yaxis)}</text>')
        for label, fx, fy in items:
            px, py = x + fx * w, y + (1 - fy) * h
            self.parts.append(f'<circle cx="{px}" cy="{py}" r="5.5" fill="{PF_LINE}"/>')
            self.text(px, py - 12, label, size=size, weight="600")
        self._block(x, y, w, h + 34, "quadrant", nest)
        return y + h + 34

    def timeline(self, x, y, w, items, size=11.5, subsize=9.5, nest=False):
        """Horizontal spine with evenly spaced milestones, alternating above/below.
        items = [(label, sub)]. Returns bottom y."""
        self.line(x, y, x + w, y, stroke=BORDER, sw=2.5, arrow=False)
        n = len(items)
        step = w / max(1, n - 1) if n > 1 else w
        for i, item in enumerate(items):
            label, sub = item[0], (item[1] if len(item) > 1 else None)
            px = x + i * step if n > 1 else x + w / 2
            up = i % 2 == 0
            self.parts.append(f'<circle cx="{px}" cy="{y}" r="6" fill="#fff" stroke="{PF_LINE}" '
                              f'stroke-width="2.5"/>')
            ty = y - 32 if up else y + 30
            self.text(px, ty, label, size=size, weight="700")
            if sub:
                self.text(px, ty + 15, sub, size=subsize, fill=MUTED)
        self._block(x, y - 52, w, 114, "timeline", nest)
        return y + 62

    def split(self, x, y, w, h, left, right, gap=28, left_tone=(BAD_FILL, BAD_LINE),
              right_tone=(OK_FILL, OK_LINE), nest=False):
        """Two labelled panels for before/after or option A/B. Returns (left_box, right_box)
        as (x, y, w, h) tuples for placing content inside."""
        pw = (w - gap) / 2
        for i, (title, tone) in enumerate(((left, left_tone), (right, right_tone))):
            px = x + i * (pw + gap)
            self.rect(px, y, pw, h, "#ffffff", tone[1], r=10, sw=1.6)
            self.rect(px, y, pw, 30, tone[0], tone[1], r=10, sw=1.6)
            self.rect(px, y + 22, pw, 8, tone[0], tone[0], r=0, sw=0)
            self.text(px + pw / 2, y + 20, title, size=11.5, weight="700", fill=tone[1],
                      spacing="0.04em")
        self._block(x, y, w, h, "split", nest)
        return (x, y + 30, pw, h - 30), (x + pw + gap, y + 30, pw, h - 30)

    def legend(self, x, y, items, size=10, gap=20, swatch=11):
        """Colour key. items = [(colour, label)]. Laid out left to right. Returns bottom y."""
        cx = x
        for colour, label in items:
            self.rect(cx, y - swatch + 2, swatch, swatch, colour, colour, r=3, sw=0)
            self.text(cx + swatch + 6, y, label, size=size, fill=MUTED, anchor="start")
            cx += swatch + 6 + tw(label, size) + gap
        return y + 8

    def callout(self, x, y, w, text, title=None, kind="note", size=10.5, nest=False):
        """Accent-bar note. kind in {note, warn, ok, bad}. Returns bottom y."""
        tones = {"note": (LB_LINE, "#f4f3fa"), "warn": (WARN_LINE, WARN_FILL),
                 "ok": (OK_LINE, OK_FILL), "bad": (BAD_LINE, BAD_FILL)}
        accent, bg = tones[kind]
        lines = wrap(text, w - 34, size)
        h = 20 + (len(lines) + (1 if title else 0)) * size * 1.5
        self.rect(x, y, w, h, bg, bg, r=7, sw=0)
        self.rect(x, y, 4, h, accent, accent, r=2, sw=0)
        ty = y + 20
        if title:
            self.text(x + 18, ty, title, size=size, weight="700", fill=accent, anchor="start")
            ty += size * 1.5
        self.para(x + 18, ty, text, w - 34, size=size, fill=INK)
        self._block(x, y, w, h, "callout", nest)
        return y + h

    def step_marker(self, x, y, n, stroke=PF_LINE, r=11):
        """Numbered circle for annotating a topology diagram with flow order."""
        self.parts.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="#ffffff" stroke="{stroke}" '
                          f'stroke-width="1.8"/>')
        self.text(x, y + 4, str(n), size=11, weight="700", fill=stroke)

    # ---- quality gate -------------------------------------------------------

    def audit(self):
        """Layout problems that are invisible in code but obvious on the page."""
        out = []
        for label, width, (bx, by, bw, bh) in self._fits:
            if width > bw - 10:
                out.append(f'text does not fit: "{label}" needs {width:.0f}px, box is {bw:.0f}px')
        for i, a in enumerate(self._boxes):
            for b in self._boxes[i + 1:]:
                if (a[0] < b[0] + b[2] and b[0] < a[0] + a[2]
                        and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]):
                    out.append(f'boxes overlap: "{a[4]}" and "{b[4]}"')
        for bx, by, bw, bh, label in self._boxes:
            if bx < 0 or by < 0 or bx + bw > self.w or by + bh > self.h:
                out.append(f'box off canvas: "{label}" at ({bx:.0f},{by:.0f}) {bw:.0f}x{bh:.0f}')
        for i, a in enumerate(self._blocks):
            for b in self._blocks[i + 1:]:
                if (a[0] < b[0] + b[2] - 2 and b[0] < a[0] + a[2] - 2
                        and a[1] < b[1] + b[3] - 2 and b[1] < a[1] + a[3] - 2):
                    out.append(f'{a[4]} block collides with {b[4]} block '
                               f'(y {a[1]:.0f}+{a[3]:.0f} vs {b[1]:.0f}+{b[3]:.0f})')
        for s, left, right, base, size in self._texts:
            if left < -1 or right > self.w + 1 or base > self.h or base - size < 0:
                out.append(f'text off canvas: "{s}"')
        return out

    def render(self):
        head = (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
            f'viewBox="0 0 {self.w} {self.h}" font-family="{FONT}">'
            f'<title>{_esc(self.title)}</title>'
            '<defs>'
            # orient="auto" (not "auto-start-reverse"): for an end-marker the two are
            # identical, and "auto" is understood by every renderer — some rasterizers
            # mishandle auto-start-reverse and print the arrowhead rotated sideways.
            # The start-marker "as" is a separately pre-rotated triangle so it also
            # works under plain "auto".
            f'<marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
            f'markerHeight="7" orient="auto">'
            f'<path d="M0,1 L9,5 L0,9 z" fill="{LINE}"/></marker>'
            f'<marker id="as" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="7" '
            f'markerHeight="7" orient="auto">'
            f'<path d="M9,1 L0,5 L9,9 z" fill="{LINE}"/></marker>'
            '</defs>'
            f'<rect width="{self.w}" height="{self.h}" fill="#ffffff"/>')
        return head + "".join(self.parts) + "</svg>"

    def save(self, path):
        import pathlib
        problems = self.audit()
        if problems:
            PROBLEMS.append((pathlib.Path(path).name, problems))
        pathlib.Path(path).write_text(self.render())
        return path


# Collected across a build so make_diagrams.py can fail loudly rather than
# writing a diagram nobody looks at again until it is on a screen in front of
# a customer.
PROBLEMS = []
