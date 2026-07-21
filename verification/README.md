# Loong CPU 模块级验证基线

这里的测试只针对单个 RTL 模块或一个紧密耦合的模块组，不替换现有的 Trace 集成测试。

## 目录

- `common/`：公共断言任务和测试辅助代码。
- `unit/`：ROB、DispatchQueue、RAT、LSU、DCache 的独立 SystemVerilog TB。
- `run_unit_tb.ps1`：使用 Vivado XSim 编译并运行一个单元 TB。

## 运行方式

在工程根目录执行：

```powershell
.\verification\run_unit_tb.ps1 -Test rob16
.\verification\run_unit_tb.ps1 -Test dispatch_queue4
.\verification\run_unit_tb.ps1 -Test rat32
.\verification\run_unit_tb.ps1 -Test rat32_ext -Mode all -Seed 20260716 -Cycles 10000 -MinCoverage 90
.\verification\run_unit_tb.ps1 -Test lsu
.\verification\run_unit_tb.ps1 -Test dcache
```

## RAT32 / Rename 扩展验证

`unit/tb_rat32_extended.sv` 是真实 `RAT32` 接口上的独立 reference-model 自检平台。设计契约、接口缺口、规范歧义和不适用项见 `RAT32_RENAME_ANALYSIS.md`。运行可表达的 mutation suite：

```powershell
.\verification\run_rat32_mutations.ps1 -Seed 20260716
```

## ROB16 扩展验证

`unit/tb_rob16_extended.sv` 是带独立 reference model、逐周期 scoreboard、历史环形日志和约束随机激励的 ROB 验证平台。它覆盖：

- 双分配、lane0-only 部分接收、满/空、回绕、多次回绕、背压；
- 双提交、完成乱序但提交按序、完成与提交同周期；
- Query 所有 live entry、未完成/已完成 entry、未分配/已释放 tag、四端口同 tag/不同 tag、wraparound 及 query 与 completion/commit/recovery 同周期；
- complete lane0/lane1 独立输入、相邻/不相邻/乱序/同 tag/非法 tag/recovery 后 tag/reallocation 相邻 completion；
- x0、无目的寄存器、branch/store/CSR-like uop、x0 与普通目的寄存器双提交；
- recovery 保留恢复点、杀死年轻指令、老指令保留，以及 recovery 与完成/提交/分配同周期；
- 重复 completion、非法 tag、reset 中断活动、tag 重用后的合法 completion；
- 每周期以输出端口比较 occupancy、live mask、alloc ready/tag、commit 和 query（包括状态转换后 query）；同时检查完整 allocation payload 的 ready/valid 稳定性、提交顺序和 reset invariants，并收集功能覆盖率。`head/tail` 不作为主判断依据，仅可通过 TB 内的 `ENABLE_WHITEBOX_CHECKS` 打开为诊断。
- scoreboard、assertion、protocol、timeout 使用统一错误计数；默认 mandatory coverage 门槛为 90%，并支持 `MIN_COVERAGE` 和 `STOP_ON_ERROR` plusarg。

当前 `ROB16` 接口没有异常字段和物理寄存器字段，因此精确异常和 old/new physical register 回收测试会明确打印 `ROB-EXT-SKIP`，待接口补全后再接入，测试平台不会伪造不存在的协议。

运行 directed 测试：

```powershell
.\verification\run_unit_tb.ps1 -Test rob16_ext -Mode directed -Seed 123
```

运行可复现的合法约束随机测试：

```powershell
.\verification\run_unit_tb.ps1 -Test rob16_ext -Mode random -Seed 20260716 -Cycles 10000
```

带覆盖率门槛和遇错即停：

```powershell
.\verification\run_unit_tb.ps1 -Test rob16_ext -Mode all -Seed 20260716 -Cycles 10000 -MinCoverage 90 -StopOnError 1
```

也可以运行全部 directed + random：

```powershell
.\verification\run_unit_tb.ps1 -Test rob16_ext -Mode all -Seed 20260716 -Cycles 10000
```

RTL 的 recovery 优先级会取消同周期 allocation packet，并对空/非法 recovery target 做安全 no-op。lane1-only 和旧 completion ABA 不属于当前连续 packet/无 generation 接口的合法可判定功能；TB 会分别通过协议断言和 `ROB-EXT-SKIP` 明确标记。未提供 generation、exception、physical-register/free-list 接口的项目不会被伪造测试。
