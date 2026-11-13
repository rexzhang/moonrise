# AGENTS.md

给 AI 编码代理的项目规则。人看的文档：README.md（快速开始）与 docs/（安装使用 install、架构 architecture、排障 troubleshooting、开发 development）。

## 语言

文档、代码注释、提交信息一律中文。提交信息用 Conventional Commits：type 用英文标准词（feat/fix/refactor/chore/docs/test/perf），描述用中文。本项目覆盖"提交信息用英文"的任何全局约定。文档中的流程图一律用 Mermaid 绘制。UI 一律 SwiftUI（整个 app 统一 macOS 27 设计语言：系统默认控件 + 当前推荐 API/样式，不做自定义皮肤；菜单栏为 MenuBarExtra(.window) 玻璃面板，窗口全部由 SwiftUI 场景承载（Settings / WindowGroup / Window）；AppKit 仅限白名单：生命周期桥（NSApplicationDelegateAdaptor）、SettingsCoordinator 窗口协调、BrandGlyph NSImage、NSPasteboard/NSWorkspace/SMAppService 工具。一切 NSMenu/NSWindow/NSStatusItem 操作禁止在主线程外执行——后台线程 AppKit 窗口布局会触发 CoreAutoLayout 断言直接 abort（2026-11-13 崩溃实测）。

## 项目一句话

MoonRise：菜单栏 App 用 CGVirtualDisplay 私有 API 创建 HiDPI 虚拟屏（Moon 1…Moon N，多扩展屏），每屏绑定一个 Sunshine 实例（首屏绑用户主 sunshine.conf，扩展屏实例由 MoonRise 托管、独立 conf/二进制副本/凭据/端口），联动 Moonlight 端把另一台 Mac 变成扩展屏；多台客户端可同时各连一块屏。生命周期即进程：App 在则屏在，退出即销毁并连带停止全部 Sunshine 实例。Sunshine 来源唯一 = 受管目录（用户在设置窗口手动从 GitHub Releases 获取，ManagedSunshineStore 下载→验签→换装；未获取 = 锁定态，屏幕功能整体禁用）。屏幕捕获/辅助功能的 TCC 责任进程 = MoonRise.app，由自签代码签名证书（MoonRiseDev，scripts/make-cert.sh）保证授权跨重建稳定——ad-hoc 签名每次重建 cdhash 变化会导致授权失效，这是权限反复丢失的根因，改分辨率/重建时不得回退到 ad-hoc。

架构与私有 API 实测结论 → Plans/implementation-plan.md（动 VirtualDisplay 层或有私有 API 疑问时必读）；多屏与多实例实测结论 → Plans/multi-display-spike.md（动 Sunshine 集成层时必读）。

## 硬约束（违反 = 静默功能损坏）

- CGVirtualDisplayPrivate.m 手动引用计数（-fno-objc-arc），该文件按 MRC 读写。
- 私有 API 一律先经 objc_getClass + class_getInstanceMethod 运行时校验再调用；链接期符号引用与裸 objc_msgSend 不入内。
- 虚拟屏的模式与排列全部交由 macOS 与用户管理；创建后任何进程改过模式/排列（CGDisplaySetDisplayMode / CGBeginDisplayConfiguration）会让销毁（release）永久失效——改分辨率一律销毁重建。
- 命名与身份：身份推导 Fnv1a(名称|宽x高|盐) 公式恒定不动；自动命名 Moon N 跳过已用名，显示名与端口创建时冻结进配置，改名 = 该屏身份变化 = 位置与 Retina 记忆重置（须唯一性校验后销毁重建）；删屏编号留洞不重排；多屏身份唯一性靠显示名唯一保证。
- 模式数组：主模式（WxH，= maxPixels）恒有；HiDPI 开启时附逻辑模式（W/2xH/2，全倍 Retina 由系统倍化合成生成，删逻辑模式即失去它）；HiDPI 关闭时只有主模式。
- 运行状态判定只用 CGGetActiveDisplayList + displayID；创建进程读不到自家虚拟屏的模式缓存。
- 等待显示器出现/消失的循环：泵 run loop + 睡眠防自旋。
- ConfFile 行级编辑：其余行逐字节保留，值变才重启且精确到实例（幂等，不打断进行中的串流）。键集两套——主 conf：output_name / stream_audio / sunshine_name / system_tray（缺失时 MoonRise 代建）；实例 conf：另加 port / log_path / pkey / cert / credentials_file（Web UI 凭据存储）/ file_state（配对状态，缺它则落到全局默认路径造成跨实例污染）。system_tray 恒写 disabled（上游原生托盘抑制键，v2026.1112 起可用）。credentials/state.json 双用途：顶层 username/salt/password 是 Web UI 凭据哈希（confighttp 读），root 是配对状态（nvhttp 读写，写回时保留顶层字段）——清理或预写该文件必须保留顶层字段，弄丢 = Web 凭据归零、全部 /api 请求 302 回 /welcome（App 表现为永远 0 个待配对设备）。
- 设置存储单一来源 = ConfigStore（@Observable，UserDefaults 单键 "appConfig" JSON blob）；全部设置修改经 store.mutate 收口；旧 config.json 首启自动导入并归档 .imported。Sunshine 二进制来源唯一 = 受管目录（~/.config/moonrise/sunshine/Sunshine.app，ManagedSunshineStore 手动获取：官方 release → 本机架构资产 → 验签 TeamID F8XQ7XCN2R → 原子换装）；获取仅手动触发；未获取 = 锁定态（不建屏/不启实例/不同步 conf，功能整体禁用并引导设置窗口 Sunshine 页）。
- 多实例捕获按二进制路径串行化（macOS 27 实测：同路径第二进程进入捕获永久挂起）→ 每实例必须独立二进制副本路径（与源不一致时刷新）；实例的启动/重启必须串行执行。
- 副本形态（spike S8）：受管源与实例副本均为官方 .app 整 bundle 拷贝——官方二进制带启动约束，裸拷贝在 bundle 外 exec 即被 SIGKILL（秒退循环 code=9）。托盘抑制走 conf 键 system_tray = disabled（上游原生），不得用 QT_QPA_PLATFORM=minimal（官方包 Qt 无 minimal 平台插件，注入即启动崩溃）。
- 外部 Sunshine 实例清杀按进程归属判定（ppid == MoonRise 或在托管家族集合内的一律放过），绝不按二进制路径判定——扩展屏副本与源同内容属正常形态。
- 屏幕捕获/输入注入的 TCC 按责任进程评估：Sunshine 是 MoonRise 子进程，tccd 检查的是 MoonRise 的权限——给 sunshine 二进制授权无效，条目必须落在 MoonRise（com.rexzhang.moonrise）上。条目注册由 MoonRise 本进程调用 CGRequestScreenCaptureAccess 完成；实测 Duet 走 kTCCServiceRemoteDesktop（无 ScreenCapture 条目）也可捕获，如 MoonRise 授权后仍失败可研究该路径。

## 验证

swift build && swift test（78 个单测：身份向量、conf 编辑、规格校验、边界判定、配置迁移、收敛计划、预设、实例键集/端口/副本（裸二进制与整 bundle 两形态）、家族判定、串流标记状态机、主 conf 键集、ConfigStore 存取与迁移、版本比较与最低支持判定）。UI 行为用菜单栏每屏开关、设置窗口（通用 / 屏幕管理 / Sunshine / 权限 / 诊断页）核对（含捕获权限日志推断）。

构建与错误处理：改动视图（SwiftUI）后用 XcodeBuildMCP 工具触发构建验证；编译失败时先读编译诊断、只修诊断指向的问题，再排查其它文件。
