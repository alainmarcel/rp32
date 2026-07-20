#!/bin/bash
# ============================================================================
# rp32 — functional (gate-level) simulation of a uhdm2rtlil-synthesised SoC.
#
# Boots the SoC's memory image (boot.hex) on the synthesised netlist using
# Yosys' built-in `sim` and checks that the GPIO output reaches the values the
# boot program writes.  This is the functional counterpart to cosim.sh: it needs
# NO independent Verilator reference, so it validates the TCB-INTERFACE SoCs
# (mouse_soc / degu_soc) that Verilator can't elaborate (it can't unroll the
# `for (genvar i=1; i<=CFG.HSK.DLY; i++)` interface delay line).
#
#   export UHDM2RTLIL_ROOT=/path/to/uhdm2rtlil   # built checkout (default ~/uhdm2rtlil)
#   ./fsim.sh [design] [cycles]                  # design default: mouse_soc
#
# The boot program (boot.hex) is:
#     lui  x1, 0x80020        ; x1 = GPIO base
#     li   x2, 0x5a           ; sw x2, 0(x1)     ; write 0x5a to GPIO reg 0
#     li   x2, 0xff           ; sw x2, 0(x1)     ; write 0xff to GPIO reg 0
#     j    .                  ; spin
# GPIO register 0 is the OUTPUT-ENABLE register on the TCB `tcb_dev_gpio`
# peripheral (offset 3'h0 -> gpio_oe -> gpio_e), and the OUTPUT-DATA register on
# the discrete mouse_soc_simple GPIO (-> gpio_o).  So a PASS is: gpio_e OR gpio_o
# takes the values 0x5a then 0xff.  Both are the same boot program landing in the
# correct register for that SoC's GPIO map.
#
# --- why the write_verilog round-trip (see synth step) --------------------
# The frontend emits the imem `$readmemh` as a `$meminit_v2` with ABITS = the
# full 32-bit address, so `memory_collect` won't fold it into the `$mem_v2` INIT
# on the direct read path (INIT stays all-x -> the CPU fetches x).  Writing the
# netlist and reading it back re-derives the meminit with the memory's own
# address width, which memory_collect then folds correctly (imem[0] = 0x800200b7).
# `sim -zinit` is also REQUIRED: without it the FFs power up at x and the x on the
# CPU state never clears (this is a sim artefact, not a netlist bug — it happens
# even on the cosim-proven mouse_soc_simple).
set -euo pipefail
cd "$(dirname "$0")"

ROOT="${UHDM2RTLIL_ROOT:-$HOME/uhdm2rtlil}"
YOSYS="$ROOT/out/current/bin/yosys"
PLUGIN="$ROOT/build/uhdm2rtlil.so"
export R5P_RTL="$(cd ../../hdl/rtl && pwd)"
export R5P_TCB="$(cd ../../submodules/tcb/hdl/rtl && pwd 2>/dev/null || echo /nonexistent)"
source ./designs.sh

DESIGN="${1:-mouse_soc}"
CYCLES="${2:-600}"
design_select "$DESIGN"          # sets TOP and SRCS

for f in "$YOSYS" "$PLUGIN"; do
    [ -e "$f" ] || { echo "ERROR: $f not found (build uhdm2rtlil / set UHDM2RTLIL_ROOT)" >&2; exit 1; }
done

mkdir -p work
cp -f boot.hex work/mem_if.mem

echo "== [1/2] synthesising + simulating $DESIGN ($TOP), $CYCLES cycles"
( cd work && "$YOSYS" -m "$PLUGIN" -q -p "
    read_sv -parse -nobuiltin -top $TOP $SRCS
    hierarchy -check -top $TOP
    proc; flatten; memory_collect
    opt -full; techmap; opt
    write_verilog -noattr fsim_net.v
    design -reset
    read_verilog -sv fsim_net.v
    hierarchy -top $TOP
    proc; flatten; memory_collect; opt_clean
    sim -clock clk -reset rst -rstlen 8 -n $CYCLES -zinit -vcd fsim.vcd
" ) || { echo "ERROR: synthesis/sim failed" >&2; exit 1; }

echo "== [2/2] checking GPIO reached the boot values (0x5a then 0xff)"
python3 - "work/fsim.vcd" <<'PY'
import re, sys
vcd = open(sys.argv[1]).read()
defs = re.findall(r'\$var \w+ (\d+) (\S+) (\S+)(?: \[[\d:]+\])? \$end', vcd)
sig = {s: n for w, s, n in defs if n in ('gpio_o', 'gpio_e')}
time = 0; last = {}; seq = {'gpio_o': [], 'gpio_e': []}
for line in vcd.splitlines():
    if line.startswith('#'):
        time = int(line[1:])
    else:
        m = re.match(r'b([01xz]+) (\S+)', line)
        if m and m.group(2) in sig and last.get(m.group(2)) != m.group(1):
            last[m.group(2)] = m.group(1)
            v = m.group(1)
            if 'x' not in v and 'z' not in v:
                seq[sig[m.group(2)]].append((time, int(v, 2)))
ok = False
for name in ('gpio_e', 'gpio_o'):
    vals = [v for _, v in seq[name]]
    if 0x5a in vals and 0xff in vals and vals.index(0x5a) < vals.index(0xff):
        for t, v in seq[name]:
            print(f"   {name} = 0x{v:02x} @ t={t}")
        print(f"PASS: {name} took 0x5a then 0xff (boot program ran to completion)")
        ok = True
        break
if not ok:
    print("FAIL: neither gpio_o nor gpio_e reached 0x5a -> 0xff")
    for name in ('gpio_o', 'gpio_e'):
        print(f"   {name}: " + ", ".join(f"0x{v:02x}@{t}" for t, v in seq[name]) or f"   {name}: (never defined)")
sys.exit(0 if ok else 1)
PY