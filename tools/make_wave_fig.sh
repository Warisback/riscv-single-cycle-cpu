#!/usr/bin/env bash
# make_wave_fig.sh: run sw/smoke.S on the single-cycle core with a VCD dump, then
# draw a timing diagram of cycles 4..13 from it.
#
#   usage: tools/make_wave_fig.sh [out.svg]      (default: docs/images/timing_smoke.svg)
#
# Leaves build/sc/smoke.vcd and build/sc/smoke.dump for GTKWave: tools/gtkwave_shot.sh
# opens them with tools/gtkwave/smoke.gtkw (--open) or takes the README screenshots.
# Log: results/sc_wave.log, with the value of every drawn signal in every cycle.
# Exit code 0 only if the run passed and the figure was written.
# The PNG copy of the figure is made separately: python3 tools/svg2png.py <svg>.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2
out="${1:-docs/images/timing_smoke.svg}"
need_binutils
need_iverilog
mkdir -p build/sc results "$(dirname "$out")"
start=$SECONDS
{
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  sw/smoke.S with a VCD dump, figure $out"
  rc=0
  bash tools/asm2hex.sh sw/smoke.S build/sc/smoke.hex > /dev/null || rc=1
  if [ $rc -eq 0 ]; then
    bash tools/run_sc.sh build/sc/smoke.hex build/sc/smoke.wave.trace +vcd=build/sc/smoke.vcd || rc=1
  fi
  if [ $rc -eq 0 ]; then
    python3 tools/vcd2svg.py build/sc/smoke.vcd "$out" \
      --clock sc_core_tb.clk --reset sc_core_tb.rst --from 4 --to 13 \
      --dump build/sc/smoke.dump \
      --title "sw/smoke.S on the single-cycle core: one instruction per clock cycle" \
      --aria "Timing diagram of sw/smoke.S on the single-cycle core, cycles 4 to 13: clock, PC, the instruction in each cycle, ALU result, write-back value, register write enable, data memory write enable, branch or jump taken, and next PC" \
      --footer "Drawn by tools/vcd2svg.py from build/sc/smoke.vcd (tb/sc_core_tb.sv +vcd=), Icarus Verilog 12." \
      "sc_core_tb.clk" \
      "sc_core_tb.dut.u_core.pc#PC register" \
      "sc_core_tb.dut.u_core.instr:asm#instruction this cycle" \
      "sc_core_tb.dut.u_core.alu_y#ALU result" \
      "sc_core_tb.dut.u_core.result#write-back value" \
      "sc_core_tb.dut.u_core.reg_write#regfile write enable" \
      "sc_core_tb.dut.u_core.dmem_we%amber#data memory write" \
      "sc_core_tb.dut.u_core.pc_src%rose#take branch/jump" \
      "sc_core_tb.dut.u_core.pc_next#next PC" || rc=1
  fi
  if [ $rc -eq 0 ]; then
    echo "PASS wave: build/sc/smoke.vcd and $out written"
  else
    echo "FAIL wave: see the lines above"
  fi
  echo "# elapsed $((SECONDS - start)) s"
} 2>&1 | tee results/sc_wave.log
grep -q '^PASS wave' results/sc_wave.log
