# 开发

## 常用命令

```bash
swift build                   # 构建
swift test                    # 单测（78 项：身份向量、conf 编辑、规格校验、边界判定、配置迁移、收敛计划、预设、实例键集/端口/副本、家族判定、串流标记状态机、主 conf 键集、ConfigStore 存取与迁移、版本比较与最低支持判定）
bash scripts/install-app.sh   # 签名并安装为 /Applications/MoonRise.app
bash scripts/make-cert.sh --trust   # 一次性：生成自签代码签名证书（弹框点"始终信任"）
```

### App 图标更新

改 logo 后运行：

```bash
.venv/bin/python scripts/logo_process.py <新logo源图.png>   # 抠图裁剪合成，重出 masters + iconset
bash scripts/install-app.sh
```

可选 macOS 26+ 新格式（IconComposer 导出的 .icon，系统直出、无系统托盘白圈）：

1. IconComposer 打开 `assets/brand/logo/moonrise-fg-1044x865.png`（透明双屏前景图层）
2. 背景设纯色 `#101318`，导出为 `assets/brand/MoonRise.icon`
3. 重新运行 `bash scripts/install-app.sh`（脚本检测到 .icon 会自动装入 bundle）

## 模块结构

- Sources/VirtualDisplayObjC：CGVirtualDisplay 私有 API 薄封装（CGVirtualDisplayPrivate.m 手动引用计数 -fno-objc-arc；运行时类/selector 全量校验，缺失时点名报错，不崩溃）
- Sources/MoonRiseCore：核心库
  - VirtualDisplay/：规格与校验（DisplaySpec）、预设库（DisplayPresets）、多槽控制器（Controller）、收敛计划（DisplayReconcilePlan）、活动显示器列表（DisplayList）、捕获权限检测（CapturePermission）
  - Sunshine/：ConfFile（行级编辑）、InstanceConf（实例 conf 键集与端口族）、SunshineSync（主 conf 同步）、ChildProcessSunshineManager（子进程托管）、SunshineProcessDiscovery（进程归属判定）、SunshineInstanceRegistry（实例登记）、ManagedSunshineStore（受管下载与验签）、InstanceWebAPI（实例 Web UI API 通道）、StreamStateMonitor（日志尾随判定串流状态）
  - Config/：AppConfig（配置模型与迁移）+ ConfigStore（@Observable，UserDefaults 单键存储）
  - State/：StateFile（运行态落盘，只写不读）
  - Display/：HostDisplayModeKeeper（host 缩放基线保持）
  - Support/：Fnv1a、Log、Paths
- Sources/MoonRiseBar：菜单栏 App（MoonRiseApp @main 场景定义、AppController 相位与编排、DisplayOrchestrator 建屏与收敛执行、SettingsWindow 设置五页 + 修改/添加视图、PairingWindow、ScreenEditWindow、DiagnosticsWindow 诊断检查模型、BrandGlyph、ListContentHeightKey）
- Tests/MoonRiseCoreTests：核心库单测
- AGENTS.md：AI 编码代理的项目规则（硬约束清单，改动 VirtualDisplay 层前必读）
- Plans/implementation-plan.md：设计决策与实测结论记录；Plans/multi-display-spike.md：多屏与多实例实测报告

## 架构与原理

MoonRise 在 host（本机 Mac）上用 CoreGraphics 私有 API 创建 HiDPI 虚拟屏幕（多扩展屏：Moon 1…Moon N），每屏绑定一个 Sunshine 实例串流；远程 Moonlight 端全屏显示，Retina 面板 1:1 像素映射。

### 总体架构

```mermaid
flowchart LR
    subgraph host["host（Mac）"]
        app["MoonRise.app<br/>（菜单栏：状态 + 每屏开关；设置窗口：通用/屏幕管理/Sunshine/权限/诊断）"]
        s1["虚拟屏 Moon 1<br/>2560×1600 HiDPI@60"]
        s2["虚拟屏 Moon N<br/>（逐屏规格）"]
        main["Sunshine 主实例<br/>（首屏，受管源）"]
        inst["Sunshine 实例 ×N<br/>（独立 conf/二进制副本/凭据/端口）"]
        app -->|"CGVirtualDisplay 按槽位建屏/销毁"| s1
        app --> s2
        app -->|"主 conf：output_name / stream_audio / sunshine_name"| main
        app -->|"实例 conf：+ port / log_path / 凭据"| inst
        s1 -->|"捕获 → VideoToolbox 硬件编码"| main
        s2 -->|"捕获 → 独立实例编码"| inst
    end
    main -->|"H.264 · 端口族 47989"| c1["Moonlight 客户端 A"]
    inst -->|"H.264 · 端口族 48089 步进 100"| c2["Moonlight 客户端 B…"]
```

- 首屏（Moon 1）绑定用户主 sunshine.conf（默认端口 47989），行为与单屏一致，不可删除；第 2..N 屏各绑定 MoonRise 自有 Sunshine 实例（~/.config/moonrise/sunshine-instances/<uuid>/：conf + bin/ 整 bundle 可执行副本 + credentials/ 独立 CA + 日志）。
- 二进制副本独立路径是 macOS 27 的硬要求：同一路径的并发捕获被系统串行化（第二进程永久挂起，spike S7 实测）。
- 副本形态（spike S8）：受管源与实例副本均为官方 .app 整 bundle 拷贝（bin/<源 bundle 名>/）——官方二进制带启动约束，裸拷贝在 bundle 外 exec 即被 SIGKILL。新鲜度以可执行文件 SHA-256 对锚，源升级后刷新。
- 变更经 diff 收敛（DisplayReconcilePlan）：只重建改动屏，保留屏的串流不中断；实例启动/重启串行执行。

### 设计要点

- 生命周期即进程：App 启动按上次开关状态逐屏建屏，退出销毁全部并连带停止全部实例。
- 逐屏规格：名称（自动 Moon N 跳过已用名，可改唯一名）、宽高、刷新率、HiDPI 逐屏配置；名称与端口创建时冻结（改名 = 身份变化 = 记忆重置 + 重建）；删屏编号留洞。
- HiDPI 实现原理：声明主模式（W×H）+ 逻辑模式（W/2×H/2），macOS HiDPI 倍化合成生成全倍 Retina 模式；HiDPI 关闭时只有主模式。
- 身份稳定：vendor/product/serial 由（名称+像素尺寸）FNV-1a 推导（vendor 0x6D6F "mo"、product 0x6F6E "on"，连读 moon），跨重启不变；多屏身份唯一性靠显示名唯一保证。
- 逐屏开关：enabled 持久化，停用 = 停实例+销屏、槽位冻结属性保留；收敛只对已启用屏 diff，停用屏不被守护复活。
- 实例对外名称：实例 conf 的 sunshine_name = 屏幕显示名（主 conf 同样写首屏名），客户端连接后主机名即屏名。
- 音频不处理：全局「禁用音频串流」写主 conf 与全部实例 conf；host 本地照常出声。
- Sunshine 来源与托管：来源唯一 = 受管目录（~/.config/moonrise/sunshine/Sunshine.app，ManagedSunshineStore 手动获取——官方 GitHub release、本机架构资产、验签 LizardByte TeamID F8XQ7XCN2R、原子换装；支持的最低版本 v2026.1112，其 ScreenCaptureKit 捕获修复了 macOS 27 的 AVFoundation 错绑与停滞，spike S8）。未获取 = 锁定态：不建屏/不启实例/不同步 conf，菜单与屏幕管理页引导设置窗口 Sunshine 页。全部实例均为子进程独占托管（退出连带停止，异常退避重启，孤儿接管）；托盘抑制走 conf 键 system_tray = disabled（上游原生，全实例生效）。
- 设置存储：ConfigStore（@Observable，UserDefaults 单键 "appConfig" JSON blob）为全部设置的单一来源；所有修改经 store.mutate 收口（改 → 持久化 → 通知）；旧 config.json 首启自动导入并归档 .imported。state.json 是运行态事实不是设置，不经 ConfigStore。
- 外部实例清杀按进程归属判定（ppid + 托管家族集合），绝不按二进制路径——扩展屏副本与源同内容属正常形态。
- 串流状态：逐实例日志尾随（log_path 分流）识别会话开始/结束，菜单栏每屏一行显示开关图标与状态词（串流中 / 空闲 / 未启用 / 离线）；看门狗 30s 对账兜底。
- 客户端发现：Moonlight 按 IP 去重，自动发现只认首实例——扩展屏以手动添加 IP:端口 为主路径（本机 IP 集中显示在设置屏幕管理页顶部）；逐实例 PIN 配对（共享 CA 不免配对，spike S2 实测）。

### 配对与凭据持久化

每个 Sunshine 实例（含首屏）独立配对、独立凭据。端口族以实例冻结端口 base 为基准（首屏 base=47989，扩展屏 48089 起步进 100 取首个空闲）：

- base：nvhttp 明文 HTTP——Moonlight 配对舞步（/pair）走这里
- base−5：nvhttp HTTPS——配对后的所有客户端请求在此做 TLS 客户端证书校验
- base+1：Web UI（confighttp）——MoonRise 配对窗口的 API 通道
- base+21：RTSP——串流会话

配对时序（PIN 窗口路径）：

```mermaid
sequenceDiagram
    participant c as Moonlight 客户端
    participant s as Sunshine 实例（nvhttp）
    participant w as confighttp（Web UI）
    participant m as MoonRise 配对窗口

    c->>s: GET /pair?phrase=getservercert（base 明文）
    Note over s: 建会话（uniqueid 为键），响应扣住等 PIN
    m->>w: GET /api/pin 轮询（2s）
    w-->>m: 待配对设备列表
    m->>w: POST /api/pin（pairing_id + PIN + name）
    w->>s: PIN 派生密钥，放行扣住的 getservercert 响应
    c->>s: clientchallenge → serverchallengeresp → clientpairingsecret
    Note over s: 哈希/签名校验 → add_authorized_client（内存 + file_state 落盘）
    w-->>m: {"status": 最终结果}（阻塞到舞步结束，最长 30s）
    c->>s: 后续请求走 base−5 HTTPS，逐握手校验客户端证书
```

机制要点：

- POST /api/pin 是阻塞语义：返回的 status 即最终配对结果；配对成功与失败都会移除会话——"会话消失"不能作为成功判据，权威判定 = 响应 status 或 GET /api/clients/list。
- GET /api/pin 只列 phase=NONE 的会话；会话 5 分钟过期；/unpair 端点已从 nvhttp 移除（客户端发 /unpair 落 404，无副作用）。
- 同一证书在 named_devices 存多条时，Sunshine 判歧义直接拒绝（出示正确证书也过不了）——配对状态正常落盘后不会积累。
- 实例 conf 的 file_state（配对状态）与 credentials_file（Web UI 凭据存储）都指向实例 credentials/state.json；缺 file_state 会落到全局默认路径（~/.config/sunshine/sunshine_state.json），与主实例互相污染。credentials_file 缺省取 file_state 值。
- state.json 双用途：顶层 username/salt/password 是 Web UI 凭据哈希（confighttp 启动读取），root 是配对状态（nvhttp 写回时保留顶层字段）。清掉顶层字段 = Web 凭据归零、全部 /api 请求 302 回 /welcome。
- Web 凭据预置：实例创建后凭据为空，MoonRise 调 POST /api/password 写入随机凭据并存 credentials/webui.json（0600）；配对窗口开窗时从磁盘加载，重置凭据后需重开窗口。首屏凭据归用户，MoonRise 不接管（配对走 Web UI 引导）。
- 客户端证书不一致：客户端在配对舞步里上交的证书必须与它后续 TLS 握手出示的证书一致，否则服务端拒绝（"Client certificate identity is not enabled"）。旧版 moonlight-iOS 存在两者不一致的缺陷——重装客户端可解（钥匙串身份随重装重新生成）。

### 权限机制（macOS 27 实测）

MoonRise 需要两项权限，授权对象都是 MoonRise 自身（com.rexzhang.moonrise）：

- 屏幕捕获（kTCCServiceScreenCapture）：Sunshine 以子进程运行，macOS 按责任进程（responsible process）向 MoonRise 收权限——给 sunshine 二进制单独授权无效。
- 输入控制（辅助功能，AXIsProcessTrusted）：Moon 端键鼠控制需要。

机制要点：

- TCC 条目注册必须由 MoonRise 本进程调用官方 API（CGRequestScreenCaptureAccess / AXIsProcessTrustedWithOptions）完成：子进程触发的检查只弹窗、不写系统设置条目。
- 授权持久化依赖稳定签名：ad-hoc 签名每次重建 cdhash 变化，tccd 拒绝持久化授权 → 必须用 MoonRiseDev 自签证书（或 Developer ID）签名。
- 实测参考：Duet（com.kairos.duetMac）走 kTCCServiceRemoteDesktop（无 ScreenCapture 条目）也可捕获；MoonRise 授权后若仍有问题可研究该路径。

### 私有 API 调用序列

虚拟屏使用 CoreGraphics 私有 ObjC 类（CGVirtualDisplayDescriptor / CGVirtualDisplay / CGVirtualDisplaySettings / CGVirtualDisplayMode，dyld 共享缓存内，无需 kext 与 TCC 权限）：Descriptor 逐 setter 构建（名称/最大像素/物理尺寸/身份/queue，不装 terminationHandler），Display 以 Descriptor 初始化后经 Settings 应用模式数组与 HiDPI 标记，销毁 = release 恰好一次后轮询活动列表消失（~0.3s）。发消息前必须 objc_getClass + class_getInstanceMethod 全量校验，缺失时点名报错、不崩溃。

完整调用链与实测结论见 Plans/implementation-plan.md。

## 签名阶梯

install-app.sh 自动按优先级选择签名身份：Developer ID（付费开发者账号，最耐久且可分发）> MoonRiseDev 自签（本机稳定，免费）> ad-hoc（仅临时，TCC 授权不持久）。

- 生成 MoonRiseDev：bash scripts/make-cert.sh --trust（一次性机器配置）
- 证书/私钥在登录钥匙串，证书副本在 ~/.config/moonrise/certs/
- 切换到 Developer ID 后：TCC 授权锚点变化，需要重新授权一次；此后随 TeamID 稳定

## 约束与注意

- 私有 API 调用纪律、MRC、销毁语义、身份恒定、conf 键集等硬约束见 AGENTS.md——违反会造成静默功能损坏。
- 依赖 CoreGraphics 私有 API（macOS 更新可能失效；App 以菜单错误状态点名缺失项，不会崩溃）。
- 虚拟屏位置不做程序控制（避免“改排列后无法销毁”陷阱），首次手动拖放后由 macOS 记忆。
- 分辨率变更 = 销毁重建（约 1–2s），期间该屏上的窗口会暂时回到主屏。
