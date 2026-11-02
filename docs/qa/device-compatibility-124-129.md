# 米家云设备适配与功率单位

本轮处理 [#124](https://github.com/jryang1997/MenuBarMijia/issues/124)、[#125](https://github.com/jryang1997/MenuBarMijia/issues/125)、[#126](https://github.com/jryang1997/MenuBarMijia/issues/126)、[#127](https://github.com/jryang1997/MenuBarMijia/issues/127) 和 [#129](https://github.com/jryang1997/MenuBarMijia/issues/129)。规格读取日期为 2026-11-02，验证数据均为公开规格和模拟属性值。

| 型号 | 本轮能力 | 边界 |
| --- | --- | --- |
| `xiaomi.wifispeaker.l17a` | macOS 音量、扬声器静音、播放状态、睡眠开关、播放音乐、停止闹钟、播报文本、执行文本指令 | 沿用现有音箱控件；Windows 尚无音箱设备模型，本轮不增加 |
| `xiaomi.derh.13l` | 双端开关、智能/睡眠/干衣模式、环境温湿度 | 复用开关与模式控制模型；本轮未增加目标湿度和水箱故障控件 |
| `xiaomi.blanket.mj2` | 双端开关、25–55℃目标温度，按规格限制范围 | 复用温控模型；内部水温不进入室温读数；本轮未增加睡眠曲线和烘干模式 |
| `xiaomi.diffuser.xw002` | 双端整机开关 | 复用开关控制模型；不把氛围灯当整机；本轮未增加出香时长、间隔和灯光控件 |

新增适配按服务与属性名称匹配，不按这四个型号写死协议地址。同类设备必须提供对应的 MIoT 服务与属性，才能使用这些能力。音箱动作还须匹配规格中的输入属性顺序；文本指令不经过麦克风静音服务。除湿机和香氛机使用独立的指令分类，避免被“关闭所有风扇”和“关闭所有插座”误选；水暖毯归入取暖设备，不被“关闭所有空调”选中。

## 功率证据

公开规格 `chuangmi.plug.212a01` 的 `electric-power` 属性为 `uint32`，`unit` 是 `watt`，备注却是 `电功率(单位0.01w)`。此前直接展示原始值；现在优先使用明确的缩放说明，11904 对应 119.04 W。普通 W、kW、mW 也换算为 W，负数、非有限值和未知单位不显示为有效功率。数值大小和 `value-range` 的步长不作为缩放依据。

[#129 的截图](https://github.com/user-attachments/assets/79aa50a0-434a-4ffe-954b-d628eed44f4e) 显示 11904W，但没有型号和原始规格，因此不能确认报告中的插座正是这一型号或同一种缩放。该反馈仍需用户实机对照米家读数。

## 来源

设备规格来自 [MIoT 公开型号索引](https://miot-spec.org/miot-spec-v2/instances?status=released) 与实例接口，实例 `type` 记录在测试夹具中。`Tests/Fixtures/miot_golden.json` 保留三个生活设备的相关公开服务；`Tests/Fixtures/miot/xiaomi.wifispeaker.l17a.json` 保留音箱公开实例。夹具没有账户、设备 did 或凭据。

参考了 [MiHome-Windows 的规格驱动设备能力处理](https://github.com/huanyuejue/MiHome-Windows/tree/41adea43f6ca0771715d05ec7afedf5ab31dc99f/app) 和 [mijia-api 的音箱动作调用](https://github.com/Do1e/mijia-api/blob/2cc61f2e4ae21d9e3736e450c968bbe53c87ebd1/mijiaAPI/mcp_server.py)。本轮独立实现于项目现有 Swift 与 TypeScript 协议层，没有复制其源代码或引入新运行依赖。

## 验证

旧代码运行新增的黄金样本时，复现了 11904 原始值直接成为 11904W，以及三个生活设备缺失。修改后，双端对同一份夹具断言设备状态、轮询属性和写入地址；macOS 另验音箱控制、动作输入顺序和 provider 路由。

本机为 macOS 27.0.1，完整 `bash scripts/check.sh` 在 `SnapshotTests` 产生 32 个截图差异。临时还原全部生产源代码至基线 `5a77b9b` 后，单独运行 `swift test --filter SnapshotTests` 得到完全相同的 32 个差异，覆盖相同的 7 个测试名称。该既有差异不通过更新截图基准来掩盖；完整截图检查继续交给 CI 的固定 macOS 环境。

以上属于协议与本地回归验证，未向反馈者的真实设备发送命令，不能替代实机验收。
