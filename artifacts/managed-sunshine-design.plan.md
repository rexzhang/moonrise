# Sunshine 受管下载整合 + UserDefaults 统一设置存储 + brew 移除 设计

## Context

现状三个独立痛点：

1. Sunshine 二进制来源依赖 brew 安装。本机 brew 版本停驻 2026.914，其 AVFoundation 捕获路径在 macOS 27.2.1 存在虚拟屏错绑（串屏）与捕获停滞（断连）缺陷（Plans/multi-display-spike.md S8）；上游自 v2026.1112 起（PR #5511）以 ScreenCaptureKit 重写捕获并修复。
2. 设置存储为 AppController 私有可变结构 + config.json 文件的散布式读写（十余处 read-modify-write + 手动 save），无单一写通道；Sunshine 受管化还需新增持久状态（版本选择）。
3. 官方 Sunshine.app 二进制带启动约束（裸拷贝离开 bundle 即 SIGKILL，S8），Qt 无 minimal 平台插件；同时上游提供 system_tray conf 键（本机实测 disabled 后托盘消失、串流正常）。

本设计：Sunshine 来源收敛为受管目录 + 用户手动从 GitHub Releases 获取；设置存储收敛为 UserDefaults 单源（ConfigStore）；brew 支持全部移除。

## 设计定案

### D1 Sunshine 来源与管理（ManagedSunshineStore）

1. 来源唯一：受管目录 `~/.config/moonrise/sunshine/Sunshine.app`（官方 release 整 bundle 拷贝）。brew 编排代码全部删除：BrewServicesSunshineManager 与探测函数、restartPolicy 配置字段、ChildProcessSunshineManager 的首启 brew services 迁移分支。家族外清杀（ppid 判定）保留。
2. 获取仅手动：下载/更新/重新获取均由用户在设置窗口 Sunshine 页触发；不自动下载、不自动检查更新、无轮询。
3. 版本选择：设置项 `sunshine.selectedVersion`（String，"latest" 默认跟随最新，或具体 tag 如 "v2026.1112.40957"）。「检查更新」按钮手动查询 releases/latest 并与 selectedVersion 语义比较（latest 比较已装版本与最新 release；钉住版本比较所选 tag）。
4. 芯片类型贯穿下载链路：资产按本机架构匹配（`name == "Sunshine-macOS-\(arch).dmg"`，arch ∈ {arm64, x86_64}，ProcessInfo.machine 映射）；release 缺本机架构资产时该版本视为不可获取（版本列表标注，不可发起下载）；下载前后均以本机架构资产为唯一目标，不出现跨架构落位。
5. 版本警示与最低支持版本：支持的最低版本为 v2026.1112（Sunshine 页固定说明）；选择或安装 < v2026.1112 的版本时展示警示条（S8：旧版捕获路径在 macOS 27 有串屏/停滞缺陷），不阻断；版本列表中低于最低支持版本的 release 标注「不支持」。
6. 安全校验：下载完成后校验 codesign TeamIdentifier == F8XQ7XCN2R（LizardByte Developer ID）且 CFBundleShortVersionString 与所请求 tag 的版本段一致；不符拒绝落位并清理 staging。
7. 换装流程：下载 → hdiutil 挂载提取 → 验签 → 停全部实例（串行）→ 原子换目录（旧目录改名遗留再删除，新目录就位）→ 按配置重建实例（实例副本按 SHA-256 对锚自动刷新，InstanceConf.ensureBinaryCopy 现有机制）→ 恢复串流。Sunshine 页全程显示阶段与进度。
8. 存量迁移：检测 legacy 形态（config.json 含 binaryPath 键，或 ~/.config/sunshine/ 存在 conf/credentials）→ Sunshine 页显示「沿用现有配置与凭据」提示条 + 获取入口。conf/凭据原地沿用（路径不变，无文件搬移），仅获取二进制。旧 JSON 的 binaryPath 键在 schema 演变后被解码器自然忽略。迁移不改变就绪判定：既有二进制（无论 brew 遗留还是 /Applications 手动安装）不视为已获取，获取成功前维持锁定态。
9. 就绪判定唯一来源：仅认经下载流程落位且落位时验签通过的受管副本（存在性判定，落位时已验签）。任何其它形态——brew 遗留二进制、手动安装于任意位置的官方 app、损坏/缺失的受管目录——一律视为未获取（等同首次获取，进入锁定态与引导流程）；运行中受管目录被破坏同样回落锁定态。
10. 主 conf 代建：~/.config/sunshine/sunshine.conf 缺失时由 MoonRise 代建（ConfFile createsIfMissing 语义扩展到主 conf，键取默认值），凭据预置沿用 provisionCredentialsIfNeeded（fdf6fa8 已覆盖首屏）。

### D2 未就绪锁定态

1. 启动解析按 D1.9 判定：ready / locked 两态。
2. locked 行为：不建屏、不启实例、不执行 conf 同步；菜单栏聚合行显示「Sunshine 未就绪」，每屏行禁用；屏幕管理页操作禁用（遮罩 + 说明 + 打开 Sunshine 页按钮）；权限页/诊断页正常可用，诊断页显示 Sunshine 状态行。
3. 启动引导：locked 时启动完成后自动打开设置窗口并定位 Sunshine 页（对齐权限引导模式，AppController 启动流程既有钩子）。

### D3 ConfigStore（UserDefaults 统一设置存储）

1. 持久化：UserDefaults 标准 suite 单键 "appConfig"，值为 AppConfig 的 JSON blob（原子写语义与现 config.json 一致）。AppConfig 值类型保留 Codable，解析容错与迁移读取逻辑不变。
2. ConfigStore：@Observable（Observation 框架），暴露只读快照与 mutate 单一写通道（改 → 存 → 变更通知）。AppController 的私有可变 config 移除，菜单/设置窗口/编排层全部读写经 store。
3. 迁移导入：首启检测 ~/.config/moonrise/config.json → 导入 blob → 原文件改名归档为 config.json.imported（不删除）。
4. schema 演变：新增 sunshine.selectedVersion；保留 autoConfigure（SunshineSync 功能开关）、configPath、disableAudioStreaming；删除 restartPolicy、hideTrayIcon、binaryPath。Package.swift 平台目标上调 .macOS(.v14)（@Observable 依赖）。
5. 边界不变：state.json（运行态事实）、SMAppService（系统自管）、Sunshine 实例凭据文件不进 store。操作键 "sunshine.migrationDone"（Bool）以独立 UserDefaults 键存放。

### D4 conf 键集与托盘

1. system_tray = disabled 加入主 conf 与全部实例 conf 的目标键集（上游 to_bool：仅 true/yes/enabled/on/含 "1" 为真，其余为假；v2026.1112.40957 src/config.cpp:1891）。托盘抑制与主线程事件循环跳转由上游原生支持（src/main.cpp:156-162）。
2. QT_QPA_PLATFORM 环境变量注入随 hideTrayIcon 字段删除一并移除。
3. AGENTS.md 键集表述同步（主 conf 四键 / 实例 conf 十键）。

### D5 GitHub 接口契约

1. 端点：GET https://api.github.com/repos/SunshineStream/Sunshine/releases/latest；GET /releases?per_page=20（版本选择列表）。免认证，限流 60 次/时/IP，仅手动触发。
2. 资产匹配（含芯片类型规则）：name == "Sunshine-macOS-\(arch).dmg"，arch ∈ {arm64, x86_64}（ProcessInfo.machine 映射）；release 缺本机架构资产 → 该版本不可获取（列表标注）；取 browser_download_url（URLSession 自动跟随跳转）。
3. 下载：URLSession downloadTask + 进度回调（字节/总量的进度条）；HTTP 403 限流时呈现限流提示（含重置时间），手动重试。
4. 提取链：hdiutil attach -nobrowse -readonly -mountpoint → cp -R bundle → 验签 → hdiutil detach（急切清理：任何步骤失败均 detach + 清 staging）。

### D6 界面（设置窗口 Sunshine 页）

独立 tab「Sunshine」，分区：状态区（版本徽标 / 来源路径 / 就绪状态 / 本机芯片架构标注）、版本选择区（固定说明行「支持的最低版本 v2026.1112」；selectedVersion：跟随最新 | 近 20 条正式 release 列表带发布日期与支持标注）、操作区（获取/更新 primary 按钮、重新获取、检查更新）、进度区（阶段文字 + 进度条 + 字节）、警示条（版本过旧）、迁移提示条（legacy 形态检测命中时）。锁定态下屏幕管理页顶部遮罩（说明 + 「打开 Sunshine 页」按钮）。菜单栏聚合行新增锁定态行。

## 分项任务

- R1 ConfigStore 统一存储：新建 ConfigStore（@Observable + UserDefaults 单键 blob + mutate 通道 + config.json 导入迁移）；AppController/设置窗口/菜单/编排层读写接线改造。依赖：无（先行）。
- R2 AppConfig schema 演变：selectedVersion 新增；restartPolicy/hideTrayIcon/binaryPath 删除；Package.swift 平台 .macOS(.v14)。与 R1 同批交付。
- R3 brew 移除：删 BrewServicesSunshineManager 与 brew 探测（SunshineProcess.swift 保留 SunshineManaging 协议）、删 ChildProcessSunshineManager 的 brew services 迁移分支；相关单测清理改写。依赖：R1。
- R4 conf 键集 system_tray：SunshineSync 主 conf 目标键集与 InstanceConf 实例目标键集扩展 + 主 conf 缺失代建；QT_QPA_PLATFORM 注入删除。依赖：R3。
- R5 ManagedSunshineStore：releases 拉取与解析（含架构资产匹配与不可获取标注）、下载进度、验签、挂载提取、原子换装、installedVersion 读取、staging 清理、最低支持版本常量。依赖：R1、R3。
- R6 未就绪锁定态与启动引导：启动解析（仅认受管副本）、锁定行为收敛、自动引导打开 Sunshine 页。依赖：R5。
- R7 设置窗口 Sunshine 页与菜单栏状态：页面分区与交互（版本选择含最低支持说明与不支持标注/下载/更新/重新获取/检查更新）、锁定遮罩、菜单栏锁定行。依赖：R5、R6。
- R8 文档修订：install（受管下载流程替代 brew 步骤）、architecture（来源唯一与 ConfigStore）、troubleshooting（锁定态/下载失败/迁移收编/最低版本）、AGENTS（键集四键/十键、项目一句话 brew 表述清理）、implementation-plan 与 multi-display-plan（brew 章节标注移除）、spike S8 增补 system_tray 实测结论。依赖：R1–R7 全部。

## 实施顺序

R1 + R2 → R3 → R4 → R5 → R6 → R7 → R8。

## 改动文件清单

- Package.swift：平台 .macOS(.v14)
- Sources/MoonRiseCore/Config/AppConfig.swift：schema 演变
- Sources/MoonRiseCore/Config/ConfigStore.swift：新建
- Sources/MoonRiseCore/Support/Paths.swift：受管目录与 staging 路径
- Sources/MoonRiseCore/Sunshine/ManagedSunshineStore.swift：新建（含最低支持版本常量）
- Sources/MoonRiseCore/Sunshine/SunshineProcess.swift：保留 SunshineManaging 协议与 SunshineInstallInfo，删 BrewServicesSunshineManager 与探测函数
- Sources/MoonRiseCore/Sunshine/ChildProcessSunshineManager.swift：删 brew 迁移分支与 hideTrayIcon/QT 注入
- Sources/MoonRiseCore/Sunshine/SunshineInstanceRegistry.swift：hideTrayIcon 参数删除
- Sources/MoonRiseCore/Sunshine/InstanceConf.swift：实例目标键集 + system_tray
- Sources/MoonRiseCore/Sunshine/SunshineSync.swift：主 conf 目标键集 + system_tray + 缺失代建
- Sources/MoonRiseCore/Sunshine/ConfFile.swift：主 conf createsIfMissing 扩展
- Sources/MoonRiseBar/AppController.swift：解析链重写（仅认受管副本）、锁定态、启动引导、mutate 接线
- Sources/MoonRiseBar/DisplayOrchestrator.swift：configProvider 改读 store 快照
- 设置窗口场景文件（Sunshine 页 + 锁定遮罩）与菜单（锁定行）
- Tests/MoonRiseCoreTests/：ConfigStoreTests 新建；InstanceConfTests/AppConfig 相关测试改写；brew 相关测试删除
- docs/install.md、docs/architecture.md、docs/troubleshooting.md、AGENTS.md、Plans/implementation-plan.md、Plans/multi-display-plan.md、Plans/multi-display-spike.md

## 验证

- swift build && swift test 全绿（测试数随删增更新）。
- 端到端手动：清空受管目录 → 启动 → 自动引导 → 手动获取（观察架构资产匹配、进度与验签）→ 就绪 → 建屏串流内容正确 → 更新换装（实例副本自动刷新、串流恢复）→ 迁移收编（本机现存 binaryPath 形态，获取前维持锁定态）。
- UI 行为按菜单栏每屏开关与设置窗口核对；改动视图用 XcodeBuildMCP 构建验证。

## 约定

文档/注释/提交信息中文，Conventional Commits（type 英文标准词）。UI 一律 SwiftUI，macOS 27 设计语言。绝不程序化修改虚拟屏模式/排列。实例启动/重启串行执行。外部 Sunshine 清杀按 ppid 归属判定。
