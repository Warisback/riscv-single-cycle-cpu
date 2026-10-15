#!/usr/bin/env bash
# gtkwave_shot.sh: GTKWave screenshots of sw/smoke.S running on the single-cycle core.
#
#   usage: tools/gtkwave_shot.sh          write the two screenshots below
#          tools/gtkwave_shot.sh --open   open GTKWave on the same signals instead
#
# Both show build/sc/smoke.vcd with the signals of tools/gtkwave/smoke.gtkw:
#   docs/images/gtkwave_smoke.png              the whole run, 0 to 170 ns (cycles 0 to 16)
#   docs/images/gtkwave_load_store_branch.png  85 to 135 ns (cycles 8 to 12), larger text
#
# Steps: tools/make_wave_fig.sh when the VCD is missing or older than its sources,
# tools/gtkwave_filters.py for the alias files (instructions as assembly, ALU and
# write-back names, register names), then GTKWave once per picture with
# tools/gtkwave/grab.tcl, which zooms and saves the window through GTKWave's own
# File > Grab To File. No screen-capture tool is needed, but GTKWave needs a display
# (a Linux desktop, or WSLg on Windows 11): each window is on screen for about
# five seconds and should not be covered. So this cannot run headless or in CI.
# Log: results/gtkwave_shot.log. Exit code 0 only if both pictures were written.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
command -v gtkwave > /dev/null 2>&1 ||
  die "error: gtkwave not found on PATH.
  Ubuntu/Debian: sudo apt install gtkwave      macOS: brew install --cask gtkwave"
[ -n "${DISPLAY:-}" ] ||
  die "error: DISPLAY is not set. GTKWave draws the screenshots in a real window, so it needs a display."

o=build/sc/gtkwave
mkdir -p "$o" docs/images results

# The VCD and the objdump listing come from tools/make_wave_fig.sh.
if [ ! -f build/sc/smoke.vcd ] || [ ! -f build/sc/smoke.dump ] ||
   [ -n "$(find sw/smoke.S rtl tb \( -name '*.S' -o -name '*.sv' \) -newer build/sc/smoke.vcd | head -n 1)" ]; then
  bash tools/make_wave_fig.sh > /dev/null || die "error: tools/make_wave_fig.sh failed, see results/sc_wave.log"
fi
python3 tools/gtkwave_filters.py build/sc/smoke.dump "$o" > /dev/null || die "error: tools/gtkwave_filters.py failed"

if [ "${1:-}" = "--open" ]; then
  exec gtkwave build/sc/smoke.vcd tools/gtkwave/smoke.gtkw
fi

png_size() {
  python3 -c 'import struct, sys; d = open(sys.argv[1], "rb").read(24); print("%d x %d pixels" % struct.unpack(">II", d[16:24]))' "$1"
}

# shot <out.png> <from_ps> <to_ps> <save file> [gtkwave options...]
shot() {
  local out="$1" from="$2" to="$3" gtkw="$4" tmp rc
  shift 4
  tmp="$o/$(basename "$out")"
  rm -f "$tmp"
  GRAB_FROM="$from" GRAB_TO="$to" GRAB_PNG="$tmp" GDK_BACKEND=x11 timeout 60 \
    gtkwave --rcvar 'splash_disable 1' --rcvar 'hide_sst 1' --rcvar 'enable_vert_grid 0' "$@" \
    -S tools/gtkwave/grab.tcl build/sc/smoke.vcd "$gtkw" > "$o/gtkwave.out" 2>&1
  rc=$?
  grep -E '^grab:|^GTKWAVE \| Filename' "$o/gtkwave.out"
  if [ $rc -ne 0 ] || [ ! -s "$tmp" ]; then
    echo "FAIL $out: gtkwave exit $rc, see $o/gtkwave.out"
    return 1
  fi
  cp "$tmp" "$out"
  echo "PASS $out: $(png_size "$out"), gtkwave exit 0"
}

start=$SECONDS
{
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  GTKWave screenshots of build/sc/smoke.vcd"
  echo "# $(gtkwave --version 2> /dev/null | head -n 1), signals from tools/gtkwave/smoke.gtkw"
  ok=0
  # The whole run at the default font size, in the window size of the save file.
  shot docs/images/gtkwave_smoke.png 0 170000 tools/gtkwave/smoke.gtkw && ok=$((ok + 1))
  # Cycles 8 to 12 (bne, sw, lw, beq, jal) with GTKWave's larger fonts, in a smaller window.
  sed -e 's/^\[size\] .*/[size] 1250 745/' tools/gtkwave/smoke.gtkw > "$o/zoom.gtkw"
  shot docs/images/gtkwave_load_store_branch.png 85000 135000 "$o/zoom.gtkw" --rcvar 'use_big_fonts 1' &&
    ok=$((ok + 1))
  if [ $ok -eq 2 ]; then
    echo "PASS gtkwave: 2 screenshots written"
  else
    echo "FAIL gtkwave: $ok of 2 screenshots written"
  fi
  echo "# elapsed $((SECONDS - start)) s"
} 2>&1 | tee results/gtkwave_shot.log
grep -q '^PASS gtkwave' results/gtkwave_shot.log
