# MoonRise 多扩展屏幕（1-N）设计

## Context

MoonRise 目前创建一块名为 "Moon" 的虚拟屏，由单个 Sunshine 子进程串流给一台 Moonlight 客户端。本设计支持 1-N 块虚拟扩展屏：每块屏独立分辨率/HiDPI 配置、独立可连的串流目标（moon 前缀 + 自编号）、多台 Moonlight 客户端同时各连一块屏；提供 Apple 设备分辨率预设与逐屏管理 UI。

用户决策：

1. 命名：统一自动命名（Moon 1、Moon 2…），允许用户改名。
2. 串流：多屏并发串流 + Moonlight 自动发现（自动发现实测受限，见定案 D6）。
3. UI：统一管理窗口承载全部管理操作（允许弹出式交互子窗口），菜单栏只做状态显示。
4. 逐屏开关：每个虚拟屏可单独启用/停用，应用记住上次的开关状态。
5. 名称对应：Sunshine 实例对外名称与 Moon 屏名一一对应（sunshine_name，实测有效）。
6. 连接可见：菜单栏展示每屏串流状态。
7. 无确认弹窗：后果提示置于控件文案；破坏性删除经统一应用提交，应用前可撤销。
8. 配对：接受逐实例 PIN 配对，App 提供配对辅助（spike S2 结论）。

Spike 实测结论（2026-11-10，详见 Plans/multi-display-spike.md）：双实例并发串流可行（双路 VideoToolbox ≥12 分钟稳定）；同一二进制路径的捕获串行化（第二个进程永久挂起）→ 实例必须独立二进制副本路径；共享 CA 免配对不成立 → 逐实例 PIN；自动发现被 Moonlight 客户端按 IP 去重 → 手动添加 IP:端口 为主路径；输入注入各归各屏；log_path 日志分流有效；遗留验证：MoonRise 归属下双子进程并发捕获（实现期必做）。

## 设计定案

- D1 架构：每屏绑定一个 Sunshine 实例。首屏绑定用户主 sunshine.conf（默认端口 47989，全局 output_name 钉屏），不可删除；第 2..N 屏各绑定 MoonRise 自有实例（实例目录 sunshine-instances/<槽位UUID>/：独立 conf、独立二进制副本 bin/sunshine、独立凭据、独立日志 + 显式 base port）。
- D2 命名：自动命名 Moon 1、Moon 2…（moon 前缀 + 自编号，跳过已用名）；用户可改任意唯一名（唯一性校验：名称不重 + 身份向量全集不撞），名称编辑旁静态警示"该屏位置与 Retina 记忆将重置"，应用直接执行，改名后销毁重建并同步更新该实例 sunshine_name。删屏编号留洞不重排；显示名与端口在创建时冻结进配置。
- D3 端口：实例 base port 从 48089 起步进 100，新屏分配时做端口占用探测，分配后冻结（客户端保存了 IP:端口）；停用后重新启用仍用冻结端口，若被其它程序占用则报错提示，不迁移端口。不设屏幕数量上限，端口耗尽报错。
- D4 凭据与配对：实例凭据完全自包含（独立 CA + 配对状态，落于实例目录）；配对为逐实例 PIN（客户端按主机条目各自建立配对，共享 CA 无免配对收益——spike S2）；管理窗口配对引导为主路径：展示 IP:端口 → 一键打开实例 Web UI PIN 页 → 用户输入 PIN；实例 Web UI 凭据首次设置引导（App 预置凭据为实现期备选，需确认 state 哈希格式）。
- D5 规格管理：HiDPI 按屏开关（关 = 只有 1:1 主模式）；改分辨率/HiDPI 一律销毁重建，且只重建目标屏（其它屏与其串流不受影响）。
- D6 发现与连接：自动发现对第 2..N 屏不可用（Moonlight 客户端按 IP 去重——spike S6 实测）；手动添加 IP:端口 为标准路径，管理窗口突出一键复制；sunshine_name 与屏名一一对应（连接后客户端显示该名——实测有效）；排列引导用「系统设置 → 显示器」deep link。
- D7 UI：统一管理窗口为唯一管理入口：屏卡片列表（状态、IP:端口 复制、打开 Web UI、重启该屏、名称编辑、分辨率/刷新率/HiDPI、启用开关、删除标记）+「添加屏幕」（预设面板子窗口：Apple 设备 / 通用 / 自定义…；选预设即创建；自定义表单含 HiDPI 以"添加"收尾）+ 单一「应用」按钮（脏标记驱动，只提交有改动的屏；含删除时文案标注"含删除 N 屏"）+ 配对引导 + 排列引导入口。菜单栏只做状态显示：状态聚合行（N 屏 · 串流 M · 实例 M/M）+ 每屏状态行（串流点 + 屏名 + 状态词，点击打开管理窗口并定位该屏）+ 全局 Sunshine 子菜单（状态 / 禁用音频串流 / 重启全部实例 / 重新同步）+ 权限引导… / 诊断… / 开机自启 / 退出；菜单栏图标维持"正常/异常"两态。
- D8 配置迁移：旧单屏配置读入时迁为数组首元素，显示名统一为 Moon 1（该屏记忆一次性重置，用户已接受），开关状态默认启用；keepHostScaling 迁为全局设置。
- D9 硬约束映射：私有 API shim 不动（MRC）；身份推导公式不变，多屏身份唯一性靠显示名唯一保证；绝不程序化改模式/排列；运行状态判定只用活动显示器列表 + displayID；ConfFile 行级编辑逐字节保留，"值变才重启"精确到实例；Sunshine 外部实例清杀必须排除 MoonRise 全家族子进程（按父进程判定，不按路径——同路径副本属正常形态）；TCC 责任进程 = MoonRise 不变。
- D10 逐屏开关：每屏一个启用开关（enabled），持久化于 config.json，重启后按上次状态恢复。停用 = 停该屏实例 + 销该屏 + 配置槽位保留（编号/名称/端口/规格冻结不变）；启用 = 按既有槽位重建建屏起实例。收敛只对已启用屏 diff；看门狗与回调不复活停用屏。首屏可停用不可删除，停用时主实例一并停止（防 output_name 指向不存在的屏而回退捕获 host 屏）。
- D11 名称对应：实例 conf 写 sunshine_name = 屏幕显示名（主 conf 同样写首屏名，所有屏一致对待），创建时冻结、随改名同步更新并只重启该实例；客户端连接后显示的主机名即屏名（spike 实测有效）。
- D12 串流可见：逐实例日志监控（log_path 按实例分流——spike 实测有效）判定串流中/空闲；菜单栏状态聚合行 + 每屏状态行标记（● 串流中 / ○ 空闲 / ○ 未启用 / ▲ 离线）。刷新机制 = 逐实例日志尾随（近实时、秒级）识别串流开始/结束 + 看门狗 30s 周期对账兜底；日志不可达按空闲显示并在诊断提示。
- D13 托管编排：首屏与第 2..N 屏实例一律由 MoonRise 子进程托管（受管目录来源，ManagedSunshineStore 获取）。
- D14 输入与音频：多客户端并发输入不限制（spike 实测各归各屏、无串扰）；音频串流保持全局开关，同一值写入主 conf 与全部实例 conf，不提供按屏音频开关。
- D15 操作语义：无确认对话框，后果提示置于控件文案（如"删除（将中断串流）"、改名旁静态警示）。新增屏选预设即创建（立即建屏起实例）；删除屏为标记式（卡片置灰标注"应用时删除"，可再点撤销），统一「应用」执行；配置类改动（名称/分辨率/刷新率/HiDPI/启用开关）一律走统一「应用」，只提交改动屏；运维动作（重启该屏 / 打开 Web UI / 复制 IP:端口）即时执行。删除屏时清理实例目录（含二进制副本与凭据）。
- D16 捕获路径序列化对策（spike S7）：同二进制路径的并发捕获被 macOS 27 串行化（第二进程永久挂起）→ 每实例独立二进制副本路径（见 D1），实例启动时校验副本与源二进制一致（源升级后跟随刷新）；实现期必做验证：MoonRise 归属下 spawn 两个不同路径副本并发捕获，若归属级序列化仍存在则架构回退评估（单实例 + 串流目标切换，需求降级）。

## 分项任务

### R1 Spike：多实例可行性实测（已完成）

结论见 Plans/multi-display-spike.md（S1–S7 全部有结论：双实例并发串流可行；同路径捕获串行化；免配对不成立；自动发现不可用；输入隔离正常；日志分流有效）。遗留一项转入 R3 验收：MoonRise 归属下双子进程并发捕获验证（D16）。

### R2 Core 多屏化（已完成，构建与 38 项单测全绿）

- 配置结构数组化：AppConfig.displays: [DisplayConfig]（槽位 UUID、持久编号、显示名、宽高、刷新率、HiDPI、启用开关、实例端口），旧格式迁移（D8：display 键只读迁为首元素 Moon 1，keepHostScaling 上移顶级，display 键不再写出）；DisplayConfig 提升为模块顶层类型。
- 虚拟屏控制器多槽化：realize(slotID:spec:) / teardown(slotID:) / teardownAll / displayID(of:)；HiDPI 传入建屏；带盐重试逐槽保留。
- diff 式收敛计划：DisplayReconcilePlan.plan（纯函数，create/remove/rebuild/keep；仅对 enabled 屏；端口变化不进 rebuild）。
- 边界判定：boundsAcceptable 在 hiDPI=false 时只接受 1:1 尺寸。
- 预设库：DisplayPresets（通用 4 + Apple 10，全部通过规格校验）。
- AppController 机械化适配（单屏行为不变）：primaryDisplay 驱动 reconcile/改分辨率；keepHostScaling 全局化；退出改 teardownAll。
- 测试：AppConfigTests（6）、DisplayReconcilePlanTests（9）、DisplayPresetsTests（3）新增；DisplaySpecTests +3（HiDPI 关=仅主模式/边界拒绝/旧 JSON 解码）；IdentityTests +1（Moon 1 vs Moon 2 serial 区分）。

### R3 Sunshine 多实例（已完成：Core 能力 + 56 项单测全绿；App 接线在 R4）

已落地：ConfFile createsIfMissing（实例 conf 代建）；InstanceConf（目录/键集/PortAllocator/bind 探测/二进制副本 SHA-256 校验刷新）；SunshineProcessDiscovery + ManagedProcessFamily（ppid 家族排除清杀）；ChildProcessSunshineManager 实例化（label、家族排除）；SunshineInstanceRegistry（懒建实例、二进制副本）；SunshineSync.syncInstance（逐实例 conf 同步，缺失代建）；StreamStateMonitor（日志尾随，标记行 spike 实测口径）。
实例串行启动/重启由编排层保证（R4）。
D16 验收 ✅ 通过（2026-11-10 真实 App 实测）：/Applications/MoonRise.app（MoonRiseDev 签名）同时托管主实例（brew 路径，Moon 1 2560×1600）与扩展屏实例（独立副本路径，Moon 2 2048×1536 iPad mini 4），两个子进程均归属 MoonRise 并各自通过编码器探测（双 "Found H.264 encoder"），端口 48089 独立监听，实例目录 UUID 与配置一致。

### R4 App/UI 多屏化（已完成，构建与 56 项单测全绿）

- DisplayOrchestrator（新）：diff 收敛（丢失槽自动重建、停用屏不复活）、单槽 create/rebuild/remove/suspend、逐实例 conf 同步（值变只重启该实例）、日志尾随串流监控接线；首屏停用/删除联动停主实例（D10）。
- AppController 重写：菜单只做状态显示（聚合行 + 每屏状态行点击定位窗口 + 全局 Sunshine 子菜单）；统一管理窗口接线（应用/增/删/改名校验/重启/Web UI/复制 IP:端口/排列引导）；看门狗逐槽收敛 + 逐实例保活 + monitor 对账 + 权限翻转重启全部实例；退出逐实例停止 + 全部销屏。
- ScreenManagerWindow（新）：屏卡片（状态/IP:端口 复制/Web UI/重启/名称+警示/规格/HiDPI/启用/删除标记式）+ 添加屏幕预设面板（Apple/通用/自定义）+ 单一「应用」（脏标记、含删除标注）+ 保持显示器缩放开关。
- ResolutionPanel 改造为自定义规格子窗口（含 HiDPI）；DiagnosticsWindow 逐屏检查（虚拟屏/output_name/Retina 指引）。
- 新增端口分配 + LAN IP 解析（复制 IP:端口）。

### R5 文档与规则修订（已完成）

- AGENTS.md：项目一句话多屏化；命名/模式数组/ConfFile 键集硬约束修订；新增多实例二进制路径独立、家族排除清杀两条硬约束；验证节更新（56 项单测）。
- Plans/implementation-plan.md 追加 M5（已完成，含 D16 遗留验收）；Plans/multi-display-plan.md（设计+实施记录合订）落库。
- README 多屏概述；docs/install.md 菜单/管理窗口/多屏使用（发现不可用、手动 IP:端口、逐实例 PIN）；docs/architecture.md 多屏架构图与设计要点；docs/troubleshooting.md 多屏类条目；docs/development.md 模块结构与测试描述更新。
- PermissionPanel 保持主实例定位（权限流程与主实例绑定，多实例重启入口在管理窗口/Sunshine 菜单）。

## 实施顺序

- R2 先行（R1 已完成）；R3 依赖 R2；R4 依赖 R2 + R3；R5 随各任务同步起草、收尾统一核对。
- 每任务完成即跑构建 + 全量单测 + 菜单栏诊断核对；R3 验收含归属级并发捕获验证（D16）。

## 改动文件清单（单仓库，按模块）

- MoonRiseCore/Config：AppConfig.swift（数组化 + 迁移）
- MoonRiseCore/VirtualDisplay：DisplaySpec.swift（HiDPI）、Controller.swift（多槽）、DisplayList.swift（边界判定）、DisplayReconcilePlan.swift（新）、DisplayPresets.swift（新）
- MoonRiseCore/Sunshine：ConfFile.swift（代建变体）、InstanceConf.swift（新：目录/键集/端口分配/二进制副本）、SunshineProcessDiscovery.swift（新）、ChildProcessSunshineManager.swift（实例化 + 串行启动）、SunshineInstanceRegistry.swift（新）、SunshineSync.swift（逐实例语义）、StreamStateMonitor.swift（新，日志尾随）
- MoonRiseCore/State：StateFile.swift（数组化）
- MoonRiseCore/Support：Paths.swift（实例目录）
- MoonRiseBar：AppController.swift（状态显示菜单 + 看门狗/回调多屏化）、DisplayOrchestrator.swift（新）、ScreenManagerWindow.swift（新，统一管理窗口 + 预设面板子窗口）、ResolutionPanel.swift（改造为自定义规格子窗口）、DiagnosticsWindow.swift（逐实例检查）、PermissionPanel.swift
- Tests/MoonRiseCoreTests：AppConfigTests（新）、DisplayReconcilePlanTests（新）、InstanceConfTests（新）、DisplayPresetsTests（新）、DisplaySpecTests/IdentityTests/ConfFileTests（扩展）
- 文档：AGENTS.md、Plans/、docs/、README.md

## 验证

- 每任务：swift build && swift test；菜单栏 → 诊断… 核对运行状态。
- R3 验收：双实例共存、双客户端并发串流 ≥10 分钟（spike 已验证同构场景）、逐实例日志分流、串行启动无互卡、MoonRise 归属双子进程并发捕获（D16）、displayID 漂移逐实例重写。
- R4 验收：菜单每屏状态行与实际一致且点击定位窗口、统一窗口应用流（多屏改动一次提交只重建改动屏、删除标记可撤销）、逐屏停用/启用往返、重启后开关状态保持、增删屏不打断其它屏串流、改分辨率只重建目标屏、改名记忆重置警示与 sunshine_name 同步、配对引导完整走通、旧配置升级迁移。
- 回归：单屏路径（首屏 + 主 conf）行为不变。

## 约定

- 文档/注释/提交信息中文；提交信息 Conventional Commits（type 英文、描述中文）；流程图 Mermaid；TODO 文件 TaskPaper 格式。
- 硬约束见 AGENTS.md 与设计定案 D9；涉及私有 API 一律运行时校验后调用；改分辨率一律销毁重建。
- 设计产物：本计划文件 + artifacts/multi-display-design.html（HTML 设计文档，流程图为主体）；实现后仅按文档核对，不回写过程叙述。


## 追加：扩展屏幕管理界面重构 + PIN 配对窗口（2026-11-10，已完成）

- W1 改名「扩展屏幕管理」，信息列表化：状态胶囊徽章（方案 A 四态配色）、IP:端口 复制、启用开关/重启/Web UI/配对/修改/删除（首屏删除禁用）；行内动作失败就地错误行。
- W2「屏幕修改窗口」（修改/添加双模式）：分组预设下拉（MacBook 5 / iPad 6 / Apple 显示器 3 / 通用 4，含 HiDPI 标记）+ 名称编辑；无删除（在 W1）；应用即校验重建/创建。
- W3「配对窗口」：实例 Web 凭据自动预置（/api/password，空凭据期无鉴权），轮询待配对设备，PIN 提交直连 /api/pin；首屏为 Web UI 引导形态。
- 全部 SwiftUI（NSHostingController 承载，系统默认控件风格）；ResolutionPanel 删除；PermissionPanel/DiagnosticsWindow 迁移记入 TODO。
- 预设清单按屏幕参数归纳去重（MacBook 5 / iPad 6 / Apple 显示器 3 / 通用 4，含 iPad mini 4 2048×1536、MacBook Air 15 2880×1864、4K UHD 等新增），来源与去重原则见实施记录 R2。

