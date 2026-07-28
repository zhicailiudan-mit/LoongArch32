# LoongArch32 CPU — GPT 网页版交接说明

更新日期：2026-07-29
交接分支：`timing/lsu-forward-tree`

## 1. 协作边界

后续使用普通 GPT 网页聊天完成架构分析、优化规划、RTL 编写和代码审查。
GPT 不负责运行本机 Vivado，也不得假装已经通过仿真。用户负责把 GPT 给出的
补丁应用到本地、运行 Vivado/XSim，并把完整统计和错误日志贴回同一个对话。

普通 GPT 聊天未必会自动读取 `AGENTS.md`，因此每次新对话都必须先要求它读取：

1. `AGENTS.md`
2. 本文件
3. 与当前任务直接相关的 RTL
4. 上一轮仿真结果或 PR diff

## 2. 当前架构摘要

- LoongArch32，双发射乱序执行。
- `ROB_DEPTH=32`；当前 Dispatch/Issue Queue 深度为 8。
- 两条整数/乘法/地址生成执行通道；分支和系统副作用仍受 lane 约束。
- LSU：LQ=8、SQ=4、SB=4。
- DCache：两路组相联，32 组，每 Line 8 个 32-bit Word（256 bit），数据按
  Bank 组织；包含请求 FIFO、单主 MSHR 状态、critical-word-first、同 Line
  refill buffer 命中和不同 Line Hit-Under-Refill/HUR 逻辑。
- Load completion 使用 owner/completion 队列保存顺序和身份。
- Store 使用 write-through/posted 路径，并保留 Store-to-Load forwarding。

## 3. 已完成的主要工作

### DCache/LSU

- 重构并清晰化 Banked DCache 结构。
- 实现 refill 期间的同 Line buffer 访问和不同 Line Hit-Under-Refill。
- 增强 MSHR、请求 FIFO、completion/owner credit 与统计。
- Store 快速路径、字节写使能和 Store forwarding 已多轮修改。
- Completion Queue 扩到 4 项，Owner FIFO 与 credit 约束保持独立。

### 双发射与调度

- 两条执行通道均可提交 Load/Store AGU 结果。
- Load 排序会同时观察 SQ、SB 和两个执行边界 Store 槽。
- 性能报告增加 source-wait 生产者归因。

### 最新但尚未经过官方负载仿真的改动

Store Address/Data Decoupling：

- Store 只要地址源 `src0` 就绪即可从 Dispatch Queue 发射，数据源 `src1`
  可以继续等待。
- `src1_ready` 和完整 `src1_id` 经过 issue、execution、LSU 传到 SQ。
- SQ 监听两路最终 completion，以完整 `epoch+rob_tag` 补齐 Store Data。
- Store 只有在“ROB 已提交且数据已就绪”后才能释放到 SB。
- Forwarding 必须先选择最新匹配 Store，再检查赢家的数据是否就绪。
- 已修复双 Store 执行边界漏判和 source-wait 对 Store Data 的错误归因。

该阶段已经通过整核 `compile.bat` 和 `elaborate.bat`，成功生成
`tb_top_behav`，但尚未取得 Matrix/Stream/Mixed/CryptoNight 的新性能数据。

## 4. 最近一次可用性能参考

以下结果来自 Store Address/Data Decoupling 之前的仿真，仅用于下一轮同周期对比。
不同测试的阶段可能随运行时长变化，必须使用相同 cycle count 比较。

| 测试 | 周期 | Retire IPC | 双发射周期占比 | 主要现象 |
| --- | ---: | ---: | ---: | --- |
| Matrix | 299999 | 0.6292 | 18.73% | source_wait 66.77%，DCache wait 73.13%，IQ 常满 |
| Stream | 499999 | 0.4761 | 约 0% | source_wait 80.94%，Load/Store 串行链明显 |
| Mixed | 299999 | 0.6860 | 21.32% | source_wait 60.50%，DCache wait 38.75%；运行阶段会变化 |
| CryptoNight | 499999 | 0.8571 | 21.43% | 该份日志几乎全是 Store/Multiply，需再次确认测试映像映射 |

Matrix 的代表性 300k 数据：

- `retire_IPC=0.629213`
- `source_wait=200314 (66.77%)`
- `dcache_wait=219383 (73.13%)`
- `dcache_backpressure=92018 (30.67%)`
- `iq_full=154520 (51.51%)`
- `load_issue=59713`，`store_issue=29698`
- MSHR：`alloc=4224`，`active_cycles=164196`，`critical_wait=92755`

Stream 的代表性 500k 数据：

- `retire_IPC=0.4761`
- `ISSUE_WIDTH_2_CYCLES=9`
- `source_wait=404683 (80.94%)`
- `dcache_wait=220196 (44.04%)`
- Load/Store 各约 47610 次

这些数据不等于当前分支新结果；下一次仿真必须建立新的“post-decoupling”基线。

## 5. 已知风险和测试缺口

1. 当前工作树积累了多个阶段的 DCache、LSU、调度和统计修改，必须保持每次
   后续改动很小，先建立交接分支的新功能基线。
2. `verification/unit/tb_lsu.sv` 和部分扩展 LSU 测试仍使用已废弃的
   `execute_result.rob_tag`/`completion.rob_tag` 写法，需迁移为 `uop_id` 后才能
   作为当前 RTL 的有效单元测试。
3. 性能计数器存在重叠统计，不能把 raw stall 百分比相加当成 100%。
4. CryptoNight 最近日志呈现零 Load，可能是测试映像或日志对应关系问题，应先
   验证 `test_profile.vh` 和实际加载程序。
5. 不得仅因一个测试 IPC 上升就保留改动；Matrix、Stream、Mixed、CryptoNight
   都必须无 Trace 错误，并检查至少一个简单功能测试。

## 6. 下一步优先级

### P0：建立当前交接提交的正确性和性能基线

在任何新优化前运行四个官方测试，收集 `SOURCE_WAIT_ATTRIBUTION`。回答：

- Store Address 等待和 Store Data 等待各占多少？
- `dep_load/dep_muldiv/dep_alu/dep_branch` 谁是主要 source_wait 来源？
- Stream 双发射近零是依赖链、slot 配对、前端供给，还是 LSU backpressure？
- 当前改动是否引入 Trace mismatch、Store 丢失/重复或 recovery 问题？

### P1：根据新数据只选一个方向

- 若 `store_data` 高：继续评估 Store Data capture/SQ 容量和 Store drain。
- 若 `dep_load` 高：分析 Load-use 唤醒延迟、completion 到 DQ 的同周期 bypass。
- 若 `iq_no_ready` 高但依赖归因低：检查 issue pairing、lane 限制和 hold 逻辑。
- 若 `icache_wait/frontend_empty` 高：审查 Fetch buffer、ICache refill 和分支恢复。
- 若 DCache `critical_wait` 高：评估第二 MSHR；不要与现有 Line HUR 重复设计。

### P2：测试基础设施

迁移 LSU testbench 到完整 `uop_id`，添加定向用例：

- Store 地址先到、数据晚到；
- 数据 completion 与 SQ accept 同周期；
- branch/system flush；
- ROB tag 复用但 epoch 不同；
- 较老 ready Store + 较新 unready Store + 同地址 Load；
- 双 Store 同周期进入执行边界；
- byte/halfword/word forwarding。

## 7. 每轮仿真回传格式

用户应按以下格式回复 GPT：

```text
测试名称：Matrix / Stream / Mixed / CryptoNight
Git commit：<hash>
仿真周期：<cycles>
功能结果：PASS，或贴出第一条 Trace mismatch / fatal

<DISPATCH-ELASTIC>
<完整 PERF-SUMMARY>
<完整 SOURCE_WAIT_ATTRIBUTION>
<IPC>
<LSU-PHASE2A-STATS>
<DCACHE-HUR-STATS>
<DCACHE-REQ-FIFO-STATS>
<DCACHE-MSHR-STATS>
```

若出现错误，优先发送第一条错误前后至少 50 行日志，并停止讨论性能。
