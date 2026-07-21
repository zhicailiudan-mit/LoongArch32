# RAT32 / Rename 基础版验证分析

## 结论与范围

真实 `RAT32` 是 2-wide、32 个架构寄存器到 16 项 ROB producer tag 的 speculative pending map；tag 宽 4 bit。它不是物理寄存器重命名器：没有 PRF、FreeList、new/old physical tag、RRAT/ARAT，也没有 exception/global-flush 输入。因此这些项目不能在不伪造接口的前提下验证，TB 会打印 `RAT-EXT-SKIP`。

`RenameDispatch` 的 lane 0 为 older、lane 1 为 younger。`RenameBundle` 只接受连续 packet：lane1 只有在 lane0 valid 时才进入该边界；单独从 `RAT32.alloc1_*` 驱动 lane1 是合法的模块级端口行为，但不是集成路径的合法 decode packet。

## 抽象契约

1. 每个非 x0 架构源读取当前最新的未提交 ROB producer；无 producer 时 `pending=0`。
2. 一个握手成功且 `reg_write && rd!=0` 的 uop 把该 rd 更新为自己的 ROB tag；no-dest 与 x0 不更新映射。
3. lane1 源必须看到同周期 lane0 的写入（RAW bypass）；lane0 源读取周期开始时的 map。
4. 同周期 WAW 后 lane1 tag 为最终 mapping。
5. commit 仅在 `(rd,tag)` 同时匹配当前 producer 时清 pending；较老 commit 不能清除 younger overwrite。
6. lane0 checkpoint 包含 lane0 自身的 mapping；lane1 checkpoint 包含同周期两个 lane 的 mapping。
7. recovery 恢复 checkpoint snapshot，并用 `rob_live_mask` 删除已不再 live 的 producer；recovery 优先于同周期 allocation。
8. x0 永远 `pending=0`。query tag 在 `pending=0` 时不具有功能意义，checker 不比较该 tag。

模型只维护抽象的 speculative map、checkpoint snapshot 和 checkpoint-defined 集合；不复制 DUT 的循环、数组赋值优先级或存储格式。checkpoint 的契约定义为“恢复到 checkpoint uop 完成重命名后的架构可见 speculative map”：lane0 checkpoint 包含 lane0 自身，lane1 checkpoint 还包含同 packet 的 older lane0。`rob_live_mask` 的使用来自独立所有权不变量——恢复后 RAT 不能指向 ROB 已判死的 producer，而不是来自 DUT 数组实现。

`recovery + commit` 的同周期优先级没有接口规范，因此完全排除在 scored reference model、coverage 和 PASS/FAIL 之外。隔离的 characterization 在独立 reset 区间只记录 DUT 观察结果，随后再次 reset；它不根据 DUT 修改期望，也不能帮助测试通过。

## 行为分类

### 明确接口/结构行为

- width=2，ARCH_REGS=32，ROB_DEPTH=16，ROB_TAG_W=4。
- reset 为低有效异步 reset；当前 speculative map reset 为空。
- 四个 query 端口中 q2/q3（lane1 sources）有 lane0 same-cycle bypass。
- recovery 对 RAT 状态优先于 allocation；commit 可在 recovery 同周期清除恢复快照中的匹配 producer。

### 微架构实现选择

- map/checkpoint 使用寄存器数组；checkpoint 以 ROB tag 直接索引。
- pending map 记录 producer ROB tag，而不是分配物理寄存器。
- commit 通过 tag 相等判断是否仍是当前 producer。

### 可疑行为或规范歧义

1. `checkpoint_valid/tag` 在 reset 时未初始化。对从未建立的 `recover_tag` 发 recovery 会传播 X；合理协议应由上游保证 tag 有效，或接口增加 `checkpoint_valid`/非法恢复安全语义。当前 TB 将 undefined checkpoint 归类为 protocol error，不把 DUT 现象写入 golden model。
2. `RAT32` 本身允许 `alloc1_valid=1, alloc_valid=0`；集成的 `RenameBundle` 不允许 lane1-only packet。这是模块端口与集成协议之间的歧义。
3. `flush` 只清 `RenameBundle`，不直接清 `RAT32`；系统 flush 是否总伴随有效 recovery 需要上层协议保证。
4. 没有 checkpoint occupancy/valid/free 接口，无法检测 checkpoint full、非法 tag 或 tag reuse 覆盖仍存活 checkpoint。
5. ROB tag 复用没有 generation/epoch；正确性依赖 ROB 不把 stale commit/recovery 送入 RAT。

## 自检与覆盖

`tb_rat32_extended.sv` 包含独立 reference model、独立 stimulus-side ROB 生命周期模型、四端口逐寄存器扫描、pre/post-edge checker、x0/X assertions、32-cycle history、五类错误计数、watchdog、18 个 mandatory hit counter，以及 `SEED/CYCLES/TEST/STOP_ON_ERROR/MIN_COVERAGE` plusargs。FAIL 和 `STOP_ON_ERROR` 都使用 `$fatal(2)`；回归脚本同时检查进程状态和 FAIL 日志。

定向覆盖：双 lane、lane1-only 模块端口、RAW、双源 RAW、WAW、RAW+WAW、x0、no-dest、单/双 commit、lane0/lane1 checkpoint、嵌套 checkpoint、tag wrap、live-mask filter、recovery+allocation 优先级、activity reset。随机激励提高同 rd 与 lane1 读取 lane0 rd 的概率；allocation 只选择 free ROB tag，双路 tag 唯一，commit 严格选择 allocation-order queue 的最老 0～2 项，recovery 只选择 live checkpoint，其 live mask 来自 checkpoint 时的 ROB 生命周期快照。由于接口没有 generation/epoch，仍被任一 live checkpoint snapshot 引用的旧 tag 也被保留，直到对应 checkpoint commit/recovery 后才允许复用。所有 tag 范围均由 `NTAG` 推导。

覆盖门槛对 `directed`、`random`、`all` 全部强制执行。纯 random 使用集成协议 profile，分母明确排除该 profile 禁止的 lane1-only 和 recovery+allocation；其他适用点仍必须满足 `MIN_COVERAGE`。lane1-only 在直接 `RAT32` 端口上定义为合法模块能力并由 directed 覆盖，但不是 `RenameBundle` 集成路径的合法 packet。

## Mutation 对应

`run_rat32_mutations.ps1` 在临时 build 目录产生 DUT 副本，不修改 RTL 源文件。当前可表达 mutation：两个 lane1 source 的 RAW bypass、lane1 state tag、x0 invariant、commit tag compare、lane1 checkpoint 漏 lane0、lane0 checkpoint 漏自身、recovery 漏 live-mask。物理寄存器、FreeList、old_phys、RRAT/ARAT 与 exception mutations 因接口不存在而不适用。
