#!/usr/bin/env python3
"""vcd2svg.py: draw a timing diagram (an SVG picture) from a VCD waveform file.

    usage: python3 tools/vcd2svg.py <in.vcd> <out.svg> --clock <clk> [options] <signal> ...
    e.g.   python3 tools/vcd2svg.py build/sc/smoke.vcd build/sc/smoke.svg \\
               --clock sc_core_tb.clk --reset sc_core_tb.rst --from 4 --to 13 \\
               --dump build/sc/smoke.dump \\
               sc_core_tb.clk sc_core_tb.dut.u_core.pc \\
               sc_core_tb.dut.u_core.instr:asm
    (tools/make_wave_fig.sh runs it like this on sw/smoke.S and writes
    docs/images/timing_smoke.svg, the timing diagram in the README.)

A VCD ("value change dump", IEEE 1364 section 18) is the text file a simulator
writes when the testbench calls $dumpvars: a header that names every signal,
then a list of "at time T, signal S became V". tb/sc_core_tb.sv writes one when
it is given +vcd=<file>.

Each <signal> is a full hierarchical name from the VCD, optionally followed by
    :FORMAT   how to show the value:
                bit   a wave, high or low (the default for 1-bit signals)
                hex   the value in hex in a box (the default for buses)
                dec   the value in decimal in a box
                asm   an instruction word shown as assembly (needs --dump)
    @VALID    a 1-bit signal: while it is 0 the value is drawn greyed out
              (for example a value that is only meaningful while a valid flag is 1)
    %COLOR    colour of a 1-bit wave: teal (default), amber, rose, purple, grey
    #NOTE     a short note printed under the signal name
in this order: NAME:FORMAT@VALID%COLOR#NOTE. The parts are split off from the
right ('#' first, then '%', '@', ':'), so a note may contain any character.

Cycles: the clock's rising edges cut time into cycles. Cycle 0 starts at the
reset edge (the last rising edge where --reset is still 1; without --reset,
the first rising edge). With tb/sc_core_tb.sv, cycle 0 is the cycle in which
the instruction at the reset PC (address 0) executes.
"The value in cycle N" is the value in the middle of cycle N,
after the rising edge that starts the cycle has updated every register.
Values are drawn exactly where the VCD says they change.

--highlight SIGNAL=COLOR:LABEL shades every cycle in which the 1-bit SIGNAL
is 1, across all lanes, and writes LABEL above it (COLOR: amber, rose, teal,
purple, grey).

The values in each cycle are also printed as a table (one line per cycle), so
a log shows exactly what the picture shows.

Python 3 standard library only.
"""
import argparse
import bisect
import re
import sys

# ----------------------------------------------------------------- look

MONO = "Cascadia Mono, Consolas, Menlo, 'DejaVu Sans Mono', monospace"
SANS = "Segoe UI, 'Helvetica Neue', 'DejaVu Sans', Arial, sans-serif"
CHAR_W = 0.62          # width of one monospace character, as a fraction of the font size:
                       # Consolas 0.55, Cascadia Mono 0.586, Menlo and DejaVu Sans Mono 0.602,
                       # plus a little room, so text still fits when a viewer has other fonts

INK = "#18201f"        # text colour
MUTED = "#5a6866"
GRID = "#d5dcda"
BUBBLE_FILL = "#eef1f0"

# colour name: (line and text, fill of a high bit or a box, very light column band)
COLORS = {
    "teal":   ("#0f6b74", "#cfe7e5", "#eaf5f4"),
    "amber":  ("#8a5a00", "#f6dfae", "#fdf3e1"),
    "rose":   ("#a33a3a", "#f2caca", "#fcecec"),
    "purple": ("#5b4b8a", "#ddd6ef", "#f3f0f9"),
    "grey":   ("#5a6866", "#e9ecec", "#f3f5f4"),
}


# ----------------------------------------------------------------- reading a VCD

class Signal:
    """One signal's history: parallel lists of change times and values.

    A value is a string of '0' '1' 'x' 'z', most significant bit first,
    exactly `width` characters long.
    """

    def __init__(self, name, width):
        self.name = name
        self.width = width
        self.times = []
        self.values = []

    def add(self, time, value):
        # A signal can change more than once in one time step (delta cycles):
        # only the last value of the step counts.
        if self.times and self.times[-1] == time:
            self.values[-1] = value
        else:
            self.times.append(time)
            self.values.append(value)

    def at(self, t):
        """The value at time t, after any change at exactly t."""
        i = bisect.bisect_right(self.times, t) - 1
        return self.values[i] if i >= 0 else "x" * self.width

    def before(self, t):
        """The value just before time t: what a flip-flop samples at an edge at t."""
        i = bisect.bisect_left(self.times, t) - 1
        return self.values[i] if i >= 0 else "x" * self.width

    def changes_in(self, t0, t1):
        """Change times strictly inside (t0, t1)."""
        lo = bisect.bisect_right(self.times, t0)
        hi = bisect.bisect_left(self.times, t1)
        return self.times[lo:hi]


def to_int(value):
    """A VCD value as a number, or None if any bit is x or z."""
    if any(c not in "01" for c in value):
        return None
    return int(value, 2)


def read_vcd(path, names):
    """Read the histories of the signals in `names` from a VCD file.

    Returns ({name: Signal}, end_time). Exits with a message if a name is
    not in the file (the message lists names that end the same way).
    """
    with open(path) as f:
        tokens = f.read().split()
    n = len(tokens)
    wanted = set(names)
    by_code = {}       # identifier code -> the Signals that use it
    found = {}         # full name -> Signal
    all_names = []
    scope = []
    i = 0

    def skip_to_end(i):
        while tokens[i] != "$end":
            i += 1
        return i + 1

    # ---- header: scopes and variable declarations
    while i < n:
        tok = tokens[i]
        if tok == "$scope":                    # $scope module sc_core_tb $end
            scope.append(tokens[i + 2])
            i = skip_to_end(i)
        elif tok == "$upscope":                # $upscope $end
            scope.pop()
            i = skip_to_end(i)
        elif tok == "$var":                    # $var wire 32 ( pc [31:0] $end
            width, code, ref = int(tokens[i + 2]), tokens[i + 3], tokens[i + 4]
            name = ".".join(scope + [ref.split("[")[0]])
            all_names.append(name)
            if name in wanted and name not in found:
                found[name] = Signal(name, width)
                by_code.setdefault(code, []).append(found[name])
            i = skip_to_end(i)
        elif tok == "$enddefinitions":
            i = skip_to_end(i)
            break
        elif tok.startswith("$"):              # $date, $version, $timescale, $comment
            i = skip_to_end(i)
        else:
            sys.exit(f"vcd2svg: {path}: unexpected '{tok}' in the header")

    missing = [name for name in names if name not in found]
    if missing:
        for name in missing:
            leaf = name.split(".")[-1]
            near = [a for a in all_names if a.endswith("." + leaf)][:6]
            print(f"vcd2svg: {name} is not in {path}" + (f" (did you mean {', '.join(near)}?)" if near else ""),
                  file=sys.stderr)
        sys.exit(2)

    # ---- value changes
    time = 0
    while i < n:
        tok = tokens[i]
        c = tok[0]
        if c == "#":                           # #15000: time now 15000
            time = int(tok[1:])
            i += 1
            continue
        if c in "bB":                          # b1010 V: vector value, then its code
            value, code = tok[1:].lower(), tokens[i + 1]
            i += 2
        elif c in "rR":                        # r1.5 V: a real number, not drawn
            i += 2
            continue
        elif c in "01xXzZ":                    # 1H: scalar value and code in one token
            value, code = c.lower(), tok[1:]
            i += 1
        elif tok == "$comment":
            i = skip_to_end(i)
            continue
        elif c == "$":                         # $dumpvars, $dumpall, $end, ...: just markers
            i += 1
            continue
        else:
            sys.exit(f"vcd2svg: {path}: cannot read '{tok}' at time {time}")
        for sig in by_code.get(code, ()):
            if len(value) < sig.width:         # VCD drops leading bits: 0 pads with 0, x with x, z with z
                pad = "0" if value[0] == "1" else value[0]
                value = pad * (sig.width - len(value)) + value
            sig.add(time, value[-sig.width:])
    return found, time


class Cycles:
    """Clock cycle numbers, from the clock's rising edges (see the file header)."""

    def __init__(self, clk, rst, end_time):
        rises = [t for k, t in enumerate(clk.times)
                 if clk.values[k] == "1" and k > 0 and clk.values[k - 1] == "0"]
        if len(rises) < 2:
            sys.exit("vcd2svg: the clock has fewer than two rising edges")
        first = 0
        if rst is not None:
            # The reset edge: rst is 1 at this edge (as the flip-flops sample it)
            # and 0 at the next one.
            for k in range(len(rises) - 1):
                if rst.before(rises[k]) == "1" and rst.before(rises[k + 1]) == "0":
                    first = k
                    break
            else:
                sys.exit("vcd2svg: no rising edge where reset is released")
        self.starts = rises[first:]
        self.period = self.starts[1] - self.starts[0]
        # The last cycle may be cut short by $finish; it counts if its middle was simulated.
        while self.starts and self.starts[-1] + self.period // 2 > end_time:
            self.starts.pop()
        self.count = len(self.starts)

    def start(self, c):
        return self.starts[c]

    def end(self, c):
        return self.starts[c + 1] if c + 1 < self.count else self.starts[c] + self.period

    def mid(self, c):
        return (self.start(c) + self.end(c)) // 2

    def position(self, t):
        """Time t as a cycle number with a fraction, e.g. 6.5 = the middle of cycle 6."""
        c = max(0, min(bisect.bisect_right(self.starts, t) - 1, self.count - 1))
        return c + (t - self.start(c)) / (self.end(c) - self.start(c))


# ----------------------------------------------------------------- the .dump file

DUMP_LINE = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(\S.*)$")


def clean_asm(text):
    """objdump text -> short assembly: 'beq\\tx4,x3,20 <ok>' -> 'beq x4,x3,ok'.

    A branch or jump target is replaced by its label when objdump names one
    (and the label has no +offset); comments after '#' are dropped.
    """
    text = re.sub(r"\s#\s.*$", "", text).strip()          # objdump's comment: ' # 8000 <expect>'
    label = re.search(r"\s<([^>+]+)>$", text)
    text = re.sub(r"\s*<[^>]*>$", "", text)
    parts = text.split(None, 1)
    mnemonic, operands = parts[0], (parts[1].replace(" ", "") if len(parts) > 1 else "")
    if label and operands:
        ops = operands.split(",")
        ops[-1] = label.group(1)
        operands = ",".join(ops)
    return f"{mnemonic} {operands}".strip()


def read_dump(path):
    """Read `objdump -d` output: returns {address: (word, assembly text)}."""
    program = {}
    with open(path) as f:
        for line in f:
            m = DUMP_LINE.match(line)
            if m:
                program[int(m.group(1), 16)] = (int(m.group(2), 16), clean_asm(m.group(3)))
    return program


# ----------------------------------------------------------------- SVG helpers

def esc(text):
    return str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def fit_font(lines, width, size, smallest=8.0):
    """The largest font size <= size at which every line fits in width (None if none does)."""
    longest = max(len(line) for line in lines)
    while size >= smallest:
        if longest * CHAR_W * size <= width:
            return size
        size -= 0.5
    return None


def bus_path(x1, x2, top, bottom, left_edge, right_edge, slant=3.5):
    """Outline of a bus value: a box whose ends are slanted where the value changes."""
    mid = (top + bottom) / 2
    s = min(slant, (x2 - x1) / 2)
    left = f"M{x1:.1f},{mid:.1f} L{x1 + s:.1f},{top:.1f}" if left_edge else f"M{x1:.1f},{top:.1f}"
    right = (f" L{x2 - s:.1f},{top:.1f} L{x2:.1f},{mid:.1f} L{x2 - s:.1f},{bottom:.1f}" if right_edge
             else f" L{x2:.1f},{top:.1f} L{x2:.1f},{bottom:.1f}")
    close = f" L{x1 + s:.1f},{bottom:.1f} Z" if left_edge else f" L{x1:.1f},{bottom:.1f} Z"
    return left + right + close


# ----------------------------------------------------------------- the diagram

class Lane:
    """One row of the timing diagram, parsed from a signal spec."""

    def __init__(self, spec):
        self.note = ""
        if "#" in spec:
            spec, self.note = spec.split("#", 1)
        self.color = "teal"
        if "%" in spec:
            spec, self.color = spec.split("%", 1)
        if self.color not in COLORS:
            sys.exit(f"vcd2svg: unknown colour '{self.color}' in {spec} (use {', '.join(COLORS)})")
        self.valid = None
        if "@" in spec:
            spec, self.valid = spec.split("@", 1)
        self.fmt = None
        if ":" in spec:
            spec, self.fmt = spec.split(":", 1)
        self.name = spec
        self.label = spec.split(".")[-1]
        if self.fmt not in (None, "bit", "hex", "dec", "asm"):
            sys.exit(f"vcd2svg: unknown format '{self.fmt}' in {spec}")


def value_text(lane, value, valid, words):
    """What to write in a box: (text lines, box colour name or None, greyed out?)."""
    number = to_int(value)
    if number is None:
        return ["x" if "x" in value else "z"], "rose", False
    if lane.fmt == "asm":
        if not valid:
            return ["bubble"], None, True
        asm = words.get(number, f"{number:08x}")
        return asm.split(" ", 1), None, False
    if lane.fmt == "dec":
        return [str(number)], None, not valid
    return [f"{number:0{(lane.width + 3) // 4}x}"], None, not valid


def segments(sig, qual, t0, t1):
    """Split [t0, t1) where the signal or its qualifier changes: [(ta, tb, value, valid)]."""
    cuts = set(sig.changes_in(t0, t1))
    if qual is not None:
        cuts |= set(qual.changes_in(t0, t1))
    edges = [t0] + sorted(cuts) + [t1]
    out = []
    for ta, tb in zip(edges, edges[1:]):
        value = sig.at(ta)
        valid = True if qual is None else qual.at(ta) == "1"
        if out and out[-1][2] == value and out[-1][3] == valid:
            out[-1] = (out[-1][0], tb, value, valid)     # nothing visible changed: merge
        else:
            out.append((ta, tb, value, valid))
    return out


def draw(args, lanes, sigs, cycles, highlights, words):
    first, last = args.first, args.last
    ncyc = last - first + 1
    width = args.width
    x_left = 10 + args.label_width          # where cycle `first` starts
    x_right = width - 12
    cw = (x_right - x_left) / ncyc           # width of one cycle
    t0, t1 = cycles.start(first), cycles.end(last)

    def x_of(t):
        return x_left + (cycles.position(t) - first) * cw if t < t1 else x_right

    heights = {"bit": 16, "clock": 16, "hex": 20, "dec": 20, "asm": 30}
    gap = 10
    y = 24 if args.title else 6
    band_label_y = y + (14 if highlights else 0)   # room for the --highlight labels, if any
    head_y = band_label_y + 18                # baseline of the cycle numbers
    lanes_top = head_y + 10

    out = []
    total_h = lanes_top + sum(heights[l.kind] + gap for l in lanes) + 30
    out.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {total_h:.0f}" '
               f'font-family="{SANS}" role="img" aria-label="{esc(args.aria or args.title or "timing diagram")}">')
    out.append(f'<rect x="0" y="0" width="{width}" height="{total_h:.0f}" fill="#ffffff"/>')
    if args.title:
        out.append(f'<text x="10" y="17" font-size="13" font-weight="600" fill="{INK}">{esc(args.title)}</text>')

    lanes_bottom = total_h - 30
    # ---- column bands for highlighted cycles, with their labels
    for sig_name, color, label in highlights:
        sig = sigs[sig_name]
        run_start = None
        for c in list(range(first, last + 1)) + [None]:
            on = c is not None and sig.at(cycles.mid(c)) == "1"
            if on and run_start is None:
                run_start = c
            if not on and run_start is not None:
                end = (c if c is not None else last + 1)
                xa, xb = x_left + (run_start - first) * cw, x_left + (end - first) * cw
                out.append(f'<rect x="{xa:.1f}" y="{band_label_y + 4}" width="{xb - xa:.1f}" '
                           f'height="{lanes_bottom - band_label_y - 4:.1f}" fill="{COLORS[color][2]}"/>')
                out.append(f'<text x="{(xa + xb) / 2:.1f}" y="{band_label_y}" font-size="11" font-weight="600" '
                           f'text-anchor="middle" fill="{COLORS[color][0]}">{esc(label)}</text>')
                run_start = None

    # ---- cycle numbers and the grid line at every rising edge
    out.append(f'<text x="10" y="{head_y}" font-size="11" fill="{MUTED}">cycle</text>')
    for c in range(first, last + 1):
        xc = x_left + (c - first + 0.5) * cw
        out.append(f'<text x="{xc:.1f}" y="{head_y}" font-family="{MONO}" font-size="11" '
                   f'text-anchor="middle" fill="{MUTED}">{c}</text>')
    for c in range(first, last + 2):
        xg = x_left + (c - first) * cw
        out.append(f'<line x1="{xg:.1f}" y1="{head_y + 4}" x2="{xg:.1f}" y2="{lanes_bottom:.1f}" '
                   f'stroke="{GRID}" stroke-width="0.8" stroke-dasharray="2 3"/>')

    # ---- the lanes
    y = lanes_top
    for lane in lanes:
        h = heights[lane.kind]
        top, bottom = y, y + h
        sig = sigs[lane.name]
        qual = sigs[lane.valid] if lane.valid else None
        name_y = top + h / 2 + (0 if lane.note else 4)
        out.append(f'<text x="10" y="{name_y:.1f}" font-family="{MONO}" font-size="12" font-weight="600" '
                   f'fill="{INK}">{esc(lane.label)}</text>')
        if lane.note:
            out.append(f'<text x="10" y="{name_y + 11:.1f}" font-size="10" fill="{MUTED}">{esc(lane.note)}</text>')

        segs = segments(sig, qual, t0, t1)
        if lane.kind in ("bit", "clock"):
            line, fill = COLORS[lane.color][0], COLORS[lane.color][1]
            if lane.kind == "clock":
                line = INK
            path = []
            for ta, tb, value, _ in segs:
                xa, xb = x_of(ta), x_of(tb)
                level = {"1": top, "0": bottom}.get(value, (top + bottom) / 2)
                if value == "1" and lane.kind == "bit":
                    out.append(f'<rect x="{xa:.1f}" y="{top}" width="{xb - xa:.1f}" height="{h}" fill="{fill}"/>')
                if value not in "01":
                    out.append(f'<rect x="{xa:.1f}" y="{top}" width="{xb - xa:.1f}" height="{h}" '
                               f'fill="{COLORS["rose"][1]}"/>')
                path.append(f"{'M' if not path else 'L'}{xa:.1f},{level:.1f} L{xb:.1f},{level:.1f}")
            out.append(f'<path d="{" ".join(path)}" fill="none" stroke="{line}" stroke-width="1.4" '
                       f'stroke-linejoin="miter"/>')
        else:
            # One font size for the whole lane: the largest at which every box's text fits.
            boxes = [(x_of(ta), x_of(tb), value_text(lane, value, valid, words)) for ta, tb, value, valid in segs]
            fits = [fit_font(lines, xb - xa - 7, 11.5) for xa, xb, (lines, _, _) in boxes]
            size = min((f for f in fits if f is not None), default=None)
            for (ta, tb, value, valid), (xa, xb, (lines, color, grey)), fit in zip(segs, boxes, fits):
                if color:
                    stroke, fill, text_fill = COLORS[color][0], COLORS[color][1], COLORS[color][0]
                elif grey:
                    stroke, fill, text_fill = "#9aa5a3", BUBBLE_FILL, "#7c8886"
                else:
                    stroke, fill, text_fill = INK, "#ffffff", INK
                out.append(f'<path d="{bus_path(xa, xb, top, bottom, ta > t0, tb < t1)}" fill="{fill}" '
                           f'stroke="{stroke}" stroke-width="1"/>')
                if fit is None:
                    continue                                  # box too narrow for any text
                style = ' font-style="italic"' if grey and lane.fmt == "asm" else ""
                weight = ' font-weight="600"' if color else ""
                if len(lines) == 1:
                    ys = [(top + bottom) / 2 + size * 0.35]
                else:
                    ys = [(top + bottom) / 2 - size * 0.18, (top + bottom) / 2 + size * 0.95]
                for text, ty in zip(lines, ys):
                    out.append(f'<text x="{(xa + xb) / 2:.1f}" y="{ty:.1f}" font-family="{MONO}" '
                               f'font-size="{size}" text-anchor="middle" fill="{text_fill}"{style}{weight}>'
                               f'{esc(text)}</text>')
        y += h + gap

    if args.footer:
        out.append(f'<text x="10" y="{total_h - 10:.0f}" font-size="10" fill="{MUTED}">{esc(args.footer)}</text>')
    out.append("</svg>")
    return "\n".join(out) + "\n"


def print_table(lanes, sigs, cycles, first, last, words):
    """One line per cycle with every lane's value in the middle of the cycle."""
    cols = []
    for lane in lanes:
        if lane.kind == "clock":
            continue                      # always 0 in the middle of a cycle
        sig = sigs[lane.name]
        qual = sigs[lane.valid] if lane.valid else None
        texts = []
        for c in range(first, last + 1):
            t = cycles.mid(c)
            value = sig.at(t)
            valid = True if qual is None else qual.at(t) == "1"
            if lane.kind == "bit":
                texts.append(value)
            else:
                lines, _, grey = value_text(lane, value, valid, words)
                texts.append(" ".join(lines) + (" (bubble)" if grey and lane.fmt in ("hex", "dec") else ""))
        cols.append((lane.label, texts))
    widths = [max(len(label), *(len(t) for t in texts)) for label, texts in cols]
    print(("cycle  " + "  ".join(label.ljust(w) for (label, _), w in zip(cols, widths))).rstrip())
    for k, c in enumerate(range(first, last + 1)):
        print((f"{c:5d}  " + "  ".join(texts[k].ljust(w) for (_, texts), w in zip(cols, widths))).rstrip())


def main():
    ap = argparse.ArgumentParser(description="VCD -> SVG timing diagram")
    ap.add_argument("vcd")
    ap.add_argument("svg")
    ap.add_argument("signals", nargs="+", help="NAME[:FORMAT][@VALID][#NOTE] (see the file header)")
    ap.add_argument("--clock", required=True, help="the clock signal (cycles start at its rising edges)")
    ap.add_argument("--reset", help="active-high reset: cycle 0 starts at the reset edge")
    ap.add_argument("--from", dest="first", type=int, default=0, help="first cycle to draw")
    ap.add_argument("--to", dest="last", type=int, help="last cycle to draw (default: the last one)")
    ap.add_argument("--dump", help="objdump -d listing, for the asm format")
    ap.add_argument("--highlight", action="append", default=[], help="SIGNAL=COLOR:LABEL")
    ap.add_argument("--check-cycle", help="an integer signal that must equal the cycle number in every cycle")
    ap.add_argument("--title", default="")
    ap.add_argument("--aria", default="", help="text description for screen readers")
    ap.add_argument("--footer", default="")
    ap.add_argument("--width", type=int, default=1000, help="SVG viewBox width")
    ap.add_argument("--label-width", type=int, default=128)
    args = ap.parse_args()

    lanes = [Lane(spec) for spec in args.signals]
    highlights = []
    for h in args.highlight:
        sig_name, rest = h.split("=", 1)
        color, label = rest.split(":", 1)
        if color not in COLORS:
            sys.exit(f"vcd2svg: unknown colour '{color}' (use {', '.join(COLORS)})")
        highlights.append((sig_name, color, label))

    names = {args.clock} | {l.name for l in lanes} | {l.valid for l in lanes if l.valid}
    names |= {h[0] for h in highlights}
    if args.reset:
        names.add(args.reset)
    if args.check_cycle:
        names.add(args.check_cycle)
    sigs, end_time = read_vcd(args.vcd, sorted(names))
    cycles = Cycles(sigs[args.clock], sigs.get(args.reset), end_time)
    if args.last is None:
        args.last = cycles.count - 1
    if not 0 <= args.first <= args.last < cycles.count:
        sys.exit(f"vcd2svg: cycles {args.first}..{args.last} asked for, the VCD has 0..{cycles.count - 1}")

    words = {}
    if args.dump:
        for addr, (word, text) in read_dump(args.dump).items():
            words.setdefault(word, text)
    for lane in lanes:
        lane.width = sigs[lane.name].width
        if lane.fmt is None:
            lane.fmt = "bit" if lane.width == 1 else "hex"
        if lane.fmt == "asm" and not args.dump:
            sys.exit("vcd2svg: the asm format needs --dump")
        lane.kind = "clock" if lane.name == args.clock else lane.fmt

    if args.check_cycle:
        counter = sigs[args.check_cycle]
        for c in range(args.first, args.last + 1):
            if to_int(counter.at(cycles.mid(c))) != c:
                sys.exit(f"vcd2svg: cycle numbering differs from {args.check_cycle} in cycle {c}")
        print(f"cycle numbers checked against {args.check_cycle}: cycles {args.first}..{args.last} agree")

    svg = draw(args, lanes, sigs, cycles, highlights, words)
    with open(args.svg, "w", newline="\n") as f:
        f.write(svg)
    print(f"vcd2svg: {args.vcd} -> {args.svg}: {len(lanes)} signals, cycles {args.first}..{args.last} "
          f"(clock period {cycles.period} time units)")
    print_table(lanes, sigs, cycles, args.first, args.last, words)


if __name__ == "__main__":
    main()
