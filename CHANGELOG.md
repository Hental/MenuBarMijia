# 更新记录

## 未发布

### 修复与设备支持
- macOS 米家开关读回只在本轮确实返回电源或运行状态时确认成功，属性级失败不再沿用缓存确认。
- **领普平移推窗器（[#223](https://github.com/jryang1997/MenuBarMijia/issues/223)）**：macOS 小米云把 `window-opener` 显示成门窗卡片。点卡片在关上时打开、开着时关闭。打开会再确认一次，关闭直接执行。展开后可以拖开合百分比、暂停，并看到电量和故障。电机指令只用规格里的 Open、Close、Pause，不猜测数值。全关不会带动窗户。
- **macOS 在官方规格下载失败时仍显示设备（[#185](https://github.com/jryang1997/MenuBarMijia/issues/185)）**：小米云拿不到已发布规格时，用与 Windows `fallbackSpecs.json` 逐字节相同的表猜一个只读规格。灯、空调、风扇这类还能出现在面板上，但开关和滑条不会发出写入。测试会拦住只改一边的情况。
- **Windows 摄像机组件与画质（[#200](https://github.com/jryang1997/MenuBarMijia/issues/200), [#97](https://github.com/jryang1997/MenuBarMijia/issues/97)）**：安装包内置 `go2rtc` 与最小 LGPL FFmpeg，首次打开摄像机不再依赖 GitHub 下载；兜底下载改为 3 次重试、120 秒超时，并在失败时给出手动放置路径。实时小窗新增「自动 / 流畅 / 高清 / 超清」画质选择（默认高清），与 macOS 对齐。

### 体验
- **米家灯组折叠为一张卡片（[#189](https://github.com/jryang1997/MenuBarMijia/issues/189)）**：设备列表刷新时通过 `v2/groupv2/query_status` 缓存每个 `group.*` 灯组的成员（同时接受 `member_ship` / `membership` 两种拼写），面板把成员单灯折叠进灯组卡片，不再重复列出；灯组卡片被隐藏、离线或筛选掉时成员灯照常显示。偏好设置新增「灯组内的单灯不重复显示」（默认开启）。全关、场景、搜索与助手仍按包含成员的完整设备集合计算，折叠只影响可见列表。
- **首次启动只教三件事，进阶功能默认收起（[#180](https://github.com/jryang1997/MenuBarMijia/issues/180)）**：新手引导改为「连接账号 → 按 ⌥M 搜一个设备 → 全关后撤销」三步，完成一步才打勾；AI 指令、GrokBall、摄像机、自动化与 URL 直控收进默认折叠的「进阶」，每行注明设置位置。连接成功后，剩余两课改为面板顶部的「上手清单」，搜索与全关撤销可以边操作边看说明；三步都试过或手动关闭后才消失。AI 的「把握度低于 80% 需确认」改为「不确定时先问我」开关（默认开启），具体阈值移到高级设置；建议胶囊的悬浮说明也改成「AI 不太确定，点一下才执行」。

- **macOS 菜单栏右键菜单（[#250](https://github.com/jryang1997/MenuBarMijia/pull/250)）**：右键点击菜单栏图标即可在实时连接与演示模式之间切换，并查看 Home Assistant / 米家云端直连是否纳入当前连接；同一菜单还提供设置、检查更新与退出。菜单展开期间的点击、长按语音与面板高亮互不干扰，关闭菜单后的第一次左键点击立即生效，按 Esc 或通过键盘关闭菜单也不会再触发异常。

### 工程
- **控制中心面板拆开（[#184](https://github.com/jryang1997/MenuBarMijia/issues/184)）**：面板主文件拆成布局拖拽和顶栏底栏两份，回到 1500 行以下。房间、分组、拖拽和底栏的行为不变。issue 里点名的 Windows 文件此前已经拆完。

### 自动化
- **更多 Mac 上下文触发（[#174](https://github.com/jryang1997/MenuBarMijia/issues/174)）**：自动化规则新增摄像头 / 麦克风开始与停止使用、接通 / 断开电源、电量低于阈值、Wi-Fi 连接 / 离开（可指定 SSID）、深夜使用电脑（以 Mac 唤醒且未锁屏为准）、专注模式开关与日历会议开始前触发。全部默认关闭，需在「自动化与外部控制」中逐条添加；沿用既有的确认、乐观更新、失败回滚与 5 分钟撤销横幅。深夜规则每晚最多执行一次；日历规则按事件去重并忽略全天 / 已拒绝的事件。摄像头 / 麦克风通过 CoreMediaIO / CoreAudio 的 `IsRunningSomewhere` 读取，无需额外权限；Wi-Fi 名称需要「定位」权限，专注状态需要「专注状态」权限，日历需要完整日历访问权限，未授权时对应规则保持静默。公开 API 只提供「是否处于专注」而不提供具体专注模式名称，因此专注触发是开关而非按模式区分；摄像头 / 麦克风检测也会看到本应用自己的录音 / 录像。

### 安全
- **更新签名密钥支持过渡公钥与轮换 / 吊销预案（[#164](https://github.com/jryang1997/MenuBarMijia/issues/164)）**：双端信任集扩展为“当前签名公钥 + 可选过渡公钥”，清单 `key_id` 必须指向实际验签的密钥；新增[轮换与吊销操作手册](docs/security/update-signing-key-rotation.md)，覆盖正常轮换的 provisioning / 切主 / 退役、回滚窗口、密钥泄露与丢失、用户手动补救与审计命令。`scripts/check.sh` 现在同时校验两端过渡公钥的一致性。

### 修复
- **Windows 面板跟随任务栏位置，并可拖动到指定角落（[#204](https://github.com/jryang1997/MenuBarMijia/issues/204)）**：面板位置改按显示器工作区（`GetMonitorInfoW` → `rcWork`，经 Tauri `Monitor::work_area`）而不是整块屏幕计算，任务栏在上、左或右时面板贴近任务栏那一侧，不再为不存在的底部任务栏固定预留 54 px 的空白；托盘左键与 Alt+M 共用同一套定位逻辑（托盘点击按图标所在显示器定位），面板高度变化时保持所贴的边不动。偏好设置新增「面板位置」（跟随任务栏 / 左上 / 右上 / 左下 / 右下），选择持久化到 `%APPDATA%\MenuBarMijia\panel-placement.json`；按住面板顶部空白处可拖动窗口，松手后吸附到最近的工作区角落并记住该位置。

### 测试
- **外部接口契约回放与确定性模糊测试（[#186](https://github.com/jryang1997/MenuBarMijia/issues/186)）**：`Tests/Fixtures/contracts/` 新增脱敏录制（米家设备列表页、共享家庭房间、属性批量读取、MIoT 实例与实例索引、HA WebSocket 消息序列），由 `ContractReplayTests` 逐字段断言应用依赖的稳定字段；`FragmentedMP4Demuxer`、MIoT 规格解析与 HA 消息解析新增固定种子、限定迭代次数的模糊测试。模糊测试同时修复了大数 / 非有限值在 `JSONValue.intValue`、`idString`、MIoT `value-list` 与 HA 传感器合成中的整数转换崩溃，以及 fragmented MP4 `tfhd` / `trun` 可选字段越界读取崩溃，均附回归用例。真实 libFuzzer 目标未接入：这些解析器是可直接调用的纯函数，带种子的进程内 fuzz 已能在普通 `swift test` 中跨平台复现崩溃，无需额外 LLVM 工具链。

## 1.1.6

### 安全与凭据（[#143](https://github.com/jryang1997/MenuBarMijia/issues/143)）
- **高风险设备的手动二次确认**：电暖器、插座、摄像机、扫地机与热水器的手动卡片 / 详情操作现在与 AI 建议共用同一张高风险表，开启或加强风险前再确认一次；关闭这些设备保持直接执行，不增加让家里更安全的阻力。门窗与燃气报警为只读状态卡片，本应用无法操作。
- **锁屏时禁止控制设备**：新增默认开启的隐私设置。Mac 锁屏期间拒绝卡片 / 详情、`menumijia://` 链接、快捷指令 / App Intent 与助手命令并提示原因；定时任务与自动化规则不受影响，可在设置中关闭。
- **一键退出并吊销令牌**：设置 → 隐私新增破坏性确认的入口，退出全部米家账号、删除 Home Assistant 令牌并断开、清除已保存的 AI 密钥与云端授权；本地设备名、房间与历史保留。
- **凭据说明**：README 中英文补充米家 / HA / AI 密钥的具体存储位置、系统加密方式、旧版明文迁移规则与逐项 / 一键吊销路径。

### 修复与设备支持
- **米家登录态到期预警与菜单栏一键重扫（[#181](https://github.com/jryang1997/MenuBarMijia/issues/181)）**：macOS 端记录扫码响应声明的 `serviceToken` 到期时刻与服务端实锤失效时间（未携带到期属性的会话保持无期限，遵循 [ADR-0004](docs/adr/0004-no-pass-token-storage.md) 不猜测寿命）；距到期不足 3 天时在面板顶部显示提前重扫横幅，全部在线连接源均过期时将菜单栏图标切换为 `house.slash` 并在面板内直接弹出二维码重扫浮层，扫码完成后原地恢复控制。
- **多小米账号同时登录与跨区合并（[#140](https://github.com/jryang1997/MenuBarMijia/issues/140), [ADR-0010](docs/adr/0010-multi-account-xiaomi-sessions.md)）**：macOS 支持在设置中添加多个米家账号（包括中国大陆与海外不同云端地区），在单个面板中合并展示各账号的家庭、房间与设备，并支持按账号分区查看、切换家庭及单独移除账号（Windows 端暂保持单账号登录）。
- **同一账号下多个家庭与共享家庭（[#134](https://github.com/jryang1997/MenuBarMijia/issues/134)）**：现在会加载账号被分享的家庭，家庭成员扫码后不再一直停在「同步设备中」。
- **智能插座功率显示异常（[#129](https://github.com/jryang1997/MenuBarMijia/issues/129)）**：按设备上报的比例换算功率，不再出现巨大的数值；同时支持云端上报但此前未识别的设备。
- **新风机与更多家电（[#124](https://github.com/jryang1997/MenuBarMijia/issues/124)–[#127](https://github.com/jryang1997/MenuBarMijia/issues/127)，[#142](https://github.com/jryang1997/MenuBarMijia/pull/142)）**：新增新风机、除湿机、水暖毯、香氛机、音箱等家电的识别与控制，恢复快捷动作，并更清楚地提示 Home Assistant 局域网限制。
- **Intel Mac 支持（[#118](https://github.com/jryang1997/MenuBarMijia/issues/118)）**：本版 DMG 为通用二进制（Apple Silicon + Intel）。


### 新功能与体验提升
- **长按设备卡片直接改名（[#145](https://github.com/jryang1997/MenuBarMijia/issues/145)）**：编辑布局时每张设备卡片右上角出现铅笔徽标，点击即打开与右键菜单相同的重命名输入框；长按卡片仍进入抖动编辑状态，保存的本地别名同步用于卡片与快捷指令。
- **房间栏编辑：重命名房间与拖动排序（[#146](https://github.com/jryang1997/MenuBarMijia/issues/146)）**：长按房间胶囊进入抖动编辑状态，胶囊内的铅笔按钮打开重命名输入框，拖动胶囊即可调整顺序；房间别名与顺序分别写入 `room_aliases` / `room_custom_order`，临时消失的房间保留名称与位置，右键菜单提供左移、右移与重置，房间名也用于「全关 房间」标题。
- **macOS 26+ 默认本机 AI（[#179](https://github.com/jryang1997/MenuBarMijia/issues/179)）**：未配置云端 AI 时，macOS 26 且已开启 Apple Intelligence 的 Mac 自动改用 Foundation Models 本机模型解析复杂指令；通过引导生成（guided generation）把输出约束到现有 `DeviceIntent` 动作集合，并继续经过 `ModelActionPolicy` / `IntentValidator` 与撤销路径。全程不联网、不需要 API Key；不支持本机模型或已配置云端服务时保持原有行为。
- **GrokBall 情绪球与侧边推荐（[#114](https://github.com/jryang1997/MenuBarMijia/issues/114), [#123](https://github.com/jryang1997/MenuBarMijia/pull/123)）**：小球悬挂在面板侧边并跟随鼠标注视，点击后在外侧纵向展开四项推荐；再次点击或按 Esc 收起。屏幕边缘自动左右镜像，展开保持小球与主面板卡片位置；macOS 使用独立透明附属窗口，Windows 扩展窗口侧栏。睡眠、聆听、思考、成功与报错状态对应不同表情，成功后短暂撒花，可逆设备动作提供撤销。系统开启减弱动态效果时静态绘制表情，停止旋转、眨眼与粒子动画。Windows 内置 [TyCoding/grok-ball](https://github.com/TyCoding/grok-ball) 的 MIT 运行时，macOS 使用原生 Canvas 绘制。
  - **macOS 小球拖动与语音交互**：默认、好奇与睡眠表情改为黑球白眼；小球可自由拖动，四项推荐按其相对主面板的位置向左、右、上或下展开，上下空间较窄时自动改为横排，靠近屏幕边缘时优先避免裁切和遮挡设备。轻点展开推荐，长按 0.5 秒进入语音，拖动不会同时触发点击或语音。移除顶部快捷动作栏及对应设置项，原有动作与场景仍可通过助手执行。
  - 推荐只包含可逆设备动作，场景与单向唤醒按钮不进入侧边推荐，可通过语音或文本指令执行；有足够可执行动作时补满四项，能力不足时显示实际数量。全关且没有习惯记录的家庭也可从在线设备生成开启建议。
- **Windows 端 Home Assistant 原生连接源支持（[#117](https://github.com/jryang1997/MenuBarMijia/pull/117)）**：Windows 端新增 Home Assistant 数据源切换、原生 WebSocket 认证与注册表快照（`get_states` + `config/entity_registry/list` + `config/device_registry/list` + `config/area_registry/list`）、服务调用与场景触发、Windows 凭据管理器令牌存储，以及按服务地址与令牌指纹隔离的本地设备缓存、自定义名称、星标与操作习惯；切换连接源时自动失效旧异步请求与撤销队列。
- **macOS 通用二进制（Universal Binary: `arm64` + `x86_64`）原生支持（[#118](https://github.com/jryang1997/MenuBarMijia/issues/118), [#119](https://github.com/jryang1997/MenuBarMijia/pull/119)）**：`scripts/build_app.sh` 与 `scripts/release.sh` 默认编译并校验 `arm64 + x86_64` 双架构通用二进制，并对全架构切片执行符号表路径泄露检查与 `go2rtc` 双架构守卫，使同一份 DMG 安装包、应用内自动更新与 Homebrew Cask 同时原生支持 Apple Silicon 与 Intel Mac。
- **温湿度卡片读数配色收敛（[#122](https://github.com/jryang1997/MenuBarMijia/pull/122)）**：24pt 温度数字原用饱和蓝（`Orb.climate` #007AFF），暗色玻璃卡上会读成「发光的数字」，现改用主文本墨色；温度计图标、湿度水滴/百分比与湿度环改用新增的 `DesignTokens.Reading` 读数色（比设备徽标色低一档饱和度、按 4.5:1 以上对比度取样，浅色更深、深色更柔），暗色下不再发亮。
- **暗色模式卡片墨色统一（[#120](https://github.com/jryang1997/MenuBarMijia/pull/120), [#121](https://github.com/jryang1997/MenuBarMijia/pull/121)）**：暗色下「开启」的卡片不再铺成近白亮板，改为比关闭态高一级的深色玻璃，卡内文字、数值、模式胶囊、图标统一使用白墨；修复展开抽屉里「80%」「4200K」等白字压在近白卡面（约 1.1:1）几乎不可见、模式胶囊白字压灰底的问题。浅色模式的亮白卡片与深色亮板上的墨色保持不变。
- **全渠道操作习惯学习与零延迟 Top 4「猜你想控」推荐引擎（[#113](https://github.com/jryang1997/MenuBarMijia/issues/113)）**：
  - **手动点卡片也计入习惯记忆**：macOS 与 Windows 双端把手动点击卡片开关、调亮度 / 色温 / 空调温度、切换空调与风扇模式、摇头、触发场景、内置快捷动作与「一键全关」全部按当前时段（清晨 / 午间 / 下午 / 夜晚 / 深夜）记入 `UserHabitMemory`；点击撤销横幅会同步回滚本次习惯计数，只有命令确认成功的操作才会被学习。
  - **固定 Top 4 零延迟推荐**：`topSuggestions` 默认返回 4 项当前可执行的推荐，习惯不足时按星标常用设备、当前开启设备、「全屋关灯」内置动作与环境温湿度（室温 ≥28°C 建议降温 / ≤16°C 建议升温）确定性补齐，并过滤已处于目标状态的冗余动作。
  - **大模型后台静默增强**：打开面板 0 延迟先展示本地 Top 4；已配置大模型时，当时段切换或室温 / 湿度明显变化（1°C / 5% 阈值）在后台静默刷新缓存，不阻塞面板打开、不弹云端确认、失败时保留旧缓存。Windows 端补齐 `recommendProactiveSuggestions`（Jev SystemOne 与 OpenAI 兼容 chat 双路），与 macOS 解析语义逐字段对齐。
  - **共享语料 `habit_golden.json`**：习惯记录 / 撤销回滚与 Top-4 补齐引擎由双端 `GoldenCorpusTests` / `core.test.ts` 逐字段共同断言；Windows 设置中可查看并一键清空已学习的时段习惯。
- **习惯排序算法对齐 Siri Suggestions 机制（[ADR-0009](docs/adr/0009-habit-ranking-algorithm.md)）**：按 WWDC18-211 公开描述的排序信号升级双端习惯引擎——①条目身份加入工作日/周末日型（time of day + day of the week），更具体上下文的习惯优先，旧数据零迁移；②推荐计分引入 14 天半衰期的时间衰减（旧习惯自然淡出，`lastRecordedAt` 与归一化模式键分离，对齐 Apple「捐赠不含时间戳」原则）；③新增一步序列预测：「关书房灯后常开卧室灯」这类先后习惯（≤30 分钟窗口学习、≤60 分钟内对下一步候选加成），撤销横幅同步回滚序列计数；常量由 `habit_golden.json` 双端钉死。

## 1.1.5

### 新功能与体验提升
- **布局编辑：iOS 控制中心风格右下角圆弧手柄调大小（[#115](https://github.com/jryang1997/MenuBarMijia/issues/115)）**：macOS 与 Windows 编辑模式移除原右上角蓝色小圆点，改为卡片右下角加粗四分之一圆弧手柄；按住向外拖逐档放大（半行 → 整行 → 展开面板）、向内推回逐档缩小，跨档伴随弹簧动画与触觉反馈（macOS `NSHapticFeedbackManager.alignment`），手柄拖拽不触发卡片位置交换；轻点手柄仍按 半行 → 整行 → 展开面板 → 半行 循环切换，并保留无障碍标签与操作。手感对齐 QuotaKeeper 看板：30pt 步进阈值 + 松手按最近 100ms 指针速度投掷最多跨一档（双端共享 `TileResizeGestureMath` / `targetSize` 契约）。
- **Windows / Web 端界面重构与刷新防闪烁调优（[#108](https://github.com/jryang1997/MenuBarMijia/pull/108)）**：
  - **浅色 / 深色 / 跟随系统外观模式与毛玻璃控制中心样式**：统一收敛为经典系统毛玻璃质感与激活白卡（platter）设计，新增「跟随系统 / 浅色 / 深色」三档外观设置与底栏太阳/月亮一键切换按钮（`#btn-toggle-appearance`），实时响应系统深浅色切换。
  - **面板刷新重绘调优**：`renderNow()` 复用已挂载的外层 `.cc-popover` 容器并清除 `is-opening`，消除点击设备开关、步进温度或云端轮询重绘时反复触发整窗下拉与卡片入场动画的问题；同时保留设置抽屉 `.cc-sheet` 滚动位置，切换选项不再跳回顶部。
  - **0.5°C 空调步进温度精度显示**：摄氏度模式下自动识别并保留 `0.5°C` 小数（如 `25°C → 25.5°C → 26°C`），双端（Windows 与 macOS `L10n.temperature`）同步生效。
- **macOS 系统毛玻璃视觉统一（[#99](https://github.com/jryang1997/MenuBarMijia/pull/99)）**：移除多套自定义皮肤，统一采用原生系统玻璃材质与卡片层级。
- **Home Assistant `button.*`（Wake on LAN 局域网唤醒等）独立设备支持（[#100](https://github.com/jryang1997/MenuBarMijia/issues/100), [#107](https://github.com/jryang1997/MenuBarMijia/pull/107)）**：支持将 Home Assistant 中的主功能 `button.*` 实体（含独立配置的 WOL 唤醒按钮，自动排除重启/升级/识别等辅助诊断按钮与已禁用设备）合成为可点击卡片，采用瞬时触发语义（不残留常亮开机状态、不推入关机撤销队列），快捷指令、URL 与 AI 助手统一播报「已触发 / Triggered」。
- **菜单栏环境温度来源扩展与优先级（[#103](https://github.com/jryang1997/MenuBarMijia/issues/103), [#105](https://github.com/jryang1997/MenuBarMijia/pull/105), [#106](https://github.com/jryang1997/MenuBarMijia/pull/106)）**：当房间没有独立温湿度传感器时，支持回退读取空气净化器或空调内置温湿度并展示在顶部环境横条与 macOS 菜单栏，严格保持「独立温湿度计 > 空气净化器 > 空调」优先级，不受卡片拖拽排序影响。
- **双端应用内一键校验更新（[#102](https://github.com/jryang1997/MenuBarMijia/pull/102)）**：Windows 与 macOS 支持在设置中直接下载更新包，完成 SHA-256 与离线 Ed25519 签名校验后直接启动安装或原位替换重启。
- **米家空气净化器支持（`zhimi.airp.rma3` 等全系 MIoT 空净）（[#98](https://github.com/jryang1997/MenuBarMijia/issues/98), [#101](https://github.com/jryang1997/MenuBarMijia/pull/101)）**：支持米家云直连与 Home Assistant 空气净化器设备卡片，卡片副标题与展开抽屉实时显示 PM2.5 浓度、空气质量等级（优/良/污染分级）、温湿度与滤芯剩余寿命；支持自动 / 睡眠 / 最爱模式切换与 1–100% 风速滑块调节（调节风速时自动联动 `air-purifier-favorite` 挡位并切入最爱模式），支持中英文语音/文字控制与一键撤销。
  - **修复油烟机/晾衣架/浴霸/风扇灯被误显示成「裸灯卡片」（[#98](https://github.com/jryang1997/MenuBarMijia/issues/98) 延伸）**：非照明类设备类型在回退时跳过 `light` 副服务（诚实进入「未显示设备」列表），可写 `on` 兜底也不再冒充插座；`video-doorbell` 品类的开关/夜视/移动侦测控制同步接入。
- **智能摄像机支持、实时画面悬浮小窗与 macOS 原生画中画（[#97](https://github.com/jryang1997/MenuBarMijia/issues/97), [#101](https://github.com/jryang1997/MenuBarMijia/pull/101), [#104](https://github.com/jryang1997/MenuBarMijia/pull/104)）**：
  - 把米家云端与 Home Assistant（`camera.*`）摄像机纳入设备卡片，点击即可弹出置顶实时画面悬浮小窗（`CameraLivePanelController`），并提供镜头休眠/唤醒、夜视模式、移动侦测开关与一键撤销；摄像机默认不参与「全关」。
  - **macOS 低延迟 fMP4 硬件解码与原生画中画（PiP）**：通过内置本地 BSD UDP 中继与 `go2rtc` 流式 fMP4 管线直连 `AVPlayer` 硬件解码，支持原生 `AVPictureInPictureController` 画中画悬浮播放。
  - **Windows 端私有 P2P 直连与会话保温**：内置 MISS CS2/TUTK 密钥协商与局域网 UDP 打洞中继（`start_xiaomi_camera_bridge`），通过无窗口 `ffmpeg-silent.exe` 转码送到常驻 `<img>`；点「关闭画面」/Esc 只隐藏小窗并保温 P2P 会话 120 秒，再次点开秒出画面，超时或彻底关闭时向摄像机下发 `stop-stream` 释放单会话。

## 1.1.4

### 新功能与体验提升
- **温湿度传感器 24 小时 / 7 天历史折线图（[#90](https://github.com/jryang1997/MenuBarMijia/pull/90), [#92](https://github.com/jryang1997/MenuBarMijia/pull/92)）**：点击传感器卡片或顶部环境胶囊即可展开分时段温湿度趋势折线图，自动拉取米家云统计与蓝牙网关历史记录，融合本机采样并按家庭连接源隔离存储；展示最新、最高、最低、均值与悬停读数。
- **macOS 按住说话（`⌥M` 全局快捷键 + 菜单栏图标长按）（[#89](https://github.com/jryang1997/MenuBarMijia/pull/89), [#95](https://github.com/jryang1997/MenuBarMijia/pull/95)）**：长按 `⌥M` 或菜单栏图标即可直接唤起语音聆听，松开自动发送执行；修复 macOS 26+ 系统级状态栏长按手势触发兼容问题。
- **指令栏执行路径与耗时回执胶囊（[#94](https://github.com/jryang1997/MenuBarMijia/pull/94)）**：指令执行完成后在回复旁展示 `⚡ 本地 · <耗时>` 或 `🧠 AI · <耗时>` 胶囊，命中个人习惯记忆时附带 `💡 习惯` 标记与悬停摘要。
- **Windows 自定义全局快捷键与冲突检测（[#43](https://github.com/jryang1997/MenuBarMijia/issues/43), [#86](https://github.com/jryang1997/MenuBarMijia/pull/86), [#87](https://github.com/jryang1997/MenuBarMijia/pull/87)）**：支持在设置中录制自定义快捷键、重启保持，并在快捷键被其他软件占用时给出冲突提示与重试入口。
- **米家云插座累计电量映射（[#62](https://github.com/jryang1997/MenuBarMijia/issues/62), [#85](https://github.com/jryang1997/MenuBarMijia/pull/85)）**：macOS 与 Windows 双端解析 MIoT `power-consumption` 累计电量（kWh / 0.01kWh / Wh），接入 7 天用电统计与电费估算。

### 界面与稳定性修复
- **macOS 房间横条鼠标滚轮横滑与自动居中（[#91](https://github.com/jryang1997/MenuBarMijia/pull/91)）**：指针悬停在顶部横条时支持普通鼠标竖向滚轮平滑横向滚动，点选或快捷键切换房间时自动滚动居中。
- **macOS 经典皮肤深浅色外观修复（[#88](https://github.com/jryang1997/MenuBarMijia/pull/88)）**：修复经典皮肤在强制深色/浅色设置下面板材质与背景色未跟随切换的问题。
- **Windows 控制面板防裁切优化**：加宽面板布局并允许顶部环境、快捷场景与房间胶囊自动折行，避免多设备下控件被裁切。

## 1.1.3

### Windows 修复
- **修复每约 6 秒设备、房间和温湿度读数乱序（[#81](https://github.com/jryang1997/MenuBarMijia/issues/81)）**：1.1.2 仍直接采用云端返回的设备列表顺序。本版同步时按设备 ID 保留已有位置，更新实时状态，新增设备追加到末尾，移除已不存在的设备；已有拖拽排序继续优先。保存稳定顺序到设备缓存，重启后的首次同步也沿用缓存位置。
- **补齐轮询回归场景**：交替反转设备和房间列表，同时改变亮度和温度，验证磁贴、房间标签、温湿度读数的位置稳定；覆盖设备增删、部分自定义排序和缓存恢复。
- 本次行为修复仅影响 Windows，macOS 仅同步版本号。

## 1.1.2

### Windows 修复
- **控制中心不再因米家云轮询反复重绘（[#81](https://github.com/jryang1997/MenuBarMijia/issues/81)）**：相同快照不再触碰界面；亮度、功率和环境读数等值变化改为原位更新，保留正在操作的控件、输入草稿和键盘焦点。结构变化仅在安全时重绘，并恢复无 ID 设备控件与滑块的焦点。
- **并发与交互保护**：较旧的刷新响应不会覆盖用户刚完成的控制或撤销；拖动期间暂停 DOM 更新，松开后补上；展开详情抽屉不会无限期阻塞结构更新；命令提交后输入框清空并恢复焦点。
- **Windows 安装包**：本次行为修复仅影响 Windows；macOS 包仅同步版本号，不包含新的 macOS 行为改动。

## 1.1.1

### 安全与凭据
- **macOS 钥匙串单条目保险库与升级引导（[#16](https://github.com/jryang1997/MenuBarMijia/issues/16), [#80](https://github.com/jryang1997/MenuBarMijia/pull/80)）**：将米家登录会话、Home Assistant 令牌、各 AI 服务商 API Key 及 LG 电视指纹合并保存在单个钥匙串条目（`CredentialVault`）中，升级版本后首次启动先展示说明，最多只需授权一次钥匙串访问。
- **防止旧版明文覆盖钥匙串与写入失败丢凭据（[#73](https://github.com/jryang1997/MenuBarMijia/pull/73), [#77](https://github.com/jryang1997/MenuBarMijia/pull/77)）**：钥匙串已有凭据时不再被残留旧明文覆盖；钥匙串或 Windows 凭据管理器写入失败时保留原有已存凭据。
- **Windows 原生 HTTP 来源白名单收归宿主管理（[#74](https://github.com/jryang1997/MenuBarMijia/pull/74), [#79](https://github.com/jryang1997/MenuBarMijia/pull/79)）**：仅允许访问已保存设置中的小米云、AI 服务商与 Home Assistant 地址，不再接受前端 WebView 自行放行新域名或跨源重定向。
- **NAS 部署包摘要校验与停服前预检（[#72](https://github.com/jryang1997/MenuBarMijia/pull/72)）**：`nas/deploy_ha.sh` 与 `nas/remote_setup.sh` 强制校验本地与远端归档 SHA-256、限制远端临时目录权限为 700，并在镜像拉取与标签准备成功前不停止既有 Home Assistant 容器。

### 交互与可靠性
- **点击外部区域收起菜单栏面板**：在桌面或其他应用窗口点击鼠标左键或右键时自动收起控制面板。
- **从系统设置返回时刷新通知权限（[#55](https://github.com/jryang1997/MenuBarMijia/issues/55), [#78](https://github.com/jryang1997/MenuBarMijia/pull/78)）**：不在启动瞬间弹出系统通知授权框；用户在系统设置更改通知权限并切回 App 时自动同步最新状态。
- **撤销操作按属性与家庭隔离（[#75](https://github.com/jryang1997/MenuBarMijia/pull/75)）**：撤销只恢复该次动作修改的属性，保留用户随后手动调整的其他属性，并在切换家庭后丢弃旧家庭的待撤销动作。
- **离线插座不再写入缓存功率（[#76](https://github.com/jryang1997/MenuBarMijia/pull/76)）**：设备离线时跳过缓存电表读数，避免虚增用电统计。
- **繁体中文回执与发布脚本修复（[#69](https://github.com/jryang1997/MenuBarMijia/pull/69), [#72](https://github.com/jryang1997/MenuBarMijia/pull/72), [#82](https://github.com/jryang1997/MenuBarMijia/pull/82)）**：补齐定时描述、助手执行回执、风速与华氏温差的繁体中文翻译；移除 `Bundle.module` 编译期绝对路径引用，修复云端 macOS 发布包残留 `/Users/` 路径导致发布门禁失败的问题；轮换离线 Ed25519 更新签名密钥并改存维护者系统钥匙串（macOS 代码签名证书保持不变）。

## 1.1.0

- 降低重复设备快照引起的界面刷新，设备别名先在临时列表中应用，再比较最终状态。回归验证相同快照不触发界面状态失效，实际状态和亮度变化仍正常更新。作者报告的 CPU 降幅尚未独立复现。

### 安全与隐私
- 首次配置固定发行签名证书和可用的离线更新签名密钥，私钥留在维护者本机；代码签名证书供发布 CI 使用。免费自签名发行未经过 Apple 公证，首次安装仍可能需要在系统设置中允许打开。
- **应用内更新有了独立的信任链，发布拆成草稿 → 离线签名 → Finalize（[#17](https://github.com/jryang1997/MenuBarMijia/issues/17)）**：更新包用离线 Ed25519 私钥签名，生成 `<DMG>.ed25519.sig`，公钥编进 App（`UpdateChecker.updateSigningPublicKeyBase64`，没有可配置公钥）；下载后先校验 SHA-256，再验证签名，缺失或不匹配一律中止安装。私钥不进 CI：`release.yml` 打标签只生成**草稿**（恰好 6 个构建附件，缺 `.sig` 时提示「等待离线签名」），维护者在本机用 `scripts/sign_update.swift` 签名并显式上传公有 `.sig`，再由 `.github/workflows/finalize.yml`（手动 `workflow_dispatch`）校验 tag/版本四处一致、远程 tag 指向、草稿状态、7 个附件字节与服务端 digest，并用内置公钥验签，最后只做 `gh release edit --draft=false`——不重编译、不上传、不 `--clobber`；缺 `.sig` 或验签失败（包括 DMG 重建后仍挂旧签名）直接失败，两个工作流都不读取 `MENUBARMIJIA_UPDATE_SIGNING_KEY`。代码签名要求从只认 Bundle ID 改为钉住固定证书的 SHA-1（`Info.plist` 的 `MijiaCodeSignCertSHA1`）；pin 缺失或不是 40 位十六进制时要求退化为 `identifier … and never`，同 Bundle ID 的 ad-hoc 包同样被拒，不会退回 bundle-ID-only——本机 ad-hoc 开发包能运行，但装不了应用内更新，发布包必须用固定证书签名并带正确 pin。只有非 Apple 锚定的本地构建才会去掉 `com.apple.quarantine`，正式构建保留隔离属性交给 Gatekeeper。离线签名 CLI 见 `scripts/sign_update.swift`。
- **AI 服务商改为精确域名识别（[#19](https://github.com/jryang1997/MenuBarMijia/issues/19)）**：`openrouter.ai.evil.com`、`notopenrouter.ai` 这类仿冒地址不再被当成 OpenRouter，也拿不到你保存的 Key。自定义地址的 Key 只发给保存时的那台服务器；换地址要重新填。非 https 的公网地址一律不发送（本机和局域网除外）。macOS 与 Windows 共用 `Tests/Fixtures/provider_golden.json` 校验。
- **不再自动读取 CodexBar / 环境变量里的 Key（[#20](https://github.com/jryang1997/MenuBarMijia/issues/20)）**：改为设置里的「从 CodexBar / 环境变量导入 Key」按钮，点了才读取并复制到本机钥匙串；设置里显示来源，可一键撤销。第一次要把指令发给某个云端 AI 服务前，会先问你一次（说明发送什么、发给谁），之后可在隐私设置里撤销授权。本机/局域网模型不用确认。升级后如果之前靠 CodexBar 自动接入，需要点一次导入。
- **AI 没把握时不再自己动手（[#21](https://github.com/jryang1997/MenuBarMijia/issues/21)）**：Jev 等 AI 给出的动作，只有把握 ≥ 80% 才直接执行；低于 80%、或没给出把握度的，变成建议胶囊，点一下才执行。打开电暖器、开关插座、启动扫地机即使 AI 很有把握也要点一下（关电暖器不用）。聊天类模型（DeepSeek 等）同样适用，回执不再声称已经开了还没开的设备。macOS 与 Windows 同步。
- **Home Assistant 断线后不再自己换地址（[#18](https://github.com/jryang1997/MenuBarMijia/issues/18)）**：以前连不上时会扫描局域网，把访问令牌直接发给扫到的第一台“Home Assistant”（可能是别人伪装的）。现在只在面板顶部提示「发现了 xxx，要切换过去吗？」，点「切换」才换；点「不切换」本次不再问。和你上次选的那台实例标识（uuid）不一致的直接忽略。连续断两次才扫描，最多 10 分钟一次。设置和新手引导里的「扫描」只填地址，点保存才连接。
- **凭证只存钥匙串，不再明文回退（[#16](https://github.com/jryang1997/MenuBarMijia/issues/16)）**：上一版为了绕开升级后的钥匙串弹窗，把米家会话、HA 令牌、AI API Key 和 LG 电视配对密钥都明文镜像到了 `UserDefaults`（`defaults read com.jryang1997.MenuBarMijia` 就能读到）。现在钥匙串是唯一存储：读取不再先看明文，读到钥匙串后也不再回写；保存空值即删除。升级后首次启动会自动把旧明文键（`ha_fallback_token`、`mi_session_fallback_v1`、`keychain_fallback_*`、`lg_webos_client_key`）迁入钥匙串并删除原键，钥匙串写入失败时保留明文等下次重试。由于 App 是 ad-hoc 自签名构建，升级后系统可能询问一次钥匙串访问；拒绝授权则需重新登录一次。Windows 版保持凭据管理器存储，不受影响。
- **演示模式严格离线，不再有任何外发请求（[#47](https://github.com/jryang1997/MenuBarMijia/issues/47)）**：演示模式的「检查更新」「下载更新」「测试 AI 连接」「主动建议」以及局域网 HA 扫描、LAN 电视连接等入口都先判断后端，一旦处于演示模式就直接返回本地结果或提示，不发起任何网络请求。切回演示模式时会停止正在运行的 LAN 电视链路、取消更新任务并清理已暂存的更新包，避免上一个后端遗留的网络活动继续跑；离开演示模式后再恢复 LAN 电视连接。设置页与面板会提示「演示模式不联网，请切换数据源后…」。
- **LG 电视连接固定证书，HA 明文地址会提示（[#30](https://github.com/jryang1997/MenuBarMijia/issues/30)）**：首次连接 webOS 电视时把该次 TLS 叶证书的 SHA-256 按电视 host 存进钥匙串；之后证书变化就直接拒绝连接、停止重试并在面板弹出提示，不会再默默信任新证书。设置里新增「重新信任电视」，二次确认后清除旧证书与配对密钥，并要求在电视上重新确认配对；已保存的指纹读不出来或写入失败时同样按失败关闭处理，不会降级成「信任任何证书」。另外，HA 地址如果是 `http://` 且不是本机回环地址，设置页与新手引导会显示橙色提示（令牌将明文传输），占位符改为推荐 `https://` 或 Nabu Casa 地址。
- **米家会话不再保存账号级 `passToken`（[#27](https://github.com/jryang1997/MenuBarMijia/issues/27)）**：`passToken` 全仓库没有一处使用，会话过期一直是提示重新扫码，所以登录成功后不再持久化它；迁移旧会话时会解码后重新编码，把已存的 `passToken` 一并去掉，不需要重新登录。决策见 `docs/adr/0004-no-pass-token-storage.md`。

### 防误操作
- **「全关」更安全（[#23](https://github.com/jryang1997/MenuBarMijia/issues/23)）**：只关当前看到的设备（当前房间、未隐藏）；插座和扫地机默认不参与（插座常接路由器、冰箱、鱼缸，扫地机不该被打断回充），可在设备右键菜单里单独加入或排除，Windows 在设置里勾选。所有皮肤都改为按住 0.6 秒才执行（经典皮肤以前单击就关），按钮显示范围和台数，例如「全关·书房 (2)」。撤销横幅从 5 秒延长到 10 秒。VoiceOver 可用「关闭这 N 台设备」操作。

### 可靠性
- **米家云不再全天每 6 秒拉一次数据（[#26](https://github.com/jryang1997/MenuBarMijia/issues/26)）**：面板打开时 6 秒刷新；面板关着改成 1 分钟一次（低电量模式 3 分钟）；电脑睡眠、显示器睡眠、锁屏、切换用户时完全不请求，醒来或解锁后马上刷新一次。选了某个家庭时只拉这个家庭的设备。米家云提示请求太频繁（HTTP 429）时至少等 1 分钟再试、最长 15 分钟，并在面板上提示。想核对请求量，可在「控制台」App 搜 `Mi cloud polling`，每次切换都会记下之前拉了几次。Windows：面板打开 12 秒、收在托盘里 1 分钟。
- **合盖睡眠后，错过的定时不再一开盖就执行（[#22](https://github.com/jryang1997/MenuBarMijia/issues/22)）**：定时到点时如果已经晚了 1 分钟以上（通常是电脑在睡眠），不会自动执行，而是和“启动时发现过期”一样进入「已错过」提示并发通知，由你决定立即执行或忽略。晚几秒的照常执行。Windows 同步。

### 交互、数据与工程
- **菜单栏改用公开 AppKit 接口（#56）**：自建 NSStatusItem 与 NSPanel，保留图标状态、悬停摘要、全局热键和按住说话，移除私有 KVC 与私有选择器。
- **拼音搜索（#60）**：输入或 ⌘F 搜设备名、房间与拼音首字母；方向键选择、回车切换、右箭头展开，Esc 先清空再收起。
- **语言资源与温度单位（#52）**：新增繁体中文资源和可扩展语言表；界面按区域显示摄氏/华氏，设备协议仍使用摄氏；Windows 新增中英切换及跟随界面的语音语言。
- **本地用电记录（#62）**：按插座累计电表读数记录增量，显示七日用电与设备排行，支持电价和清除；无电表读数不估算，首次记录不回填历史。
- **快捷指令、URL 与 Mac 自动化（#57/#59）**：复用现有控制与撤销路径，URL 默认确认；自动化默认无规则，一分钟去重且不训练习惯。打包必须包含 App Intents 元数据。
- **HomeStore 按职责拆分（#48）**：主文件降到 439 行，连接、控制、指标、提醒、撤销、界面状态分别维护。
- **发布与 Mac 验收**：补充严格附件门禁、离线签名后的手动 Finalize 和 Mac 交接清单；Homebrew cask 与同步工作流已备妥，公开 tap 与跨仓库凭据尚未配置。部分 macOS 交互已完成系统快捷指令、搜索、温度单位、撤销和真实书房灯验收；未覆盖项目与发行签名边界见 `docs/qa/mac-acceptance-2026-10-27.md`。

## 1.0.6

本次提供 macOS (`MenuBarMijia-1.0.6.dmg`) 与 Windows 安装包。

### 新增与改进
- **macOS 应用内一键下载、校验、安装与重启更新 ([#4](https://github.com/jryang1997/MenuBarMijia/issues/4), [#5](https://github.com/jryang1997/MenuBarMijia/pull/5))**：在「软件更新」区域展示新版本号与可折叠的更新说明；点击「下载并安装」后直接在应用内流式下载 GitHub Releases 安装包（优先 `.dmg`，次选 `.zip`），分块校验 SHA-256 摘要，后台静默挂载解包，剥离 `com.apple.quarantine` 并通过 `codesign --verify --deep --strict` 校验 Bundle ID 与代码签名。校验通过后由用户点击「立即重启完成更新」完成原位替换与自动重启，无需手动挂载 DMG 拖入 `/Applications`。
- **自动检查更新开关与底栏轻量角标提醒 ([#4](https://github.com/jryang1997/MenuBarMijia/issues/4))**：新增「自动检查更新」偏好开关（默认开启，按 24 小时节流），在面板底栏以胶囊角标静默提示新版本或就绪状态，不弹出打断当前工作的系统模态窗口；下载失败或无写入权限时保持当前版本正常运行，并提供「重试」与「手动下载 DMG」兜底按钮。
- **跨版本更新无感保留登录态、钥匙串凭据与自定义配置 ([#4](https://github.com/jryang1997/MenuBarMijia/issues/4))**：为米家云登录会话 (`MiSessionStore`) 与各 AI 服务商 API Key (`KeychainHelper`) 补齐 `UserDefaults` 回退同步及 `kSecUseAuthenticationUISkip` 非阻塞查询，在应用启动及替换重启前自动同步凭据，消除 Ad-hoc 签名跨版本更新后的 macOS 钥匙串授权弹窗。

## 1.0.5

本次提供 macOS (`MenuBarMijia-1.0.5.dmg`) 与 Windows 安装包。

### 修复
- **修复自定义 `localhost:3425` / `127.0.0.1:3425` 兼容接口保存后被重置为 OpenRouter 的问题 ([#3](https://github.com/jryang1997/MenuBarMijia/issues/3))**：移除 `AssistantConfig.load(from:)` 中无条件拦截 `localhost:3425` 与 `127.0.0.1:3425` 的旧版遗留覆盖逻辑，完整保留用户显式保存的自定义 Base URL、模型与对应服务商槽位的 API Key。
- **统一「测试连接」与语音/文字指令执行的配置解析路径 ([#3](https://github.com/jryang1997/MenuBarMijia/issues/3))**：`HomeStore.verifyAssistantConfig(_:)` 与设置面板保存操作现统一读取持久化后的 `store.assistantConfig`（`AssistantConfig.load(from: userDefaults)`），确保「测试连接」与实际 AI 指令执行使用完全相同的生效端点、模型及凭据，消除测试假阳性；同时为非 `.standard` 的测试 `UserDefaults` 增加独立密钥存储隔离，并补充 `127.0.0.1:3425` 与 `localhost:3425` 保存/读取往返及端到端执行回归测试。

## 1.0.4

本次提供 macOS (`MenuBarMijia-1.0.4.dmg`) 与 Windows 安装包。

### 修复与新增
- **修复米家扫码登录后菜单栏图标消失 / 进程闪退问题 ([#2](https://github.com/jryang1997/MenuBarMijia/issues/2))**：定位并修复 `MiCloudProvider.loadMissingSpecs()` 在 Release (`-O`) 编译优化下，因 `withTaskGroup` 子任务直接返回内联异步挂起点的三元组 `return (model, try await source.spec(...), nil)`，触发 Swift 6.4 协程分片优化消除元组首字段（`model`）写入、进而导致未初始化内存解引用 `EXC_BAD_ACCESS (SIGBUS)` 闪退或全部设备规格被跳过（`0 supported`）的问题。现改为先完成 `await` 再构造具名 `SpecLoadOutcome` 结构体，并补充 20+ 模型并发加载回归测试与 `scripts/check.sh` 静态门禁。
- **多 AI 服务商一键切换与自有 API Key 支持（macOS & Windows 双端对齐）**：不再局限于复用 CodexBar 中的 OpenRouter 密钥，现内置 **TypeSafe Jev 官方 (`https://api.typesafe.ai/v1`)**、**OpenRouter (`~typesafe/jev-latest`)**、**DeepSeek (`deepseek-chat`)**、**通义千问 Qwen**、**智谱 GLM**、**Moonshot Kimi**、**硅基流动 SiliconFlow**、**OpenAI**、**Groq**、**Ollama 本地模型** 及自定义 OpenAI 兼容端点预设。用户可在设置页或新手引导直接填入自己的 API Key，切换服务商时自动填入推荐 Base URL 与模型名；Jev 模型自动调用 `/v1/systemone` 结构化多选决策接口，DeepSeek 等通用模型自动调用 `/v1/chat/completions` JSON 规划接口。

## 1.0.3

本次提供 macOS (`MenuBarMijia-1.0.3.dmg`) 与 Windows 安装包。

### 新增与改进
- **系统门槛下放至 macOS 14+ (Sonoma / Sequoia / Tahoe)**：将 `Package.swift` 与应用打包最低系统版本从 `macOS 26.0` 下调至 `macOS 14.0`。macOS 26 保持原生 SwiftUI `.glassEffect` Liquid Glass 液态玻璃渲染，macOS 14 与 15 自动回退至 `.ultraThinMaterial` 毛玻璃；核心库 `MijiaCore` 可直接作为独立 SwiftPM 库引用。
- **定时器磁盘持久化与过期安全确认**：延时指令（如「10 分钟后关加热器」）持久化保存在本地 `UserDefaults` (`assistant_scheduled_commands_v1`)。应用重启后，未到期定时按剩余秒数继续倒计时；退出期间已过期的定时转入待确认队列（绝不在后台静默触发过期硬件操作），通过指令栏顶部横幅与 macOS 原生通知提供「立即执行」或「忽略」。
- **双端黄金语料 (`intent_golden.json`) 与 Windows 英文指令完整对齐**：新增跨平台共享测试语料 `Tests/Fixtures/intent_golden.json`，由 Swift Testing 与 Windows TypeScript 测试共同校验；Windows 端补齐词边界消费式英文解析（支持色温、空调模式、相对调温、自动风速、英文延时与撤销）。
- **隐私与米家云直连说明完善**：在 README 与登录设置页补充米家非官方客户端 API 的账号风控提示与官方 `xiaomi_home` 替代方案，并披露本地 `UserDefaults` 明文存储键名。

## 1.0.2

本次提供 macOS (`MenuBarMijia-1.0.2.dmg`) 与 Windows 安装包。

### 新增
- **应用内中英双语国际化 (`zh-Hans` / `en`)**：支持「跟随系统 / 简体中文 / English」实时切换（偏好设置与新手引导均可一键切换），全面覆盖主控制面板、设备磁贴、快捷场景、设置页、安全通知与系统权限弹窗。
- **英文语音识别与本机 0ms 英文指令解析**：英文界面下自动切换 `en-US` 语音识别，支持英文自然语言设备控制（如 `"turn on study light"`, `"study light moonlight mode"`, `"set living room ac to 24 degrees"`, `"dimmer"`）、英文延时指令（`"in 10 minutes turn off study light"`, `"cancel timer"`）与英文撤销（`"undo"`, `"revert"`）。
- **米家云端多地区服务器选择**：扫码登录支持切换中国大陆 (`cn`)、新加坡/国际 (`sg`)、欧洲 (`de`)、美区 (`us`)、俄罗斯 (`ru`) 节点。

## 1.0.1

本次提供 macOS (`MenuBarMijia-1.0.1.dmg`) 与 Windows 安装包。

### 修复
- 应用名称、安装包（`MenuBarMijia.app` / `MenuBarMijia-1.0.1.dmg`）与仓库名称统一为 `MenuBarMijia`。
- LG webOS 电视局域网直连默认关闭，移除内置的局域网 IP 与 MAC 地址默认值，改为由用户在设置中填写或局域网扫描。
- 未配置 AI 服务 API Key 时，默认地址保持为 OpenRouter (`https://openrouter.ai/api/v1`)，不再回退连接本机 `localhost:3425` 端口，并在触发复杂指令时直接提示配置 API Key（简单指令仍可 0ms 本地离线执行）。
- Home Assistant 支持独立实体的设备合成，补齐没有物理设备注册记录的灯、风扇、空调、插座等已支持类型。
- 按 Home Assistant 的标准设备类别识别温湿度计和普通开关，保留辅助开关设备的环境读数，避免实体名子串误伤有效插座。
- 初次连接等待区域、设备、实体注册表和状态全部就绪后发布列表，避免隐藏设备暂时出现；注册表权限或格式错误会显示连接错误。
- Windows 云端控制失败时显示错误并保留原状态；撤销按成功指令逆序恢复实际修改的属性和原始开关状态，失败后可重试。
- Windows 保留手动选择的数据源，避免已有小米登录信息覆盖该选择；同步设备时不再重叠请求。
- Windows 灯具详情显示设备支持的日光、月光等模式，点击后通过米家云切换，并支持撤销恢复原模式。

### 工程
- 固定 Windows 原生依赖版本；CI 在核心测试通过后生成安装包和 SHA-256 校验文件，发布时上传到对应版本。
- 增加 Windows 页面控制、模式切换及撤销回归测试，以及 HA 设备识别、初始返回顺序和注册表错误的 Swift Testing 用例。

## 1.0.0

### 新增
- 说「再暗一点」「调高两度」「温度低一点」可以微调；没说设备时只调正开着的。
- 风扇：「高档」「风速调低」「摇头」「停止摇头」。
- 定时：「10 分钟后关灯」「半小时后关空调」，指令栏里能看到倒计时并取消；也可以说「取消定时」。
- 语音撤销：说「撤销」能恢复 10 分钟内最近一次语音操作。
- 设置页「检查更新」，读取 GitHub Releases。
- 隐私：可以关掉习惯学习、逐条删除已记住的习惯、让语音只在本机识别；设置页写明哪些内容会发给 AI。

### 改进
- App 名称统一为 MenuBarMijia（登录信息和设置会保留）。
- AI 出错时说人话：超时、断网、密钥不对、请求太多、服务器出错分别提示。
- 默认家庭名改为「我的家」。

### 工程
- 版本号放在 `VERSION`；`scripts/release.sh` 一条命令完成签名、DMG、公证。
- GitHub Actions：macOS 上编译和测试，Linux 上跑核心测试。
- 核心库可以在 Linux 上编译测试（`scripts/linux-check/run.sh`）。
- `HomeStore.swift` 拆出 `HomeStore+Assistant.swift`。
