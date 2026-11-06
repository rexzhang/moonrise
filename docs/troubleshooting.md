# 排障

先打开菜单 → 权限引导… 与 诊断…：多数问题的状态会直接呈现在这两个面板里。

## 权限类

- Sunshine 报无权限 / 编码器探测失败：权限引导面板会实时显示 MoonRise 的屏幕捕获与输入控制状态；完成授权后点「重启 Sunshine」重跑编码器探测（授权翻转时也会自动重启）。
- 系统设置列表里看不到 MoonRise 条目：点面板「请求屏幕捕获授权」后在弹窗里点「允许」（不要只点“打开系统设置”）；仍不行就手动添加 /Applications/MoonRise.app。
- 每次重建后权限失效：说明安装时用了 ad-hoc 签名——运行 bash scripts/make-cert.sh --trust 后重新 install-app.sh（签名阶梯见 docs/development.md）。
- 键鼠在 Moon 端不动：输入控制（辅助功能）权限未授予 MoonRise，面板一键请求后即可。

## 显示类

- Moonlight 全屏有黑边：虚拟屏宽高比必须与串流分辨率一致。改分辨率请用本 App 菜单同步改（如 Moonlight 退到 2560×1440 预设，则菜单也选 2560×1440）。
- Retina 发糊：确认 Moon 显示设置是“默认为此显示器”（2x 整数缩放）；虚拟屏选中了逻辑模式（如 1280×800）。
- 改分辨率后没有全倍 Retina：自定义分辨率需为偶数尺寸（逻辑模式 = 一半尺寸）；改完在系统设置重新选一次逻辑模式。
- 改分辨率/逻辑模式后位置变了：改分辨率会重置排列，回系统设置 → 显示器的排列视图把 Moon 拖回主屏旁即可，macOS 会记住新组合。

## 进程类

- 两个 Sunshine 冲突：Sunshine 由 MoonRise 以子进程独占托管（首次启动自动解除 brew services 注册）；不要手动另起实例。
- MoonRise 退出后屏消失、Sunshine 停止：设计如此（生命周期即进程）；重新打开即恢复。
- /Library/ColorSync/Profiles/Displays 里的 ICC 文件：每个虚拟屏身份一个，属主 root，属正常副作用，不要手删。
