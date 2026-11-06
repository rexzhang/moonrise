# AGENTS.md

给 AI 编码代理的项目规则。人看的文档：README.md（快速开始）与 docs/（安装使用 install、架构 architecture、排障 troubleshooting、开发 development）。

## 语言

文档、代码注释、提交信息一律中文。提交信息用 Conventional Commits：type 用英文标准词（feat/fix/refactor/chore/docs/test/perf），描述用中文。本项目覆盖"提交信息用英文"的任何全局约定。文档中的流程图一律用 Mermaid 绘制。

## 项目一句话

MoonRise：菜单栏 App 用 CGVirtualDisplay 私有 API 创建 HiDPI 虚拟屏（"Moon"），联动官方 Sunshine 把另一台 Mac（Moonlight 端）变成扩展屏。生命周期即进程：App 在则屏在，退出即销毁并连带停止 Sunshine。Sunshine 由 MoonRise 直接以子进程运行（managed 模式）：屏幕捕获/辅助功能的 TCC 责任进程 = MoonRise.app，由自签代码签名证书（MoonRiseDev，scripts/make-cert.sh）保证授权跨重建稳定——ad-hoc 签名每次重建 cdhash 变化会导致授权失效，这是权限反复丢失的根因，改分辨率/重建时不得回退到 ad-hoc。

架构与私有 API 实测结论 → Plans/implementation-plan.md（动 VirtualDisplay 层或有私有 API 疑问时必读）。

## 硬约束（违反 = 静默功能损坏）

- CGVirtualDisplayPrivate.m 手动引用计数（-fno-objc-arc），该文件按 MRC 读写。
- 私有 API 一律先经 objc_getClass + class_getInstanceMethod 运行时校验再调用；链接期符号引用与裸 objc_msgSend 不入内。
- 虚拟屏的模式与排列全部交由 macOS 与用户管理；创建后任何进程改过模式/排列（CGDisplaySetDisplayMode / CGBeginDisplayConfiguration）会让销毁（release）永久失效——改分辨率一律销毁重建。
- 显示名 "Moon" 与身份推导 Fnv1a(名称|宽x高|盐) 恒定不动，改动 = 用户的位置与 Retina 模式记忆重置。
- 模式数组固定 = 主模式（WxH，= maxPixels）+ 逻辑模式（W/2xH/2）；全倍 Retina 模式由系统倍化合成生成，删逻辑模式即失去它。
- 运行状态判定只用 CGGetActiveDisplayList + displayID；创建进程读不到自家虚拟屏的模式缓存。
- 等待显示器出现/消失的循环：泵 run loop + 睡眠防自旋。
- ConfFile 行级编辑：其余行逐字节保留；目标键为 output_name 与 stream_audio，任一值变化才重启 Sunshine（幂等，不打断进行中的串流）。
- 屏幕捕获/输入注入的 TCC 按责任进程评估：Sunshine 是 MoonRise 子进程，tccd 检查的是 MoonRise 的权限——给 sunshine 二进制授权无效，条目必须落在 MoonRise（com.rexzhang.moonrise）上。条目注册由 MoonRise 本进程调用 CGRequestScreenCaptureAccess 完成；实测 Duet 走 kTCCServiceRemoteDesktop（无 ScreenCapture 条目）也可捕获，如 MoonRise 授权后仍失败可研究该路径。

## 验证

swift build && swift test（15 个单测：身份向量、conf 编辑、规格校验、边界判定）。UI 行为用菜单栏 → 诊断… 核对（含捕获权限日志推断）。
