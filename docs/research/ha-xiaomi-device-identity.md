# 调研：Home Assistant 与小米/米家设备在「设备注册表」层的同一性（join key）与能力信号

调研日期：2026-10-31　状态：源码级结论，均标注一手来源；无法确认的显式标 `UNVERIFIED`
背景：MenuBarMijia 要把 HA 设备与米家云设备合成一张去重卡片，偏好能力更强的一侧。本文回答七个问题：注册表线格式、官方集成写入的标识符、其它小米集成路径、双端能力信号、稳定性、以及本地 `DeviceSynthesizer.swift` 的解码缺口。

所有引用格式：`文件:行号` + 链接（均为读取当日 2026-10-31 的对应分支/标签源码）。

---

## 0. 结论先行

1. **HA 侧设备注册表没有 REST 端点。** `GET /api/config/device_registry/list` 不存在——0.110→2026.10.4 的 `components/config/device_registry.py` 全程只有 WebSocket 命令 `config/device_registry/list`，官方 REST API 文档也只列 `/api/states` 与 `/api/services`。`identifiers` / `connections` **在**线格式里，形如 `[["xiaomi_home","cn_1234567"]]` 的二元组数组（元组序列化为数组）。
2. **官方集成把 `did` 编进了标识符，但不是裸值**：`('xiaomi_home', slugify(f'{cloud_server}_{did}'))`。MenuBarMijia 两端信息（server + did）都有，**可以用「构造候选标识符串再查表」的方式精确还原，不需要解析**。
3. **推荐 join key 优先级**（§8 详细论证）：
   ① MAC 连接（`connections` 含 `("mac", …)`）——但米家云侧是否给设备 MAC `UNVERIFIED`；
   ② `xiaomi_home` 标识符 → 由已知 server+did 构造候选串精确匹配；
   ③ `xiaomi_miot`（al-one）标识符值 = MAC 或裸 did，可与米家 did 直接比对；
   ④ `xiaomi_miio` / `xiaomi_aqara` / `xiaomi_ble` / `yeelight` 只认 MAC / sid / 蓝牙地址；
   ⑤ model+name+房间 启发式兜底。
4. **能力信号**：HA 侧「实体数（按 device_id）+ 每实体 `supported_features`（在 state attributes 里）+ `/api/services`」；小米侧「MIoT 规格的 services → 可写属性 + 动作数」。两侧计数**不可直接比大小**（HA 一个属性常映射成一个实体，传感器还会膨胀），可比的是逐字段映射后的可控制项集合。
5. **本地 DTO 缺口**：`HADeviceEntry` 需要新增 `identifiers` 与 `connections` 两个字段（线格式为 `[[String,String]]`）；其余字段（`config_entry_id`、`serial_number`、`via_device_id`…）可按需加，`JSONDecoder` 对多余键本就忽略，向后兼容。
6. **勘误**：任务描述给的 `github.com/XiaomiMi/ha_xiaomi_home` 是错的组织，官方仓库是 `XiaoMi/ha_xiaomi_home`（org `XiaoMi`，`main` 分支）。

---

## 1. 设备注册表线格式（WS `config/device_registry/list`）

注册与序列化都在 `homeassistant/helpers/device_registry.py`，WS 命令在 `homeassistant/components/config/device_registry.py`。

- 命令注册与处理器：`components/config/device_registry.py:24-37, 63-90`——`websocket_list_devices` 把每个 entry 的缓存 `json_repr` 拼成结果数组。
  https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/config/device_registry.py
- `DeviceEntry.dict_repr` 字段全集（`helpers/device_registry.py:591-629`）：
  `area_id, configuration_url, config_entries（2027.8 弃用）, config_entries_subentries, config_entry_id, config_subentry_id, connections, created_at, disabled_by, entry_type, hw_version, id, identifiers, labels, manufacturer, model, model_id, modified_at, name_by_user, name, next_name_part, parent_device_id, primary_config_entry（2027.10 弃用）, serial_number, sw_version, via_device_id`
  https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/helpers/device_registry.py#L591-L629
- 测试断言的完整响应样例（`tests/components/config/test_device_registry.py:60-104`）确认 `identifiers: [["bridgeid","0123"]]`、`connections: [["ethernet","12:34:56:78:90:AB:CD:EF"]]`——**set[tuple] 序列化为数组的数组，每项两元素 `[domain_or_type, value]`**。
  https://github.com/home-assistant/core/blob/2026.10.4/tests/components/config/test_device_registry.py#L60-L104
- 连接类型常量（`helpers/device_registry.py:87-90`）：`bluetooth` / `mac` / `upnp` / `zigbee`（另有 `ethernet` 见测试）。MAC 值入库时经 `format_mac` 归一化（`_normalize_connections`，:526-533）。
  https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/helpers/device_registry.py#L87-L90
- **REST 不存在**：该文件从 0.110.0 到 2026.10.4 都只注册 WS 命令、无 `HomeAssistantView`；官方 REST 文档只列 `/api/states`、`/api/services` 等。
  https://github.com/home-assistant/core/blob/0.110.0/homeassistant/components/config/device_registry.py 、
  https://github.com/home-assistant/developers.home-assistant/blob/master/docs/api/rest.md
- WS 响应不含 `suggested_area`（只在创建设备时用于落 area_id，:2503-2514），要房间名得配 `config/area_registry/list`。

## 2. 官方集成 `XiaoMi/ha_xiaomi_home` 怎么写设备

DOMAIN = `'xiaomi_home'`（`miot/const.py:51`）。
https://github.com/XiaoMi/ha_xiaomi_home/blob/main/custom_components/xiaomi_home/miot/const.py#L51

**device_info（每个实体上报，:360-372）：**

```python
DeviceInfo(
    identifiers={(DOMAIN, self.did_tag)},
    name=self._name,
    sw_version=self._fw_version,
    model=self._model,
    manufacturer=self._manufacturer,
    suggested_area=self._suggested_area,
    configuration_url='https://home.mi.com/webapp/content/baike/product/index.html?model=…')
```

https://github.com/XiaoMi/ha_xiaomi_home/blob/main/custom_components/xiaomi_home/miot/miot_device.py#L360-L372

关键点：

| 字段 | 写入内容 | 来源 |
| --- | --- | --- |
| `identifiers` | `('xiaomi_home', did_tag)`，其中 `did_tag = slugify(f'{cloud_server}_{did}', separator='_')` | `miot_device.py:380-383`；`miot/common.py:101-103` |
| `model` | MIoT 型号串原样，如 `zhimi.airp.rma3` | 云端 `/app/v2/home/device_list_page` 的 `model` 字段（`miot_cloud.py:576, 597`） |
| `manufacturer` | **`model.split('.')[0]`**（即 `zhimi`/`lumi` 这类前缀，不是「Xiaomi」） | `miot_cloud.py:614` |
| `connections` | **不写**。云端响应里的 `local_ip`/`bssid`/`ssid` 解析了（`miot_cloud.py:603-616`）但没进 DeviceInfo | `miot_device.py` 全文无 `connections` |
| `sw_version` | 云端 `extra.fw_version` | `miot_cloud.py:617` |

- `slugify_did`（`miot/common.py:101-103`）：`slugify(f'{cloud_server}_{did}', separator='_')`，server 为 `cn`/`de`/`us`/`ru`/`tw`/`sg` 等（`main` 分支 const；`unverified`：完整 server 代码表需对照集成设置项文档）。did 为纯数字时 slugify 无损，值形如 `cn_123456789`。
- **entity `unique_id` 内嵌 did_tag**：`gen_device_entity_id` / `gen_prop_entity_id` / `gen_event_entity_id` / `gen_action_entity_id` 生成 `xiaomi_home.<model[0][:9]>_<did_tag>_<…>_p_<siid>_<piid>` 之类的串（`miot_device.py:382-435`），实体 unique_id 直接用它（:991, :996, :1303, :1449, :1563）。因此**从任一实体的 unique_id 也能反查出 did_tag**。
- 一个 HA 设备 = 一个 `did`（split 子服务不出独立 HA 设备）；云端 `parent_id` 子设备也没有 `via_device` 关系。
- MIoT RPC 线级形状（`miot/miot_cloud.py:844-875`）：`/app/v2/miotspec/prop/set` 参数 `[{did,siid,piid,value}]`；`/app/v2/miotspec/prop/get`（:736-742）；`/app/v2/miotspec/action` 参数 `{did,siid,aiid,in:[…]}`。

## 3. 其它把同一物理设备带进 HA 的路径（合并需识别的标识符域）

| 集成 | 域 | identifier 值 | connections | manufacturer | model |
| --- | --- | --- | --- | --- | --- |
| `xiaomi_home`（XiaoMi 官方） | `xiaomi_home` | `slugify(cloud_server + '_' + did)` | 无 | `model[0]`（前缀） | MIoT 型号串 |
| `xiaomi_miot`（al-one/hass-xiaomi-miot） | `xiaomi_miot` | `format_mac(mac).lower()`；无 MAC 时退化为裸 `did` | 有 MAC 时写 `("mac", …)` | `model.split('.')[0]` 或 `'Xiaomi'` | MIoT 型号串 |
| `xiaomi_miio`（HA 内置，局域网） | `xiaomi_miio` | config entry `unique_id` = **格式化 MAC**（config_flow.py:178-191） | `("mac", mac)`（entity.py:59-60；网关另建 :440） | `"Xiaomi"` | miio info 的型号串（同 MIoT 型号） |
| `xiaomi_aqara`（HA 内置，YAML 网关） | `xiaomi_aqara` | 网关=其 MAC；子设备=`sid`（Zigbee 地址，**非 MIoT did**） | 网关 `("mac",…)`；子设备 `("zigbee", sid)` | `"Xiaomi Aqara"` | 网关型号 |
| `xiaomi_ble`（HA 内置，BLE） | `bluetooth` | BLE 地址 | `("bluetooth", address)` | — | — |
| `yeelight`（HA 内置） | `yeelight` | config entry `unique_id`（灯的 `id`，MAC 派生） | 无 | `"Yeelight"` | 灯型号（Yeelight 自有命名） |
| `xiaomi_tv`（HA 内置，YAML） | 无 | **完全没写 device_info**，不进注册表 | — | — | — |

来源：
- al-one：`core/device.py:73-76`（unique_id=MAC 或 did）、`:335-348`（identifiers/connections）、`:351-369`（hass_device_info）；
  https://github.com/al-one/hass-xiaomi-miot/blob/master/custom_components/xiaomi_miot/core/device.py
- xiaomi_miio：`entity.py:41,46-62`、`config_flow.py:164-192`、`__init__.py:436-448`；
  https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/xiaomi_miio/entity.py
- xiaomi_aqara：`entity.py:93-121`（device_id 取 `config_entry.unique_id` 或 `_sid`，`__init__.py:64-68`）；
  https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/xiaomi_aqara/entity.py
- xiaomi_ble：`__init__.py:54-60`（identifiers 用 `bluetooth` 域）；yeelight：`entity.py:16-29`；xiaomi_tv：`media_player.py`（无 DeviceInfo）。

**合并识别清单**：`xiaomi_home`、`xiaomi_miot`、`xiaomi_miio`、`xiaomi_aqara`、`bluetooth`、`yeelight` + 各类连接类型 `mac`/`zigbee`/`bluetooth`。历史上有过 `xiaomi`/`xiaomi_aqara` 网关旧域名与「identifiers 只认 sid」的旧条目，老库存里可能仍有 `('xiaomi', sid)` 残留——`[推断]`，不再有源码可指。

## 4. HA 侧能力信号（判定「哪边更强」）

| 信号 | 端点/命令 | 返回什么 | 备注 |
| --- | --- | --- | --- |
| 实体清单（按设备计数） | WS `config/entity_registry/list` | 每实体 `as_partial_dict`：`entity_id, device_id, platform, unique_id, disabled_by, entity_category, …`（**不含 supported_features**） | `entity_registry.py:369-402`（字段全集）；handler `config/entity_registry.py:39-67` |
| 单实体完整注册项 | WS `config/entity_registry/get` / `get_entries` | `extended_dict` = partial + `capabilities, device_class, original_device_class, original_icon, aliases`（仍无 supported_features） | `entity_registry.py:408-416`；`config/entity_registry.py:98-155` |
| 轻量展示清单 | WS `config/entity_registry/list_for_display` | 仅启用实体 | `developers.home-assistant/docs/api/websocket.md:625-642` |
| 状态与 `supported_features` | REST `GET /api/states(/<entity_id>)`；WS `get_states` / `subscribe_entities` | state + attributes；**`supported_features` 写进 state attributes**（`helpers/entity.py:1175-1176`），另有 `get_supported_features()` 帮手（:182-194） | REST 文档 `rest.md:412`；WS handler `websocket_api/commands.py:369,441` |
| 服务清单 | REST `GET /api/services`；WS `get_services` | 全部 domain → 服务定义 | `rest.md:202`；`commands.py:598` |
| 实体来源 | WS `entity/source` | `{entity_id: {"domain": <platform>}}` | `commands.py:853-869` |
| 设备↔实体归属 | 上面实体清单的 `device_id` 字段 + `config/device_registry/list` | — | 实体计数：`device_id == X` 且 `disabled_by == null` 的条数 |

推荐的可比能力集：对每个 HA 设备取「启用实体数 + 每实体 domain + state attributes 里的 `supported_features`」，与小米侧「MIoT 规格可写属性数 + 动作数」做**逐项映射后**比较（哪个可控制项只有一边有），而不是比原始计数。

## 5. 小米侧能力信号（MIoT Spec）

- 规格实例 JSON（`https://miot-spec.org/miot-spec-v2/instance?type=<urn>`，实测 `urn:miot-spec-v2:device:air-purifier:0000A007:zhimi-va2:2`，读取 2026-10-31）：顶层 `{type, description, services[]}`；service `{iid, type, description, properties[], actions[]}`；property `{iid, type, description, format, access:["read"|"write"|"notify"], "value-list":[{value,description}] | "value-range":[min,max,step]}`；action `{iid, type, description, in:[], out:[]}`。
- 实例总目录 `https://miot-spec.org/miot-spec-v2/instances?status=all`（本次实测 48,114 条）。
- 可比能力计数的定义：对某 `did` 的规格，`Σ services` 的 `access 含 "write"` 的属性数 + `Σ actions` 数（MenuBarMijia 现有 `MiotReader`/`requiredProps` 管道已按名解析规格，直接复用即可）。
- 控制线级形状：`prop/set [{did,siid,piid,value}]`、`prop/get [{did,siid,piid}]`、`action {did,siid,aiid,in:[]}`（§2 末，来自官方集成源码）。get_props 分块上限 100 属性/请求与 `docs/research/miot-unsupported-categories.md` §4.2 一致。

## 6. 稳定性：什么会让 join 断开

- **HA `device.id`**：创建时 `uuid_util.random_uuid_hex`（`device_registry.py:410`），持久化在 `.storage/core.device_registry`（STORAGE_KEY，:81, :1898）——重启不变。同一 config entry 内再创建按 `(connections, identifiers, config_entry_id)` 匹配已有 entry（`async_get_or_create`，:2465-2469）。
- **集成重装/删除重加**：设备被删除后进入 `deleted_devices`；重加集成时若 identifiers/connections 匹配会**恢复原 device id、area、name**（:2495-2510 的注释明确写了这条），另有按 domain 的孤儿恢复（:2499-2504）。所以 HA 侧 id 在「重装集成」后基本稳定。
- **会断开的情形**：
  1. 标识符方案变化→生成新 device entry（旧的成为孤儿）。`xiaomi_home` 的 did_tag 含 `cloud_server`，**换区登录会改变标识符**（推断自 `slugify_did` 实现；未找到官方迁移说明，`UNVERIFIED`）。
  2. `disabled_by`：值域 `config_entry/integration/user/device`（`device_registry.py:124-131`）。设备仍在注册表里，但实体禁用、state 变 unavailable——join 不会断，但「能力对比」要排除被禁实体。
  3. 用户在注册表里手动删除设备且未重加（若重加会走 deleted 恢复）。
  4. **设备在米家 App 里解绑重绑 → did 变化** → HA 侧生成全新设备 entry。did 的跨重绑稳定性没有官方文档背书：`UNVERIFIED`（官方集成把 did 当长期主键用于本地缓存与订阅，`miot_client.py` 全文以 did 为 key，但「重绑必变」无一手来源）。
  5. miio/al-one/yeelight 侧以 MAC 为键：设备换 WiFi 模组或 MAC 被随机化时键变（`UNVERIFIED`：随机化是否出现在此类设备）。

## 7. 本地解码缺口（`Sources/MijiaCore/DeviceSynthesizer.swift`）

现状：`HADeviceEntry`（:15-40）只解码 `id, area_id, name, name_by_user, manufacturer, model, disabled_by`；`HAEntityEntry`（:43-76）已有 `device_id, platform, entity_category, disabled_by, hidden_by`，够做按设备计数；`HAEntityState.attributes` 是 `[String: JSONValue]`（:78-91），`supported_features` 已能读。

为支持 join，`HADeviceEntry` 需要补的字段（按线格式字段名，全部可选解码即可兼容旧 fixture）：

| 线格式字段 | 类型（Swift 建模） | 用途 |
| --- | --- | --- |
| `identifiers` | `[[String]]`（每项 `[domain, value]`） | **必需**。join 主通道（§8 ②③） |
| `connections` | `[[String]]`（每项 `[type, value]`；`type=="mac"`） | **必需**。join 主通道（§8 ①） |
| `serial_number` | `String?` | 部分集成把 MAC 塞这里（`UNVERIFIED`——本次未逐集成核对），低成本顺手解 |
| `config_entry_id` / `config_entries` | `String?` / `[String]?` | 判「该设备来自哪个集成」，辅助识别表 |
| `entry_type` | `String?` | 排除 `service` 类虚拟设备 |
| `via_device_id` | `String?` | 识别网关子设备（aqara zigbee 子设备等） |
| `configuration_url` | `String?` | 含 `home.mi.com/...model=` 可反解 MIoT 型号 |

`HAEntityEntry` 无需改动即支持能力计数；若要拿「该实体属于哪个平台集成」更权威的来源，WS `entity/source` 需另行接入（现有 DTO 不覆盖）。

## 8. 推荐 join key（按可靠性排序）

1. **`connections` 里的 MAC**（`type=="mac"`，值已 format_mac 归一化）：覆盖 `xiaomi_miio`、`xiaomi_miot`（有 MAC 时）、`xiaomi_aqara` 网关。前提取决于米家云侧能否给出设备 MAC——`device_list_page` 响应里有 `local_ip`/`bssid`（bssid 是路由器的），设备自身 MAC 是否可得 `UNVERIFIED`。若云侧无 MAC，此键只对「HA 侧有 MAC + 米家侧能从其它途径（如局域网 ARP）拿到 MAC」时可用。
2. **`('xiaomi_home', slugify(f'{server}_{did}'))` 的构造匹配**：MenuBarMijia 登录米家时已知 `cloud_server`，对每个米家 `did` 构造候选串 `slugify(server + "_" + did)`，与 HA 设备 `identifiers` 查表。**确定性强、零解析歧义**，是官方集成路径下的首选。注意 slugify 行为：小写化 + 分隔符替换，did 为数字串时无损；`UNVERIFIED`：did 含字母时的 slugify 细节需按 `python-slugify` 语义复核。
3. **`('xiaomi_miot', …)` 裸 did 兜底**：al-one 在设备无 MAC 时 identifier 值就是裸 did，可与米家 did 直接比对。
4. **`xiaomi_home` 实体 unique_id 反查**：`xiaomi_home.<prefix>_<did_tag>_<suffix>_p_<siid>_<piid>`（§2），当设备 entry 被孤儿化但实体还在时可用，作二级兜底。
5. **`model` 串 + `manufacturer` 前缀 + name/房间** 启发式：仅在前四项全部失败时用于提示人工确认，不自动合并（同型号多实例会误合）。

另注意：HA 注册表本身会因 identifiers/connections 相同把多个 config entry 的设备**合并成一个 entry**（`config_entries` 数组变多元素）——这正是集成混装用户的常态，join 时应按 identifiers 并集匹配而不是按 config entry 数。

## 9. UNVERIFIED / 开放问题

1. 米家云 `/app/v2/home/device_list_page` 响应是否含设备自身 MAC（官方集成只解析了 `local_ip`，未解析 mac；MenuBarMijia 侧 `MiCloudClient` 的 DTO 需要实测确认）。
2. `cloud_server` 的完整代码表（`cn/de/us/ru/tw/sg/…`）与 slugify 对非数字 did 的确切行为——需对照 `ha_xiaomi_home` 设置项文档与 python-slugify 语义实测。
3. did 在米家 App 解绑重绑后是否必变（无官方文档，只有集成以 did 为主键的间接证据）。
4. `xiaomi_home` 换区登录后 did_tag 是否变化、旧 HA 设备是否孤儿化（推断成立但无迁移文档）。
5. 部分集成是否把 MAC 写进 `serial_number`（本次未逐个核对）。
6. 2026.10 新引入的 composite/child device（`ChildDeviceEntry`、`list_composite_splits`、`probatio` 校验）对旧版 HA（用户可能停在 2025.x）线格式的兼容窗口——`dict_repr` 的弃用字段（`config_entries`、`primary_config_entry`）计划 2027 年移除，本地 DTO 建模时只加不减即可同时兼容。
7. HA 侧实体计数与 MIoT 计数的**换算表**（哪些 HA domain 由哪个 MIoT 服务映射而来）需要拿 `ha_xiaomi_home` 的 `specv2entity.py` 实测映射规则，本文未展开。

---

## 来源清单（全部为 2026-10-31 读取的一手源码/文档）

- https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/helpers/device_registry.py
- https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/config/device_registry.py
- https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/helpers/entity_registry.py
- https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/config/entity_registry.py
- https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/helpers/entity.py
- https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/websocket_api/commands.py
- https://github.com/home-assistant/core/blob/2026.10.4/tests/components/config/test_device_registry.py
- https://github.com/home-assistant/core/blob/0.110.0/homeassistant/components/config/device_registry.py （REST 缺失的历史对照）
- https://github.com/home-assistant/developers.home-assistant/blob/master/docs/api/rest.md
- https://github.com/home-assistant/developers.home-assistant/blob/master/docs/api/websocket.md
- https://github.com/XiaoMi/ha_xiaomi_home/blob/main/custom_components/xiaomi_home/miot/miot_device.py
- https://github.com/XiaoMi/ha_xiaomi_home/blob/main/custom_components/xiaomi_home/miot/miot_cloud.py
- https://github.com/XiaoMi/ha_xiaomi_home/blob/main/custom_components/xiaomi_home/miot/common.py
- https://github.com/XiaoMi/ha_xiaomi_home/blob/main/custom_components/xiaomi_home/miot/const.py
- https://github.com/al-one/hass-xiaomi-miot/blob/master/custom_components/xiaomi_miot/core/device.py
- https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/xiaomi_miio/{entity.py,config_flow.py,__init__.py}
- https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/xiaomi_aqara/entity.py
- https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/xiaomi_ble/__init__.py
- https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/yeelight/entity.py
- https://github.com/home-assistant/core/blob/2026.10.4/homeassistant/components/xiaomi_tv/media_player.py
- https://miot-spec.org/miot-spec-v2/instance?type=urn:miot-spec-v2:device:air-purifier:0000A007:zhimi-va2:2
- https://miot-spec.org/miot-spec-v2/instances?status=all
