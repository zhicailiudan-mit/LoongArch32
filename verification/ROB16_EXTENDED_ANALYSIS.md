# ROB16 扩展验证分析

## 当前 RTL 的真实接口

- dispatch width：2；当前端口按连续双发射 packet 使用，lane1 只有在 lane0 同时有效时才有意义；lane0-only 是合法的部分接收场景。
- commit width：2；ROB 没有外部 commit ready，完成后自动按序提交。
- entry 数量：16。
- tag 格式：`ROB_TAG_W=4`，tag 是 4 位环形索引 `0..15`。
- head/tail/count：RTL 内部保存 4 位 `head`、4 位 `tail` 和 5 位 `count`；`alloc_tag[0]=tail`，`alloc_tag[1]=tail+1`。
- dispatch fire：正常周期对合法 packet 使用 `alloc_valid[i] && alloc_ready[i]`；TB driver 在 stalled 时保持完整 `issue_uop_t` payload。由于 RTL 时序块中 `recover_valid` 优先于 allocation，且 `alloc_ready` 已在 recovery 周期被门控，recovery 同周期的 allocation packet 按 flush 被取消；TB 不把这种被 squash 的 packet 当作 fire，同时保留该场景的定向检查。
- completion 定位：只使用 `completion_t.rob_tag` 查找 `valid[tag]`，没有 generation/epoch。
- commit 条件：head entry 已完成即可提交；第二提交必须满足 head1 已完成、head 已提交且不越过 recovery 点。
- completion 与 commit 同周期：完成信号是组合旁路，允许当前周期 head/head1 直接提交；时序块随后写入完成状态并清除提交 entry。
- recovery：只有 `recover_valid/recover_tag`，没有独立的 branch flush、exception flush 或 flush reason；恢复点自身保留，tag 之后的年轻 entry 被杀死。
- exception：ROB16 接口没有 exception valid/code/subcode，也没有 exception redirect/CSR 信息，因此精确异常目前不能在 ROB 单元直接验证。
- 物理寄存器：`issue_uop_t`、`completion_t`、`commit_t` 没有 new physical destination、old physical destination 或 FreeList 接口，物理寄存器释放目前不可验证。
- store/branch/CSR：uop 中存在 `is_ld_st`、`is_br_jmp`、`system_op` 等字段，但 ROB 只保存 PC、架构目的寄存器、完成值和完成写使能；类型信息没有存入 ROB 状态，也没有独立的 store/branch/CSR 提交语义。
- Query：`query_done` 只有在 tag 当前 live 且 entry 已完成并且 `result_we/reg_write=1` 时才有意义；未分配或已释放 tag 的 `query_value` 没有定义，TB 只严格比较 `query_done=0`。live、未完成、已完成、四端口同 tag/不同 tag、completion/commit/recovery 同周期均由 reference model 比较。
- completion 双端口：ROB 没有禁止两个端口命中同一 tag 的输入断言；TB 按 RTL 真实优先级建模：组合 query/commit 优先 lane0，时序 completion 写入按 lane0 后 lane1。
- x0/无目的：`has_dest/result_we` 在 allocation 时由 `reg_write && arch_rd!=0` 决定；commit 的 `reg_write` 仍可能被 completion 旁路覆盖，因此测试使用真实 completion `reg_write` 语义，不伪造物理寄存器释放。

## 当前 RTL 中需要重点暴露的风险

1. recovery target 必须来自 live entry；RTL 现在对空/非法 target 做安全 no-op，不再创建 phantom occupancy。
2. tag 只有 4 位，没有 generation；completion 接口无法验证或防止旧响应污染新 entry，旧响应必须由上游取消。
3. recovery 与 completion/commit/dispatch 的组合优先级需要通过同周期测试确认。
4. 当前 `alloc_ready[1]` 的容量判断与连续 packet 语义之间仍存在部分接收协议风险，待明确 retry/拆包协议后再扩展测试。
5. exception、物理寄存器释放、FreeList、异常精确性不属于当前 ROB16 可观察协议，需要在接口补全后新增另一层测试。

扩展 TB 使用独立的逻辑顺序表和 sequence ID，不复制 RTL 的 head/tail/count 更新过程。主 scoreboard 只依赖输出端口；`dut.head/tail` 仅在 `ENABLE_WHITEBOX_CHECKS=1` 时作为可选诊断。它包含 Query post-transition 比较、完整 payload 的 ready/valid 稳定性 SVA、occupancy/live_mask/提交顺序断言、统一错误计数、covergroup、32 项 mandatory coverage hit counter、独立延迟 completion scheduler 和 watchdog。generation/异常/物理寄存器相关项目会明确记录为不可测试项。
