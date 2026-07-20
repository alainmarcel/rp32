# rp32 — Yosys synthesis via UHDM/Surelog (uhdm2rtlil)

This directory adds a **Yosys synthesis flow driven by the Surelog SystemVerilog
front end** ([uhdm2rtlil](https://github.com/alainmarcel/uhdm2rtlil)), alongside
the existing `syn/` (Yosys‑slang) and `fpga/*/yosys` flows.

Surelog parses the design to UHDM and the uhdm2rtlil plugin imports it to Yosys
RTLIL (`read_sv`), so the full IEEE‑1800 SystemVerilog the rp32 cores use
(packages, structs, interfaces) is synthesisable through Yosys.

The gate‑level result is verified two ways:

* **Co‑simulation** (`cosim.sh`): the synthesized netlist is run against the
  original RTL under Verilator and the outputs are compared every cycle.
* **Functional simulation** (`fsim.sh`): the SoC boots its program on the
  synthesized netlist under Yosys `sim` and the GPIO output is checked against
  the values the program writes.  This needs **no independent reference**, so it
  validates the full **TCB‑interface** SoCs (`mouse_soc`, `degu_soc`) that
  Verilator can't elaborate (it can't unroll the `tcb_lite_if` delay‑line
  `for (genvar i=1; i<=CFG.HSK.DLY; i++)`).

## Prerequisites

* A **built** [uhdm2rtlil](https://github.com/alainmarcel/uhdm2rtlil) checkout
  (provides `out/current/bin/yosys`, `build/uhdm2rtlil.so`, and the Yosys
  `simcells.v`).  Point `UHDM2RTLIL_ROOT` at it (defaults to `~/uhdm2rtlil`):

  ```bash
  export UHDM2RTLIL_ROOT=/path/to/uhdm2rtlil
  ```

* **Verilator 5.x** in `PATH` (for the co‑simulation) — the repo's
  `submodules/verilator` build works; see `settings-verilator.sh`.

## Usage

```bash
cd syn/uhdm2rtlil

./build.sh --list             # list the catalogued designs
./build.sh mouse_soc_simple   # synthesise one design (work/<top>_uhdm.v/.json)
./cosim.sh                    # gate-level co-sim of the Mouse simple SoC
./fsim.sh  mouse_soc          # boot the SoC on its netlist, check GPIO (func-sim)
./run.sh                      # synthesise ALL designs + co-sim + func-sim, table
```

The design catalog (cores + SoCs) lives in `designs.sh`; `build.sh <name>` picks
one.  The full SoCs need the TCB submodule:

```bash
git submodule update --init submodules/tcb
```

## Design status

`./run.sh` synthesises every design, co-simulates the ones Verilator can build
as an independent reference, and **functionally simulates** the SoCs (boot the
program, check GPIO — no reference needed):

| design              | synth | co-sim | func-sim | notes |
|---------------------|:-----:|:------:|:--------:|-------|
| `mouse`             | ✅ | (det.) | – | standalone core; only deterministic streams are equiv-able |
| `hamster`           | ✅ | (det.) | – | standalone core (decoder rewired to the flat `dec_t`) |
| `degu`              | ✅ | (det.) | – | standalone core |
| `mouse_soc_simple`  | ✅ | ✅ **PASS** | ✅ **PASS** | discrete Mouse SoC, inline RAM — cosim 0 mismatches / 6000 cyc; boots to `gpio_o`=0x5a→0xff |
| `mouse_soc`         | ✅ | n/a | ✅ **PASS** | full TCB-interface Mouse SoC; Verilator can't build the interface RTL (delay-line genloop), so no cosim — instead func-sim boots it: `gpio_e`=0x5a→0xff |
| `degu_soc`          | ✅ | n/a | ✅ **PASS** | full TCB-interface Degu SoC; func-sim boots it: `gpio_e`=0x5a→0xff |

All six designs synthesise to clean netlists.  The interface SoCs report a few
benign warnings (undriven CPU `req.byt`/`lck`/`ndn` don't-cares, cosmetic
interface-array port resizes) but are **functionally correct end-to-end** — the
CPU boots the program from the initialised imem and the store propagates through
the TCB interface fabric to the GPIO peripheral's register.  (GPIO register 0 is
the *output-enable* on the `tcb_dev_gpio` peripheral, so the boot writes land in
`gpio_e`; the discrete `mouse_soc_simple` GPIO maps register 0 to `gpio_o`.)

## The memory‑preserving synthesis flow

A design with an initialised ROM/RAM (`$readmemh`) **must not** be run through
the plain `synth` / `synth_*` shortcut: those run `opt_mem`, which trims an
initialised memory to its "used" width and mangles the `$meminit` constant
(e.g. `0x800200B7` → garbage), so the fetched program reads back wrong and the
CPU never boots. `build.sh` therefore drives the passes explicitly:

```
read_sv → proc → flatten → memory_collect   (no opt_mem / memory -nomap)
        → opt -full → techmap → dfflegalize → abc → opt_clean
```

`flatten` **before** `memory_collect` is what lets the `$readmemh` init reach
the combinational read port.

## Files

| file            | purpose                                                          |
|-----------------|------------------------------------------------------------------|
| `designs.sh`    | design catalog: name → sources + top (cores + SoCs)             |
| `build.sh`      | synthesise one design through uhdm2rtlil (memory‑preserving flow)|
| `run.sh`        | synthesise all designs + co‑sim + func‑sim, print a status table |
| `cosim.sh`      | synth + Verilator co‑simulation (RTL vs gate netlist)            |
| `cosim_tb.sv`   | testbench: RTL and gate netlist side by side, per‑cycle compare  |
| `cosim_main.cpp`| Verilator driver (reset, free‑run, exit non‑zero on mismatch)    |
| `fsim.sh`       | boot the SoC on its netlist (Yosys `sim`) and check GPIO output   |
| `boot.hex`      | tiny deterministic boot program (GPIO writes) for the SoC RAM    |

`work/` (netlists, logs, Verilator objects) is generated and git‑ignored.

## Notes

* The **complete Mouse SoC** co‑simulates cleanly because its boot program is
  deterministic. The **standalone `r5p_mouse` core** synthesises correctly too,
  but under *random* instruction stimulus it diverges on the design's own `'x`
  don't‑cares (illegal opcodes), so only a deterministic instruction stream is a
  meaningful equivalence check for it — use the SoC for the end‑to‑end gate check.
* This flow depends on two uhdm2rtlil front‑end fixes for the rp32 cores: comb
  `case` blocking‑read value threading, and byte‑enable (`mem[a][hi:lo] <= …`)
  memory‑write emission. Use a uhdm2rtlil build that includes them.
