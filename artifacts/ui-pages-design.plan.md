# UI 页面信息归拢 + 窗口置顶 + 组织原则 设计

## Context

延续"一处一事"的信息归拢：Retina 指引为公共信息（不绑定具体屏幕），置于屏幕管理页最下方；编码器探测归诊断页；Sunshine 页健康检查整体整合到诊断页；诊断页按"先公共项、后按屏项"组织。Sunshine 页收敛为纯 Sunshine 程序管理域，信息区排版保持现状。确立全局组织原则：按屏幕组织信息时以屏幕为单位分组、内部以 slotID（id）为键、显示用屏幕名。窗口置顶：设置与全部子窗口弹出时必须置顶显示。

## 设计定案

### D1 诊断页（先公共项、后按屏项）

- 公共组：私有 API ｜ 屏幕捕获权限（MoonRise）｜ Sunshine 受管副本（就绪判定 + 受管 bundle 路径，自 Sunshine 页健康检查迁入）。
- 按屏组（以屏幕为单位，内部按 slotID 键控，组头 = 屏幕名）：每屏三行——虚拟屏（id + 规格 + 活动列表状态）｜ output_name 一致性（conf 路径 → displayID）｜ 编码器探测（日志 "Found H.264 encoder" 权威判定）。
- 删除：Retina 指引段、外接显示器清单段。页面尾部保留「重新检查」。

### D2 Sunshine 页健康检查移除（整合至 D1）

Sunshine 页不再有健康检查区；sunshineChecks 函数删除，行拆分进 D1 诊断结构。

### D3 Sunshine 页信息区（保持现有排版）

信息区维持现状排版与行集：可展开「详细信息」，行 = 受管 bundle 路径 ｜ 可执行文件路径 ｜ 主 conf 路径 ｜ 首屏端口族（47989（配对）· 47990（Web UI）· 48010（RTSP））｜ 主实例日志 ｜ 本机架构 ｜ 托盘（system_tray = disabled），逐行可复制（沿用 infoRow）。不引入逐屏分组。

### D4 Retina 指引（公共信息，置于窗口底部）

屏幕管理页最下方（窗口内容底部）新增「Retina 指引」公共信息块，措辞不绑定具体屏幕；排版按多条目约定换行（标题行 + 条目逐行）：

> Retina 指引（公共信息）
> Retina 清晰度取决于两项设置：
> ① 系统设置 → 显示器：选中 Moon 屏，分辨率选择逻辑分辨率（"看起来像" = 像素尺寸的一半）
> ② Moon 端 Moonlight：分辨率设为与该屏像素尺寸一致、全屏显示

ScreenCard 不再有 Retina 指引展开行。

### D5 窗口置顶（保持 Settings 场景，不转普通窗口）

打开即置顶 = raiseToFront（SettingsCoordinator）：转正激活（.regular + NSApp.activate）→ orderFrontRegardless → makeKeyAndOrderFront → 窗口层级短暂提升 .floating（对冲场景装配期的系统重排）；设置窗成为 key 或 1.2s 超时后恢复常态层级，期间 0.15s/0.45s 两次延迟重申置前；子窗（添加/修改/配对）前置时设置窗回常态层级，避免浮层压住子窗。三个入口（面板设置按钮 / 锁定引导 / 已可见再开）统一走该路径。

### D6 组织原则（入 AGENTS.md「语言」段 UI 约定）

按屏幕组织信息时以屏幕为单位分组，内部以 slotID 为键，显示用屏幕名。

## 分项任务

- R1 DiagnosticsWindow.swift：runChecks 重构（公共组 + 逐屏组：虚拟屏 / output_name 一致性 / 编码器探测；含受管副本行；删 Retina 指引与外接清单）；sunshineChecks 删除。依赖：无。
- R2 SettingsWindow.swift：SunshinePageView 删健康检查区（信息区排版保持现状）；ScreensPageView 底部公共 Retina 指引块；权限页指引多条目换行排版；按钮对齐修正（屏幕管理页添加按钮靠右、屏幕卡动作行靠右、诊断页重新检查居中或靠右、菜单面板操作行靠右）。依赖：无。
- R3 SettingsWindow.swift（SettingsCoordinator）：occlusion 登记处 orderFrontRegardless + makeKey。依赖：无。
- R4 AGENTS.md 组织原则一句；ui-refresh-plan.md 追加实施记录。依赖：R1–R3。

## 实施顺序

R1 → R2 → R3 → R4（R1/R2/R3 相互独立，可并行实施）。

## 改动文件清单

- Sources/MoonRiseBar/DiagnosticsWindow.swift（R1）
- Sources/MoonRiseBar/SettingsWindow.swift（R2/R3）
- AGENTS.md、Plans/ui-refresh-plan.md（R4）

## 验证

- swift build && swift test（78 全绿）。
- 手动逐页对照：诊断页先公共组后按屏组（每屏三行）、Sunshine 页仅程序管理域（信息区现状排版）、屏幕管理页底部公共 Retina 指引（措辞不绑屏）、其它 app 窗口置前时打开设置/添加/修改/配对窗口均出现在最上层。

## 实现说明

- 页面布局与 HTML 设计稿构件一一对应（SettingsGroupBox / infoRow / 胶囊徽章 / DisclosureGroup 均为现成构件）；诊断页检查输出从平铺改为"公共组 + 按屏组"两段（与 D1 一致）；Sunshine 页信息区排版保持现状，无新增派生。

## 约定

文档/注释/提交信息中文，Conventional Commits。UI 排版两条项目约定：① 叙述性文本含 1/2/3 多条目时换行排版（每条目独立一行，不内联拼接）；② 按钮布局左右居中或靠右，禁止左对齐。不主动提交，用户确认后提交。
