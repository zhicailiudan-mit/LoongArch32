# LoongArch32 CPU repository guidance

## Project goal

This repository contains a LoongArch32 dual-issue out-of-order CPU implemented
in Verilog/SystemVerilog and verified with Vivado 2023.2/XSim. Optimize
performance without changing architectural behavior or the official commit
trace.

The human operator runs the long Vivado simulations on Windows. An AI working
from the GitHub repository must plan, inspect, edit, and review the RTL, then
give the operator exact commands and the statistics that must be returned.

## Important directories

- `rtl/mycpu/`: active CPU RTL.
- `rtl/mycpu/DCache.v`: current two-way, banked DCache implementation.
- `rtl/mycpu/dispatch_queue.sv`: eight-entry issue/dispatch queue.
- `rtl/mycpu/load_store_unit.sv`: LQ/SQ/SB integration and forwarding.
- `rtl/mycpu/lsu_arbiter.sv`: load/store request, owner, and completion flow.
- `rtl/mycpu/performance_counters.sv`: simulation performance report.
- `run_vivado/project/loongson.xpr`: Vivado project.
- `verification/`: module-level test sources. `verification/build/` is generated.
- `docs/GPT_WEB_HANDOFF.md`: current architecture, baseline, risks, and next work.

## Non-negotiable correctness rules

1. Match dependencies and completions with the full `uop_id` (`epoch` plus
   `rob_tag`), never with the tag alone.
2. Preserve precise branch recovery and system flush behavior. A squashed uop
   must never complete, write a register, release a Store, or update memory.
3. Stores remain architecturally ordered. A committed younger Store must never
   bypass an older Store waiting for commit or data.
4. Store-to-Load forwarding is byte accurate. For each requested byte, first
   choose the youngest matching older Store; only then test whether its data is
   ready. A ready older value must not bypass a newer unready Store.
5. Both execution lanes can present Store address-generation results. Both must
   participate in Load ordering before they become visible in the SQ.
6. MMIO reads and other irreversible operations must remain non-speculative and
   obey the existing ROB-head restrictions.
7. Preserve ready/valid payload stability while stalled and avoid combinational
   loops across the scheduler, execution lanes, LSU, completion router, and ROB.
8. Do not silently change cache geometry, memory protocol, trace format, test
   selection, or simulation duration.

## Working method

For every optimization:

1. Read `docs/GPT_WEB_HANDOFF.md` and inspect the relevant RTL and call sites.
2. State one measurable bottleneck and one bounded hypothesis.
3. Write a short plan covering behavior, interfaces, recovery, ordering,
   backpressure, assertions, and expected performance counters.
4. Make the smallest coherent change. Do not combine unrelated optimizations.
5. Review the complete diff for functional correctness before discussing speed.
6. Provide a unified diff or complete replacement contents for every changed
   file. Never use ellipses or omit unchanged portions inside a replacement.
7. Give the Windows Vivado commands the human must run and list the exact output
   sections required for evaluation.
8. Do not claim success until the human reports a clean trace and simulation.

## Local verification

The generated XSim directory is normally:

```powershell
cd run_vivado\project\loongson.sim\sim_1\behav\xsim
cmd /c compile.bat
cmd /c elaborate.bat
```

Success requires `compile.bat` and `elaborate.bat` to exit with code 0 and the
elaboration log to contain `Built simulation snapshot tb_top_behav`.

Module tests are launched from the repository root:

```powershell
.\verification\run_unit_tb.ps1 -Test <name>
```

Some older LSU testbenches still reference the obsolete direct `rob_tag` field
instead of `uop_id.rob_tag`. Do not treat that known testbench migration issue
as proof that the integrated RTL is wrong, but do not hide it either.

## Required simulation evidence

Ask the operator to return:

- all trace mismatches, `$fatal`, `$error`, and serializer overflow messages;
- `[PERF-SUMMARY-BEGIN]` through `[PERF-SUMMARY-END]`;
- `[IPC]` and `[DISPATCH-ELASTIC]`;
- `SOURCE_WAIT_ATTRIBUTION`;
- `[LSU-PHASE2A-STATS]`;
- `[DCACHE-HUR-STATS]`, `[DCACHE-REQ-FIFO-STATS]`, and
  `[DCACHE-MSHR-STATS]`.

Compare equal workloads at equal cycle counts. Correctness is mandatory. Keep an
optimization only when it has a defensible cross-workload benefit or a clear
architecture-enabling purpose without a meaningful regression.

## Repository hygiene

- Never commit `verification/build/`, `xsim.dir/`, `.Xil/`, `.wdb`, `.sdb`,
  `.pb`, logs, or other generated Vivado/XSim artifacts.
- Do not use destructive Git commands or overwrite unrelated work.
- Use a dedicated branch for each optimization and keep commits reviewable.
- Do not edit generated IP output products unless the task explicitly requires
  regenerating an IP core.
