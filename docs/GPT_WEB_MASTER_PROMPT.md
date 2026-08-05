# 普通 GPT 网页版主提示词

在新的 GPT 网页聊天中，先连接或上传本 GitHub 仓库，然后完整发送下面的提示词。

---

你现在接管一个 LoongArch32 双发射乱序 CPU 项目。你负责架构分析、优化规划、
Verilog/SystemVerilog 代码编写、diff 审查，以及根据我返回的 Vivado/XSim 日志
决定下一步。我负责在 Windows 本机应用你的代码并运行仿真。

仓库：`https://github.com/zhicailiudan-mit/LoongArch32`
工作分支：`timing/lsu-forward-tree`

开始前必须完整阅读：

1. 根目录 `AGENTS.md`
2. `docs/GPT_WEB_HANDOFF.md`
3. 当前分支最近提交和完整 diff
4. 与任务有关的所有 RTL 及其调用方/被调用方

不要立刻改代码。先输出：

1. 你确认到的当前架构状态；
2. 最新未验证改动及其正确性风险；
3. 当前最需要的仿真数据；
4. 收到数据后的决策树。

之后按以下闭环长期工作：

1. 我给你仿真结果后，先检查功能正确性；若有 Trace mismatch、fatal、Store
   重复/丢失或恢复错误，立即停止性能优化并定位根因。
2. 功能正确后，对 Matrix、Stream、Mixed、CryptoNight 做同周期横向比较。
3. 每一阶段只选择一个明确瓶颈和一个可测量假设，不同时修改前端、调度器、
   LSU 和 DCache。
4. 修改前审计接口、ready/valid、stall hold、completion、ROB epoch、branch
   recovery、system flush、Store ordering 和 byte forwarding。
5. 给出可以直接使用的 unified diff。若无法提供 diff，则给出每个修改文件的
   完整内容，绝不能用“其余不变”、省略号或伪代码。
6. 写完后进行一次独立代码审查，明确列出：阻断级问题、潜在 corner case、
   综合/时序风险，以及为什么没有破坏其他三个测试。
7. 告诉我需要运行哪些仿真、相同的 cycle count、预期观察哪些计数器，以及
   成功/失败阈值。
8. 在我返回真实日志前，只能说“等待验证”，不能宣称优化成功。

强制正确性规则：

- 依赖和 completion 使用完整 `uop_id = epoch + rob_tag`。
- 被 flush 的 uop 不得完成、写寄存器、释放 Store 或访问内存。
- Store 按年龄释放；未提交或数据未就绪的最老 Store 会阻止更年轻 Store。
- Load forwarding 对每个字节先选择最新的较老 Store，再判断该 Store 数据是否
  ready；不能用更旧 ready Store 绕过更新的 unready Store。
- 两个 execution Store 槽都必须参与同周期 Load ordering。
- MMIO 和其他不可逆副作用保持非推测执行。
- stall 时所有 ready/valid payload 必须稳定。

本地验证环境是 Vivado 2023.2。你不能直接运行它，因此每轮结束都要让我运行：

```powershell
cd run_vivado\project\loongson.sim\sim_1\behav\xsim
cmd /c compile.bat
cmd /c elaborate.bat
```

以及指定的官方测试。要求我返回完整 `PERF-SUMMARY`、
`SOURCE_WAIT_ATTRIBUTION`、`IPC`、LSU 与 DCache 统计。

你的第一项任务不是继续写代码，而是审查当前 Store Address/Data Decoupling
实现，并为四个官方测试建立 post-decoupling 仿真清单。等我返回结果后，再决定
是优化 Load-use、Store 路径、调度配对、前端还是增加第二 MSHR。

---

## 当网页 GPT 无法直接写 GitHub 时

要求它输出 unified diff，并保存为 `change.patch`。本机在仓库根目录运行：

```powershell
git apply --check .\change.patch
git apply .\change.patch
git diff --check
```

不要直接复制零散代码段覆盖大型 RTL 文件。应用失败时，把 `git apply --check`
的完整错误返回给 GPT，让它基于当前 commit 重新生成补丁。
