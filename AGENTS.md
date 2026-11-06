# AGENTS.md

给 AI 编码代理的项目规则。人看的安装与使用文档在 README.md。

## 语言

文档、代码注释、提交信息一律中文。提交信息用 Conventional Commits：type 用英文标准词（feat/fix/refactor/chore/docs/test/perf），描述用中文。本项目覆盖"提交信息用英文"的任何全局约定。

## 项目一句话

Moonrise：菜单栏 App 用 CGVirtualDisplay 私有 API 创建 HiDPI 虚拟屏，联动官方 Sunshine 把另一台 Mac（Moonlight 端）变成扩展屏。生命周期即进程：App 在则屏在，退出即销毁。

架构与私有 API 实测结论 → Plans/implementation-plan.md（动 VirtualDisplay 层或有私有 API 疑问时必读）。

## 硬约束（违反 = 静默功能损坏）

- CGVirtualDisplayPrivate.m 手动引用计数（-fno-objc-arc），该文件按 MRC 读写。
- 私有 API 一律先经 objc_getClass + class_getInstanceMethod 运行时校验再调用；链接期符号引用与裸 objc_msgSend 不入内。
- 虚拟屏的模式与排列全部交由 macOS 与用户管理；创建后任何进程改过模式/排列（CGDisplaySetDisplayMode / CGBeginDisplayConfiguration）会让销毁（release）永久失效——改分辨率一律销毁重建。
- 显示名 "Sunshine Ext" 与身份推导 Fnv1a(名称|宽x高|盐) 恒定不动，改动 = 用户的位置与 Retina 模式记忆重置。
- 模式数组固定 = 主模式（WxH，= maxPixels）+ 逻辑模式（W/2xH/2）；全倍 Retina 模式由系统倍化合成生成，删逻辑模式即失去它。
- 运行状态判定只用 CGGetActiveDisplayList + displayID；创建进程读不到自家虚拟屏的模式缓存。
- 等待显示器出现/消失的循环：泵 run loop + 睡眠防自旋。
- ConfFile 行级编辑：其余行逐字节保留；output_name 值变化才重启 Sunshine（幂等，不打断进行中的串流）。

## 验证

swift build && swift test（15 个单测：身份向量、conf 编辑、规格校验、边界判定）。UI 行为用菜单栏 → 诊断… 核对（含捕获权限日志推断）。
