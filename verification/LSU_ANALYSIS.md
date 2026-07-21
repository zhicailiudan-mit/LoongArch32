# LoadStoreUnit RTL 行为分析与抽象契约

## 1. 真实接口与资源

- LSU 顶层 `LoadStoreUnit` 每周期只有一个 `execute_result_t` 输入，因此最多接收 1 条 uop；不存在双 issue lane，lane1-only/dual issue 对该顶层不适用。
- Load/Store 共享同一个 execute 输入和同一个 DCache request 口。
- LQ、SQ、StoreBuffer 深度均为 4。LQ/SQ 使用压缩数组，StoreBuffer 为 FIFO。
- 没有外部 LQ/SQ tag；内部 entry 仅携带 4-bit ROB tag，没有 wrap generation 或 epoch。
- 地址和 Store 数据在同一个 `execute_result` 中同时到达；没有 address-ready/data-ready 分离协议。
- reset 为低有效异步 reset。

## 2. Load 路径

- aligned Load 在 execute edge 进入 LQ；LQ 只允许未 issue 的队首请求 DCache。
- `LSUArbiter` 只允许一个 DCache transaction outstanding。读请求在 `rready=1` 时以单周期 `ren=4'hf` 发出，随后等待无 ID 的 `valid/rdata`。
- Load request 总是读取完整 32-bit word；byte offset 和 sign/zero extension 在 response 后由 `LoadDataAligner` 完成。
- flush 清空整个 LQ。已发 Load 不能取消 DCache response，但通过 `active_killed` 禁止 completion。
- 没有 completion ready；completion 是单周期、不可回压的输出。

## 3. Store 路径

- Store 地址和数据生成成功、且 SQ 可接收时立即产生 ROB completion，但不会立刻写 DCache。
- ROB commit tag 将 SQ entry 标为 committed；随后 entry 进入 StoreBuffer，最后才请求 DCache。
- byte/half Store 在 LSU 内按地址低位生成 `wen` 和移位后的 `wdata`。
- posted Store 在 request handshake 同周期完成 StoreBuffer pop；非 posted Store 等待无 ID 的 `wresp`。
- 普通 flush 删除未提交 SQ entry，保留已 committed 或 flush 同周期 commit 的 entry；StoreBuffer 没有 flush 输入，因此全部保留。

## 4. Memory ordering、forwarding 与仲裁

- 当前没有 Store-to-Load forwarding，也没有 partial-byte merge。
- `MemoryOrderChecker` 只按 4-byte word 地址比较；只要 SQ 或 StoreBuffer 中存在同 word Store，Load 就阻塞。它不携带程序年龄，因此也无法区分 older/younger Store。
- Load request 固定优先于 StoreBuffer drain；没有轮询或 bounded fairness，连续 Load 可能使不同地址 Store 饥饿。
- 没有 memory violation detection、replay、replay tag 或 redirect 输出。

## 5. Recovery、ABA 与异常

- LSU 只有全局 `flush`，没有 `recover_tag/live_mask`，无法保留 recovery point 或任意更老 speculative Load/Store；所有 Load 和未提交 Store 都被清除。
- committed SQ entry 与 StoreBuffer 在 branch flush 下保留，符合“已提交 Store 不得被普通分支恢复删除”的基本契约。
- Load response 没有 transaction ID。由于 arbiter 严格限制为单 outstanding，并在被杀请求返回前保持 `WAIT_LOAD`，当前结构不会在旧 response 未返回时发新 Load，因此靠串行化避免 LQ slot ABA，而不是靠 generation 检测。
- `memory_response_t` 没有 error/exception/MMIO/uncached 字段；`completion_t` 也没有 exception 字段。精确 access fault、translation fault、MMIO、atomic、fence/barrier 语义无法由此接口验证。
- `ldst_unalign` 只导致普通 `reg_write=0` direct completion；没有 exception code/bad address 输出，精确非对齐异常属于接口缺口。

## 6. 抽象 LSU 契约

以下契约独立于队列索引和 RTL 优先编码实现：

1. 每个被接受且未 squash 的 Load/Store 只能 completion 一次。
2. 被 flush 的 Load 不得在旧 response 返回时产生 completion。
3. speculative Store 不得产生 DCache 写事务；commit 后才允许产生不可撤销写入。
4. committed Store 必须在普通 branch flush 后保留并最终 drain。
5. 每个 DCache request 只在对应 ready 为真时算作握手；未握手不得改变参考内存。
6. 单 outstanding 协议下，每个 response 必须对应唯一活动请求，且不得重复消费。
7. Load 结果由字节寻址参考内存独立计算，再按访问类型做符号/零扩展。
8. Store byte-enable 和 lane-aligned wdata 由 access size 与地址低位独立计算。
9. 同 word 的 Store/Load 顺序必须给出程序顺序正确结果；阻塞、forward 或 drain-then-load 都是允许的实现选择，但不得读到旧值。
10. valid 输入在 `ldst_suspend=1` 时必须由上游保持；LSU 不得把未接受的 Store误报 completion。
11. direct completion 与 memory response 同周期竞争时，两者都必须最终各完成一次。
12. reset/flush 后 LQ/SQ 可见 speculative occupancy 必须归零；committed StoreBuffer 不受普通 branch flush 破坏。

## 7. 明确规范、实现选择与疑点

### 明确规范行为

- Store commit 前无 DCache side effect。
- killed Load response 不得 completion。
- byte/half/word load alignment 和 sign/zero extension必须符合访问类型。
- DCache request 以 ready 握手，response 只可消费一次。

### 微架构实现选择

- 4-entry 压缩队列、FIFO StoreBuffer、单 outstanding cache port。
- Load 固定优先于 Store drain。
- 同 word Store 存在时选择阻塞 Load，而不是 forwarding。

### 可疑行为/规范歧义

- `MemoryOrderChecker` 不含年龄，younger Store 也可能阻塞 older Load；功能值可能仍正确，但可能死锁/饥饿。
- 固定 Load 优先级无公平保证，StoreBuffer 可能长期不 drain。
- flush 无 age mask，无法实现“保留 recovery point 与更老 speculative memory op”的精确分支恢复。
- 无 generation/transaction ID；正确性依赖单 outstanding 永不放开旧请求。
- response 与 direct completion 的 pending 机制只有 1 项；持续 direct completion 的上游行为和进度保证需单独验证。
- 非对齐访问没有可观察异常信息，不能把普通无写回 completion 自动当作正确异常语义。
- forwarding、partial merge、violation/replay、MMIO、atomic/fence 均未实现；后续阶段应以 capability gap 或潜在设计缺陷报告，而不能在 golden model 中伪造。

## 9. 阶段验证发现的 RTL 缺陷

### Stage 3：StoreQueue commit 与 release 同周期丢失 commit 标记

状态：已修复，并通过阶段一至阶段三及原 LSU baseline 回归。

最小触发条件：

1. SQ 中依次存在 tag0、tag1、tag2、tag3 四条未提交 Store；
2. 第一个周期双提交 tag0/tag1；
3. 下一周期在 SQ release tag0 的同时双提交 tag2/tag3；
4. StoreBuffer backpressure，便于观察最终状态。

合理预期：四条 Store 都成为 committed，并按 commit 顺序最终进入 StoreBuffer。

实际行为：`StoreQueue` 的 commit loop 对 tag2/tag3 写 `committed<=1`，但同一个 `always_ff` 后续 release compaction 又把旧的 `committed[j+1]` 写到移动后的 slot，覆盖同周期 commit 结果。最终 StoreBuffer 只收到 tag0/tag1，SQ 留下两条 `committed=0` 的 tag2/tag3，无法继续 release。

修复：压缩 entry 时把本周期 `commit0/commit1` 同步折叠到被搬移的 entry，并为新提交 entry 生成对应 commit sequence，避免后执行的 nonblocking assignment 覆盖 commit-loop 更新。

验证：固定 seed `20260716` 下，Stage 3 mandatory coverage 为 `25/25`，scoreboard、assertion、protocol、timeout、memory-model 错误计数均为 0；Stage 1、Stage 2 和原 `tb_lsu.sv` 回归也全部通过。

该问题由 stage3 scoreboard 作为正式失败报告，不属于 specification ambiguity；修复后阶段三门禁已经通过。

### Stage 4：recovery、在途响应与同周期竞争

- 已验证空 LSU flush、speculative LQ/SQ flush、squashed Load 旧响应、response+flush 同周期、flush 后立即重新分配、direct completion 与 Load response 同周期、branch completion 与 branch flush 同周期、新 memory issue 与 flush 同周期及连续 recovery。
- Stage 4 mandatory coverage `36/36`，五类错误计数均为 0。
- DUT 无 `recover_tag`/age mask，无法表达 middle recovery、保留 recovery point 或保留任意更老 speculative memory op。
- DUT 无 violation/replay/redirect 输出，不能把当前同字阻塞实现当作 replay 已验证；这些项目是接口能力缺口。

### Stage 5：特殊访问、随机压力与 mutation

- 已验证非对齐 Load/Store 不产生 DCache side effect、活动 Load 中 reset 清理状态，以及基于固定 LCG 的合法约束随机 Load/Store、size、地址低位、response latency、posted/non-posted Store 和 DCache backpressure。
- Stage 5 mandatory coverage `48/48`，五类错误计数均为 0，`+SEED=20260716 +CYCLES=1000` 可复现。
- memory request 没有 MMIO/uncached 属性或 ROB-head 非推测授权；response/completion 没有异常码和 bad address；atomic/fence/barrier/CSR 没有 LSU 接口。这些能力不能由 TB 凭空补出。
- mutation campaign 在临时 RTL 副本上运行，成功编译并杀死 `load_sign_extension`、`store_byte_mask`、`squashed_load_completion`、`duplicate_store_write`、`storebuffer_count` 和 `load_not_popped`，结果 `6/6`。完整适用性见 `LSU_MUTATION_MATRIX.md`。

## 8. 分阶段验证边界

1. 阶段一：基础 Load/Store、DCache request/response、alignment、completion、基础 backpressure。
2. 阶段二：验证当前 ordering block 行为能否给出正确值，并用独立逐 byte forwarding 契约测试报告 forwarding/merge capability gap。
3. 阶段三：LQ/SQ/SB occupancy、顺序 commit、posted/non-posted drain、flush 保留 committed Store。
4. 阶段四：flush/in-flight response/direct-completion 竞争；memory violation/replay 和精确 middle recovery按接口能力判定。
5. 阶段五：受支持随机压力与 mutation；MMIO/exception/atomic/fence 明确列为接口未实现。
