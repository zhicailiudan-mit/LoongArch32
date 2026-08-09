# LoongArch32 SoC

哈尔滨工业大学（深圳）龙芯杯 2026 个人赛初赛提交工程。仓库保留的是比赛提交版本，重点展示 LoongArch32 处理器、缓存、乱序后端以及 ThinPad SoC 集成代码；未完成时序收敛和功能回归。

## Repository layout

```text
src/soc/                 Synthesizable SoC RTL; top module: thinpad_top
src/soc/mycpu/           CPU core, frontend, backend, cache and memory system
src/soc/xilinx_ip/       Xilinx IP configuration files (.xci/.xcix)
run_vivado/constraints/  Board pin, clock and timing constraints
run_vivado/flow/         Vivado project, implementation and timing helpers
run_vivado/simulation/   Board/SRAM simulation models supplied by the template
asm/                     LoongArch assembly example and build files
```

## Building the Vivado project

The project-generation script expects to be launched from Vivado's Tcl console:

```tcl
cd run_vivado
source flow/create_vivado_project.tcl
```

The script targets the `xc7a200tfbg676-2` device and sets `thinpad_top` as the top-level module. Implementation and bitstream helper scripts are in `run_vivado/flow/`.

## Notes

- Generated Vivado/XSim directories, reports, waveforms, checkpoints and binaries are intentionally excluded from version control.
- Timing and functional behavior depend on the Vivado version, board constraints and the exact RTL revision. Check the generated reports before drawing performance conclusions.
- The repository is kept as a clean submission snapshot; experimental debugging work belongs outside this public repository.
