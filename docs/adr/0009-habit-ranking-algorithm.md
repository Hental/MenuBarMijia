# ADR-0009：习惯推荐排序算法对齐 Siri Suggestions 机制（衰减 / 日型 / 序列）

日期：2026-11-01　状态：已接受（依赖 [ADR-0006](0006-dual-platform-implementation.md) 双端实现与 #113 的 Top-4 引擎）

## 背景

#113 落地了零延迟 Top 4「猜你想控」引擎，但排序仍是「时段 × 设备 × 操作」的原始次数：三个月前的旧习惯与昨天的习惯等权，工作日与周末不分，也学不到「关书房灯之后常开卧室灯」这类先后序列。对标 Apple 的 Siri Suggestions 机制（一手来源：WWDC18 Session 211《Introduction to Siri Shortcuts》与官方文档《Donating Shortcuts》），其可借鉴且已公开描述的机制有：

1. **上下文信号 = 时段 + 星期**：「the system will look at the time, location, and other signals. For a time, we consider, among other things, the time of day and the day of the week」——本应用无位置语义（面板只在家庭网络/本机使用），故取时段 × 日型的二维上下文；
2. **模式归一化**：捐赠按「动作完成时、一次动作一次捐赠」进行，模式比较使用归一化键（`requiredUserInfoKeys` / shortcut types），时间戳不参与比较而由系统单独跟踪——对应本引擎的 `operationKey`（归一化键）与 `lastRecordedAt`（元数据分离）；
3. **特异性优先**：「更具体的模式优先于泛化模式」（Soup Chef 例：午餐时段的具体组合胜过全天泛化组合）；
4. **可删除性**：用户删除数据时同步删除捐赠——对应已有的 `forget` / 清空 / 撤销回滚。

未采用的 Apple 能力及原因：位置与移动信号（桌面托盘应用无意义）、跨设备联合学习（不出设备，且习惯库本就只存本机）、端上模型排序（候选空间仅「设备 × 操作」，规则引擎可解释且够用）。

## 决定

1. **条目身份扩展为 (bucket, dayType, targetId, operationKey)**：`dayType ∈ {weekday, weekend}`（周一至周五为工作日、周六周日为周末，是「day of the week」的刻意粗化，避免 7 × 5 = 35 个桶导致数据过度碎片化）。新记录必写；历史条目 `dayType == nil` 视为「任意日型」参与全部匹配，旧持久化数据无需迁移。
2. **特异性分桶候选池**：候选按 (bucket 匹配 且 dayType 匹配或为 nil) → (bucket 匹配) → (全部) 三层顺序抽取，跨层按 targetId 去重——即「更具体的模式优先」。
3. **时间衰减计分**：`score = count × 0.5^(距上次记录天数 / 14)`（半衰期 14 天，自定标定，Apple 未公开具体数值）；`lastRecordedAt` 缺失（旧数据）按无衰减处理，避免静默降级老用户的既有习惯。
4. **一步序列预测**：每次记录时若上一动作距今 ≤ 30 分钟，则以 `上一动作键 (targetId|operationKey) → 本动作` 累计转移次数（上限 40 条，按次数截断）；`topSuggestions` 对「与最近一次手动动作（≤ 60 分钟内）构成已知转移」的候选加 `2 × 转移次数` 的加成——这是「猜你下一步」在单步马尔可夫上的可解释实现。
5. **撤销完整性**：`RecordingReceipt` 扩展序列变更与撤销前的 `lastAction`，`unrecord` 精确回滚，与既有 habit 回滚共用同一条横幅撤销路径。
6. **双端一致**：上述结构、公式、常量（14 天半衰期、30/60 分钟窗口、加成系数 2、序列上限 40）由 `Tests/Fixtures/habit_golden.json` 双端逐字段钉死；`user_habits` 摘要补充「最近动作后的序列提示」。

## 后果

- 推荐对行为漂移敏感（搬走一个房间的习惯两周后自然淡出）、工作日/周末差异可学习、相邻操作可预测——三条都是 Apple 已公开描述的排序信号在智能家居候选空间的最小实现。
- 常量（半衰期、窗口、加成）是标定值而非学习值；若后续引入「忽略降权」反馈，可在同一 `score` 公式上叠加，不需要改结构。
- 旧数据零迁移：`dayType`/`lastRecordedAt`/序列均为可选字段，v1 持久化键不变。
