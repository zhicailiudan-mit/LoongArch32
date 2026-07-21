# LSU Mutation Matrix

Mutation 使用 `verification/run_lsu_mutation.ps1` 在独立 build 目录复制 RTL，再修改副本；源 RTL 不会被 mutation campaign 改写。编译失败不算被检测，只有成功编译、且被 scoreboard/assertion/protocol/watchdog/memory checker 报告的 mutant 才算 killed。

| 用户要求的 mutation | 当前接口状态 | campaign |
|---|---|---|
| Load byte sign extension 错误 | 支持 | `load_sign_extension` |
| Store byte mask 错位 | 支持 | `store_byte_mask` |
| forwarding 选择最老 Store | forwarding 未实现 | 不适用，能力缺口 |
| 从 younger Store forwarding | forwarding/age 未实现 | 不适用，能力缺口 |
| Store 数据未就绪仍 forwarding | 地址/数据分离未实现 | 不适用，能力缺口 |
| partial forwarding 未合并 Cache | forwarding 未实现 | 不适用，能力缺口 |
| recovery 漏清年轻 Load | 无 recover age mask | `squashed_load_completion` 覆盖可观察的 kill 路径 |
| branch recovery 错清 committed StoreBuffer | Stage 3 定向 checker 覆盖 | 尚未自动 mutation |
| squashed Load 仍 completion | 支持 | `squashed_load_completion` |
| 旧 response 写入重用 entry | 单 outstanding 串行避免 ABA | Stage 4 定向 checker 覆盖 |
| Load completion 重复 | 支持 | `load_not_popped` 覆盖未释放/泄漏路径 |
| Store 写内存重复 | 支持 | `duplicate_store_write` |
| memory violation 漏报 | violation/replay 未实现 | 不适用，能力缺口 |
| 无冲突时错误 replay | replay 未实现 | 不适用，能力缺口 |
| full/count 更新错误 | 支持 | `storebuffer_count` |
| backpressure 时改变 payload | 接口没有独立 request valid | 不适用，协议缺口 |
| MMIO 推测提前发出 | 无 MMIO 属性/ROB-head 输入 | 不适用，接口缺口 |
| issue0/issue1 选择同一 entry | LSU 只有单 execute 输入 | 不适用 |

