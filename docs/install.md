# 安装与使用

## host 端（本机 Mac）

环境：macOS 13+，Apple Silicon（实测 macOS 27）。

1. 如安装了 Duet Display：先禁用其虚拟屏（iPad 等其他用途不受影响）。
2. 安装 Sunshine 并锁定版本：
   ```bash
   brew tap lizardbyte/homebrew
   brew install lizardbyte/homebrew/sunshine
   brew pin sunshine   # 避免自动升级打断
   ```
3. Clone 本仓库后，构建并安装（详见 docs/development.md）：
   ```bash
   bash scripts/make-cert.sh --trust   # 一次性：生成自签证书（弹框点"始终信任"）
   bash scripts/install-app.sh         # 签名 + 生成 /Applications/MoonRise.app
   open /Applications/MoonRise.app
   ```
4. 首次启动会自动弹出权限引导面板：按指引完成「屏幕捕获」与「输入控制」两项授权（授权对象是 MoonRise，Sunshine 以子进程运行按责任进程收权限；给 sunshine 二进制单独授权无效）。
5. 浏览器打开 https://localhost:47990 创建 Sunshine 账号。
6. 开启 Retina（关键）：系统设置 → 显示器 → 选中 "Moon" → 分辨率选 1280×800（“看起来像”），并在同一界面的排列视图中把它拖到主屏旁。分辨率与排列位置要一起调整（改分辨率后排列常会移位），macOS 把两者都按身份记住，此后自动生效。

## Moon 端（远程 Mac）

1. 安装 moonlight-qt（最新版支持 macOS 11+）。
2. 显示设置保持“默认为此显示器”（1280×800，恰好 2x 整数缩放——像素级清晰的必要条件）。
3. 连接 host（同一局域网，建议 5GHz Wi-Fi 或有线），输入 PIN 配对。
4. 视频设置：分辨率 2560×1600、帧率 60、编码 H.264（Broadwell 无 HEVC 硬解）、码率 60 Mbps、全屏；音量 0。
5. 全屏后，屏幕文字应与原生一样锐利（同页 PDF 对比检验）。

## 菜单功能

- 状态行：分辨率 · displayID · Sunshine 同步状态
- 重新开始虚拟屏：销毁 + 重建 + 自动重新同步（约 1–2s）
- 分辨率：预设（2560×1600 / 1920×1200 / 2560×1440 / 1920×1080）+ 自定义（W、H、刷新率 30/60/75/120）
- Sunshine：运行状态行 / 重新同步 output_name / 禁用音频串流（默认勾选）/ 重启 Sunshine / 打开 Web UI
- 权限引导…：屏幕捕获与输入控制的实时监控、一键请求、分步指引；权限缺失时启动自动弹出
- 诊断…：一键检查私有 API、虚拟屏、Sunshine 安装、output_name 一致性、捕获权限（本进程 preflight + 日志推断）、Retina 指引、外接显示器清单
- 开机自启（SMAppService，默认关；需先 install-app.sh 装为 App）
- 退出：销毁虚拟屏并停止 Sunshine 后退出（无确认）

## 网络

同一局域网，2560×1600@60 H.264 约需 60 Mbps；5GHz Wi-Fi 起步，有线更佳。
