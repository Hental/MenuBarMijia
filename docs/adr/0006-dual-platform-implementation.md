# ADR-0006：接受双端各自实现，用共享测试语料 + 两端 CI 对比守住一致性

日期：2026-10-27　状态：已接受（对应审计 #40）

## 背景

ADR-0003 让 `MijiaCore` 保持能在 Linux 编译，理由之一是"将来做 Windows/Linux 版时，设备合成、意图解析、习惯记忆可以直接复用"。冻结计划 v1 第 6 条也写着"先抽出共享核心，再做 Windows"。

实际情况：Windows 版用 TypeScript 重写了米家协议、加密、设备合成、意图解析和 AI 请求（约 7,300 行），与上述文档矛盾。审计 #37/#38/#39 记录了已经发生的漂移（无地区选择、AI 请求结构不同、无更新检查）。每个 bug 要修两遍、测两遍。

## 备选方案

1. **共享 Swift 核心**：`MijiaCore` 编成动态库，Tauri/Rust 经 C ABI 调用。一致性最好，但要求 Windows 构建链引入 Swift 工具链（CI、打包、调试都复杂化），且 Swift on Windows 的 FFI 生态尚不成熟。
2. **共享 Rust 核心**：协议/加密/合成移到 Rust，macOS 经 UniFFI 调用。要把 macOS 端 2 万行核心逻辑重写进 Rust，工作量和回归风险最大。
3. **接受双实现**：承认两端各自维护，把"复用"的文档说法删掉，用硬约束（共享语料 + 两端 CI 对比）守住不漂移。

## 决定

选择方案 3：

1. 修订 ADR-0003 的措辞：`MijiaCore` 保持 Linux 可编译的理由是**核心逻辑可脱离 macOS 测试**（Linux CI 全量单测），不再是"为 Windows 复用做准备"。
2. 一致性靠以下硬约束维持，并写入 `CODING_STANDARDS.md` 第 6 条：
   - 共享 golden 语料：`Tests/Fixtures/intent_golden.json`、`miot_golden.json`、`provider_golden.json`，两端测试分别断言同一份行为；
   - 两端 CI 都跑（`linux-core` + `macos` 跑 Swift 侧，`windows-core` 跑 TS 侧），新增共享能力原则上双端同 PR 落地（平台特定或分阶段落地的能力须在对应 ADR 与 README 中明确标注，如 ADR-0008 双源合并与 ADR-0010 多小米账号先落地 macOS）；
   - 审计发现的已知漂移（#37 地区选择、#38 AI 请求结构、#39 更新检查）在同一 PR 内补齐。
3. 如果未来 Windows 用户规模或漂移成本证明值得，再升级为方案 1/2——届时本 ADR 标记被取代。

## 后果

- 短期：修 bug 仍要双端各一次；好在共享语料能机械地发现行为分叉。
- 长期风险：语料覆盖不到的行为仍可能漂移；缓解是把新能力的"两端一致性"作为 PR 审查的固定检查项（Spec 轴）。
- README 中"Windows 完整复刻"等宣传措辞改为如实列出已支持/未支持能力（#44 一并修正）。
