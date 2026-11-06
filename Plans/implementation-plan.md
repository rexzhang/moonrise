# moonrise 实现计划

用 Sunshine + Moonlight 把另一台 Mac（ext）变成 host 的扩展屏，充分利用 ext 的 Retina 面板。

## 背景

- host：MacBook Air M4，macOS 27.0.1。需要一块分辨率可设置的虚拟屏幕。
- ext：MacBook Pro Retina 13" Early 2015（Broadwell，无 HEVC 硬解），原生 2560×1600，默认逻辑 1280×800（恰好 2x 整数），macOS Monterey 12，运行 Moonlight。
- 本仓库：菜单栏 App（Moonrise，Swift/AppKit）+ 官方 Sunshine（brew，不改源码）。无 CLI。
- 音频不处理：host 音频在本机播放；ext 端 Moonlight 音量调 0。

## 已定决策

- 生命周期即进程：App 启动建屏、退出销毁（无确认）。无 enabled 配置项。
- 默认 2560×1600 HiDPI@60；分辨率可配置（菜单预设 + 自定义小窗：W、H、刷新率 30/60/75/120；HiDPI 恒开）。
- 虚拟屏名 "Sunshine Ext"，App 名 Moonrise.app（名字进入身份推导，定后不改）。
- 开机自启默认关（SMAppService，菜单勾选）。
- 虚拟屏位置不做程序控制：首次在系统设置手动拖放，macOS 按稳定身份记忆。
- 单屏 UI，Controller 留多屏余地；仅自用 ad-hoc 签名；Duet 保留但禁用其虚拟屏。
- M0 若私有 API 失效：停下汇报（含 BetterDisplay 底层选项），由用户决定。

## 技术结论（含 M0 实测）

1. 虚拟屏：CoreGraphics 私有 ObjC 类 CGVirtualDisplayDescriptor / CGVirtualDisplay / CGVirtualDisplaySettings / CGVirtualDisplayMode（dyld 共享缓存，无 kext / 无 TCC 权限）。发消息前必须 objc_getClass + class_getInstanceMethod 全量校验（20 个 selector）。
2. M0 实测（macOS 27.0.1）：私有 API 完全可用；创建→销毁周期正常（销毁 ~0.34s）。
3. HiDPI 合成规则（实测）：setHiDPI:1 时系统为每个已声明/标准模式合成 2x 变体（受 maxPixels 上限约束）。要得到全倍 Retina 模式（如逻辑 1280×800 @ 像素 2560×1600），必须同时声明主模式（2560×1600，= maxPixels、身份依据）与逻辑模式（1280×800）。用户在系统设置选一次逻辑模式，macOS 按身份记忆。
4. 身份：vendor 0x7365("se") / product 0x6578("ex") / serial = FNV-1a("名称|宽x高|盐") 非 0；跨重启稳定，位置/模式记忆随之保留。每个身份在 /Library/ColorSync/Profiles/Displays 留一个 root 属主 ICC 文件（文档化，不清理）。
5. 生命周期陷阱：创建后任何进程改过该屏模式/排列（CGDisplaySetDisplayMode / CGBeginDisplayConfiguration），release 不再销毁 → 本工具绝不改模式、绝不程序化排列；改分辨率一律销毁重建。创建进程读不到自家虚拟屏的模式缓存 → 状态判断只用 CGGetActiveDisplayList + displayID。
6. 进程退出（含 SIGKILL）即屏失（WindowServer 回收）→ 菜单栏 App 常驻即持有。
7. 不装 setTerminationHandler:（退出期回调崩溃风险）；run loop 必须持续运转（AppKit 跑过的进程里，显示器只在 loop 运转时激活）。
8. Sunshine：AVCaptureScreenInput 按 CGDirectDisplayID 捕获；配置键 output_name（十进制 ID，空=主屏），配置文件 ~/.config/sunshine/sunshine.conf；成功日志 "Configuring selected display (<id>) to stream"。捕获按客户端请求分辨率 aspect 缩放 → 虚拟屏宽高比必须与串流分辨率一致。brew：tap lizardbyte/homebrew，裸二进制 $(brew --prefix)/bin/sunshine，服务标签 homebrew.mxcl.sunshine；权限：屏幕录制 + 辅助功能。音频 tap 非破坏性（CATapUnmuted，host 本地照常出声）。
9. Moonlight（ext）：自定义分辨率 2560×1600@60 H.264（Broadwell 无 HEVC 硬解）、码率 60 Mbps、全屏；显示设置保持 Default（恰好 2x）→ 1:1 像素映射全保真。已知 v6.0.0 macOS 自定义分辨率黑边回归（#1301）→ 实测，失败回退预设 + 菜单同步改比例。

## 项目结构

```
Package.swift            # swift-tools 5.9, [.macOS(.v13)]，无外部依赖
README.md                # 中文指南
Plans/implementation-plan.md
scripts/install-app.sh   # 生成 /Applications/Moonrise.app（LSUIElement, ad-hoc 签名）
Sources/
  VirtualDisplayObjC/    # ObjC target（MRC, -fno-objc-arc）：私有类重声明 + 运行时校验 + 安全类型化 API
  MoonriseCore/          # Swift 库：DisplaySpec/Identity/Controller（realize/teardown）、AppConfig、StateFile、ConfFile、SunshineProcess、Fnv1a、Paths
  MoonriseBar/           # 菜单栏 App：main / AppController / ResolutionPanel / DiagnosticsWindow
Tests/MoonriseCoreTests/
```

菜单：状态首行（displayID/分辨率/Sunshine 同步）、重新开始、分辨率（预设 2560×1600、1920×1200、2560×1440、1920×1080 + 自定义…）、Sunshine（重新同步 output_name / 重启 / 打开 Web UI）、开机自启、退出。

## 私有 API 调用序列（实测可行）

Descriptor: alloc/init → setName:(NSString) → setMaxPixelsWide:/setMaxPixelsHigh:(uint32) → setSizeInMillimeters:(CGSize 值传递) → setVendorID:/setProductID:/setSerialNum:(uint32) → setQueue:(串行 queue，不装 setTerminationHandler:)。
Display: alloc/initWithDescriptor:（nil = 无 GUI 会话）。
Settings: alloc/init → setModes:(NSMutableArray) → setHiDPI:(uint32 0/1，非 BOOL) → display.applySettings:（NO = 拒绝）。
displayID → 轮询活动列表（25ms/5s/泵 run loop）。
销毁：release 恰好一次 → 轮询消失（~0.34s）。
模式数组：[WxH@Hz 主模式, W/2xH/2@Hz 逻辑模式]（HiDPI 全倍模式由此生成）。

## 实现要点

- 配置 ~/.config/moonrise/config.json（Codable，原子写）：display{name,width,height,refreshRate} + sunshine{autoConfigure,configPath,restartPolicy=brewServices|launchctl|manual}。
- Sunshine 联动：行级编辑 sunshine.conf 的 output_name（其余行逐字节保留，.bak 单份备份）；仅值变化时按 restartPolicy 重启（brew services restart sunshine → launchctl kickstart -k gui/$UID/homebrew.mxcl.sunshine → 打印指引）；值相同不动（不打断串流）。每次 realize 后自动同步。
- 状态/错误一律呈现为菜单状态而非崩溃；CGDisplayRegisterReconfigurationCallback + 30s 看门狗兜底。
- AppController：启动 → 配置 → 可用性检查（失败→菜单错误状态+弹窗）→ 建屏 → Sunshine 联动 → state.json → 回调+看门狗 → RunLoop。

## 里程碑

- M0 私有 API 验证：✅ 完成（含全倍 Retina 模式合成规则、销毁时序、身份稳定性；验证器已移除）。
- M1 核心库：shim（selector 表校验）、spec/identity/controller、配置+state、单测。
- M2 菜单栏 App：状态图标、重新开始、分辨率菜单+自定义窗、开机自启、退出 + install-app.sh。
- M3 Sunshine 自动联动：ConfFile/SunshineProcess/App 同步 + Sunshine 子菜单。
- M4 端到端 + 打磨：ext 配对、Moonlight 设置、验证清单全绿、诊断窗口、中文 README。

## 验证清单（最终出口）

- host：诊断全绿；系统设置显示 Sunshine Ext（逻辑模式选中后 Retina）；拖窗可用；sunshine.conf 有 output_name=<id>；Sunshine 日志有 Configuring selected display。
- ext：全屏文字与原生同样锐利；指针/键盘双向；ext 无声而 host 音频正常；30 分钟无断流。
- 循环：重新开始 ≤5s 自动重同步；改分辨率无黑边；退出 ≤2s 屏消失；快速重启 ×10 恰好一块屏；重启 host 后开 App 即恢复。

## 风险与对策（摘要）

| 风险 | 对策 |
|---|---|
| macOS 更新移除私有 API | 运行时 selector 全量校验 → 菜单错误状态点名缺失项，不崩溃 |
| 改过模式/排列后销毁失效 | 绝不改模式、绝不程序化排列；只销毁重建；带盐身份重试 |
| displayID 漂移 | 每次 realize 后自动重写 output_name；回调+看门狗 |
| Moonlight v6 自定义分辨率黑边 | 实测；回退预设 + 同步改比例 |
| 非整数缩放发糊 | ext 固定 Default（恰好 2x） |
| Sunshine TCC 摩擦 | brew pin；必要时 .app 包装 |
| Duet 混淆 | 禁用其虚拟屏；诊断警告 |
| HEVC 无硬解 | 默认 H.264 |
| host 音频受影响 | tap 非破坏性；ext 端音量 0 |
