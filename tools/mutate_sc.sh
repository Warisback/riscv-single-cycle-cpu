#!/usr/bin/env bash
# mutate_sc.sh: plant one bug at a time in a copy of the design and check that
# the tests catch it.
#
#   usage: tools/mutate_sc.sh                 every mutant (log: results/sc_mutants.log)
#          tools/mutate_sc.sh NAME [NAME...]  only these mutants (log: results/sc_mutants_part.log)
#          tools/mutate_sc.sh --list          list the mutant names
#
# Each mutant is one exact text replacement in a copy of rtl/, tb/ and tools/
# under build/mut/<name>. A mutant is KILLED if any rv32ui riscv-test or any of
# random programs 1..10 (tools/randgen.py --n 300) fails on it: the trace
# differs from the ISS trace, TOHOST != 1, an assertion fires, or a timeout.
# The unmodified control copy runs first and must pass every program, or the
# harness itself is broken. The control copy exists because an earlier version
# of this script had a path bug that made every mutant fail.
# The programs and their ISS traces are built first if they are missing or out
# of date. At the end, tools/mutant_report.py reads the runs in build/mut/ and
# writes how each mutant was caught to results/sc_mutants_detail.log
# (results/sc_mutants_part_detail.log for a subset).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT" || exit 2

# name # file # exact text # replacement # what the bug means   (fields split on '#')
MUTANTS=(
"none_control#rtl/sc_core.sv#assign src_b = alu_src_b ? imm : rs2_val;#assign src_b = alu_src_b ? imm : rs2_val;#CONTROL: no change; must SURVIVE or the harness itself is broken"
"jalr_bit0_kept#rtl/sc_core.sv#target_sum[0] & ~jalr#target_sum[0]#JALR does not clear bit 0 of its target"
"x0_writable#rtl/regfile.sv#end else if (we && wa != 5'd0) begin#end else if (we) begin#writes to x0 are not dropped"
"link_is_alu#rtl/sc_core.sv#RES_PC4: result = pc_plus4;#RES_PC4: result = alu_y;#JAL/JALR write the ALU result instead of pc+4"
"auipc_zero#rtl/sc_core.sv#SRCA_PC:   src_a = pc;#SRCA_PC:   src_a = 32'd0;#AUIPC adds the immediate to 0 instead of the PC"
"srcb_always_imm#rtl/sc_core.sv#assign src_b = alu_src_b ? imm : rs2_val;#assign src_b = imm;#R-type instructions use the immediate instead of rs2"
"jal_not_taken#rtl/sc_core.sv#(branch && taken) || jump || jalr;#(branch && taken) || jalr;#JAL writes its link but does not jump"
"blt_unsigned#rtl/branch_unit.sv#assign lt  = (\$signed(a) < \$signed(b));#assign lt  = (a < b);#BLT/BGE compare unsigned"
"sra_as_srl#rtl/alu.sv#ALU_SRA:  y = \$signed(a) >>> shamt;#ALU_SRA:  y = a >> shamt;#SRA shifts in zeros"
"lb_zero_extend#rtl/load_unit.sv#assign lb_val  = {{24{shifted[7]}},  shifted[7:0]};#assign lb_val  = {24'b0, shifted[7:0]};#LB zero-extends"
"store_ignores_be#rtl/sc_core.sv#assign dmem_be    = st_be;#assign dmem_be    = 4'b1111;#every store writes the whole word"
)
NRAND=10   # random programs 1..NRAND, RAND_N=300

if [ "${1:-}" = "--list" ]; then
  for entry in "${MUTANTS[@]}"; do
    IFS='#' read -r name file from to what <<< "$entry"
    printf '%-18s %s\n' "$name" "$what"
  done
  exit 0
fi

# Which mutants to run: all, or the names given (the control always runs first).
selected=" none_control "
log=results/sc_mutants.log
detail=results/sc_mutants_detail.log
if [ $# -gt 0 ]; then
  log=results/sc_mutants_part.log
  detail=results/sc_mutants_part_detail.log
  for want in "$@"; do
    found=0
    for entry in "${MUTANTS[@]}"; do
      [ "${entry%%#*}" = "$want" ] && found=1
    done
    if [ $found -eq 0 ]; then echo "mutate_sc: unknown mutant '$want' (see --list)" >&2; exit 2; fi
    selected="$selected$want "
  done
fi

# ---- inputs: the riscv-tests images and golden traces, random programs 1..NRAND
need_binutils
need_riscv_tests
need_iverilog
mkdir -p results sw/gen build/mut
ensure_riscv_tests || exit 1
for s in $(seq 1 "$NRAND"); do
  python3 tools/randgen.py --seed "$s" --n 300 --out "sw/gen/rand_$s.S" > /dev/null &&
    bash tools/asm2hex.sh "sw/gen/rand_$s.S" "sw/gen/rand_$s.hex" > /dev/null &&
    python3 tools/iss.py --hex "sw/gen/rand_$s.hex" --trace "sw/gen/rand_$s.iss.trace" > /dev/null ||
    { echo "FAIL could not build random program $s"; exit 1; }
done
NRT=$(ls sw/riscv-tests/*.hex | wc -l | tr -d ' ')

run_mutant() {
  local name="$1" file="$2" from="$3" to="$4" what="$5"
  local m="$ROOT/build/mut/$name"           # absolute: the runs below cd into it
  local rt=0 rr=0 first="" hex t s verdict
  rm -rf "$m"
  mkdir -p "$m"
  cp -r rtl tb tools "$m/"                   # programs and golden traces are read from the real sw/
  if ! python3 tools/mutate_sc_apply.py "$m/$file" "$from" "$to"; then
    printf '%-18s NOT APPLIED (text not found exactly once in %s)\n' "$name" "$file"
    return
  fi
  for hex in sw/riscv-tests/*.hex; do
    t=$(basename "$hex" .hex)
    if ! (cd "$m" && bash tools/run_sc.sh "$ROOT/$hex" "$m/$t.rtl.trace" > "$m/$t.out" 2>&1 \
          && python3 tools/compare.py "$ROOT/sw/riscv-tests/$t.trace" "$m/$t.rtl.trace" > /dev/null 2>&1); then
      rt=$((rt + 1))
      [ -z "$first" ] && first="$t"
    fi
  done
  for s in $(seq 1 "$NRAND"); do
    if ! (cd "$m" && bash tools/run_sc.sh "$ROOT/sw/gen/rand_$s.hex" "$m/rand_$s.rtl.trace" > "$m/rand_$s.out" 2>&1 \
          && python3 tools/compare.py "$ROOT/sw/gen/rand_$s.iss.trace" "$m/rand_$s.rtl.trace" > /dev/null 2>&1); then
      rr=$((rr + 1))
    fi
  done
  verdict=SURVIVED
  [ $((rt + rr)) -gt 0 ] && verdict=KILLED
  printf '%-18s %-8s riscv-tests failing %2d/%d (first: %-6s)  random failing %2d/%d   %s\n' \
    "$name" "$verdict" "$rt" "$NRT" "${first:--}" "$rr" "$NRAND" "$what"
}

start=$SECONDS
{
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)  planted bugs in the single-cycle core ($NRT riscv-tests, random programs 1..$NRAND)"
  for entry in "${MUTANTS[@]}"; do
    IFS='#' read -r name file from to what <<< "$entry"
    if [ $# -eq 0 ] || [[ "$selected" == *" $name "* ]]; then
      run_mutant "$name" "$file" "$from" "$to" "$what"
    fi
  done
} | tee "$log"

# report: how each mutant was caught (reads build/mut/ only; never changes the verdict)
report() {
  local names
  names="$(grep -E ' (KILLED|SURVIVED) ' "$log" | awk '{print $1}')"   # one per line
  python3 tools/mutant_report.py --out "$detail" --log "$log" $names > /dev/null &&
    echo "how each mutant was caught: $detail"
}

if ! grep -q '^none_control .*SURVIVED' "$log"; then
  echo "FAIL harness: the unmodified control copy did not pass, so every verdict above is meaningless" | tee -a "$log"
  echo "# elapsed $((SECONDS - start)) s" >> "$log"
  report
  exit 1
fi
killed=$(grep -v '^none_control' "$log" | grep -c ' KILLED ')
total=$(grep -v '^none_control' "$log" | grep -cE ' (KILLED|SURVIVED|NOT APPLIED) ')
if [ "$killed" -eq "$total" ] && [ "$total" -gt 0 ]; then
  echo "PASS mutants: $killed of $total killed (control copy passed every program)" | tee -a "$log"
  rc=0
else
  echo "FAIL mutants: $killed of $total killed (control copy passed every program)" | tee -a "$log"
  rc=1
fi
echo "# elapsed $((SECONDS - start)) s" | tee -a "$log"
report
exit $rc
