# Makefile: one target per check (GNU make on Linux or macOS).
# Each target runs one bash script in tools/ and the scripts write their logs to
# results/. On Windows without make, run the same scripts from Git Bash through
# WSL with tools/wsl, for example: tools/wsl run_unit_all.sh (see `make help`).

N         ?= 20
START     ?= 1
RAND_N    ?= 300
MUTANTS   ?=

.DEFAULT_GOAL := help
.PHONY: help deps check unit adv oracle smoke riscv-tests random long mutants
.PHONY: wave gtkwave png lint versions all regress clean

help:
	@echo "make deps         fetch riscv-tests (pinned commit) and pcpp     tools/setup_deps.sh"
	@echo "make check        what CI runs: lint, unit, adv, smoke, riscv-tests, random (N=$(N))"
	@echo "                                                                 tools/check.sh N"
	@echo "make unit         the 9 unit testbenches                         tools/run_unit_all.sh"
	@echo "make adv          the 7 independent-oracle checks (alias: make oracle)"
	@echo "                                                                 tools/run_adv_all.sh"
	@echo "make smoke        sw/smoke.S on the core vs the ISS              tools/run_all_sc.sh smoke"
	@echo "make riscv-tests  the 40 applicable rv32ui tests vs the ISS      tools/run_all_sc.sh riscv"
	@echo "make random       N random programs (N=$(N) START=$(START) RAND_N=$(RAND_N))"
	@echo "                                                                 tools/run_all_sc.sh rand N START RAND_N"
	@echo "make long         20 long random programs (seeds 1001-1020)      tools/run_all_sc.sh rand 20 1001 2000"
	@echo "make mutants      10 planted bugs, each must be caught           tools/mutate_sc.sh [names]"
	@echo "make wave         smoke run with a VCD and a timing diagram      tools/make_wave_fig.sh"
	@echo "make gtkwave      GTKWave screenshots (needs a display)          tools/gtkwave_shot.sh"
	@echo "make png          PNG copies of docs/images/*.svg                tools/svg2png.py"
	@echo "make lint         compiler warnings: iverilog -Wall on every TB  tools/lint_sc.sh"
	@echo "make versions     tool versions to results/tool_versions.log     tools/tool_versions.sh"
	@echo "make all          full regression, about 22 min here (alias: make regress)"
	@echo "                                                                 tools/regress_all.sh"
	@echo "make clean        delete build/, sw/gen/ and sw/riscv-tests/"
	@echo ""
	@echo "Windows (Git Bash, no make): tools/wsl <script> [args], e.g. tools/wsl run_unit_all.sh"
	@echo "                             and for the PNGs: py tools/svg2png.py docs/images/*.svg"

deps:
	bash tools/setup_deps.sh

# What CI runs: lint, unit, adv, smoke, riscv-tests and random, as one script
# that runs every step and fails if any step failed (log: results/check.log).
check:
	bash tools/check.sh $(N)

unit:
	bash tools/run_unit_all.sh

adv:
	bash tools/run_adv_all.sh

oracle: adv

smoke:
	bash tools/run_all_sc.sh smoke

riscv-tests:
	bash tools/run_all_sc.sh riscv

random:
	bash tools/run_all_sc.sh rand $(N) $(START) $(RAND_N)

long:
	bash tools/run_all_sc.sh rand 20 1001 2000

mutants:
	bash tools/mutate_sc.sh $(MUTANTS)

wave:
	bash tools/make_wave_fig.sh

gtkwave:
	bash tools/gtkwave_shot.sh

png:
	python3 tools/svg2png.py docs/images/*.svg

lint:
	bash tools/lint_sc.sh

versions:
	bash tools/tool_versions.sh

all:
	bash tools/regress_all.sh

regress: all

clean:
	rm -rf build sw/gen sw/riscv-tests
