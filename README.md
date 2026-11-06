# MoonRise

<p align="center"><img src="assets/brand/logo/moonrise-icon-256.png" width="128" alt="MoonRise"></p>

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-1B2A4A)](https://github.com/rexzhang/moonrise)
[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://github.com/rexzhang/moonrise)
[![License](https://img.shields.io/badge/license-MPL--2.0-2E7D32)](https://github.com/rexzhang/moonrise)

仓库：https://github.com/rexzhang/moonrise

把另一台 Mac（Moon）变成本机（host）的扩展屏，充分利用 Moon 的 Retina 面板（1:1 像素映射）。

MoonRise 在 host 上创建一块 HiDPI 虚拟屏幕（默认 2560×1600@60，可改分辨率），自动联动官方 Sunshine 捕获串流；Moon 端 Moonlight 全屏显示，文字与原生同样锐利。Sunshine 由本 App 以子进程独占托管（退出连带停止），权限引导面板自动化完成授权。

## Clone 后快速开始

前提：brew 已安装；Moon 端另需 moonlight-qt（见 docs/install.md）。

```bash
# 1. 安装 Sunshine（一次性）
brew tap lizardbyte/homebrew
brew install lizardbyte/homebrew/sunshine
# brew pin sunshine   # 可选：锁定版本；不 pin 也可，升级后重启 Sunshine 自动跟随新版

# 2. 生成自签签名证书（一次性，弹框点"始终信任"）
bash scripts/make-cert.sh --trust

# 3. 编译、签名并安装
bash scripts/install-app.sh

# 4. 启动
open /Applications/MoonRise.app
```

启动后：权限引导面板自动弹出 → 按指引允许「屏幕捕获」与「输入控制」两项授权（授权对象是 MoonRise）→ 面板全绿即就绪。

系统设置 → 显示器：选中 "Moon" 把分辨率改为 1280×800（“看起来像”），并在同一界面把它的排列位置拖到主屏旁——分辨率与位置要一起调整，macOS 会把两者都记住，此后每次启动自动恢复。

Moon 端：moonlight-qt 连接本机 → PIN 配对 → 分辨率 2560×1600 / 60fps / H.264 / 60 Mbps / 全屏，音量 0。详细步骤见 docs/install.md。

## 文档

| 文档 | 内容 |
|---|---|
| docs/install.md | host 与 Moon 端完整安装、菜单功能、网络要求 |
| docs/architecture.md | 架构图、设计原理、权限机制、私有 API 调用序列 |
| docs/troubleshooting.md | 权限、显示、进程三类常见问题 |
| docs/development.md | 构建、测试、模块结构、签名阶梯、约束 |
| Plans/implementation-plan.md | 设计决策与实测结论记录（中文） |
| AGENTS.md | AI 编码代理的项目规则 |
