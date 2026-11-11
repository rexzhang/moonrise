# 排障

先打开 设置 → 权限 与 诊断 页：多数问题的状态会直接呈现在这两处。

## 权限类

- Sunshine 报无权限 / 编码器探测失败：设置「权限」页会实时显示 MoonRise 的屏幕捕获与输入控制状态；完成授权后点「重启 Sunshine」重跑编码器探测（授权翻转时也会自动重启）。
- 系统设置列表里看不到 MoonRise 条目：点面板「请求屏幕捕获授权」后在弹窗里点「允许」（不要只点“打开系统设置”）；仍不行就手动添加 /Applications/MoonRise.app。
- 每次重建后权限失效：说明安装时用了 ad-hoc 签名——运行 bash scripts/make-cert.sh --trust 后重新 install-app.sh（签名阶梯见 docs/development.md）。
- 键鼠在 Moon 端不动：输入控制（辅助功能）权限未授予 MoonRise，面板一键请求后即可。

## 显示类

- Moonlight 全屏有黑边：虚拟屏宽高比必须与串流分辨率一致。改分辨率请在 设置 → 屏幕 → 该屏「修改…」里同步改（如 Moonlight 退到 2560×1440 预设，则该屏也选 2560×1440）。
- Retina 发糊：确认 Moon 显示设置是“默认为此显示器”（2x 整数缩放）；虚拟屏选中了逻辑模式（如 1280×800）。
- 改分辨率后没有全倍 Retina：自定义分辨率需为偶数尺寸（逻辑模式 = 一半尺寸）；改完在系统设置重新选一次逻辑模式。
- 改分辨率/逻辑模式后位置变了：改分辨率会重置排列，回系统设置 → 显示器的排列视图把 Moon 拖回主屏旁即可，macOS 会记住新组合。

## 配对类

- 客户端报「证书校验失败 / the client is not authorized」：配对加密握手已成功，但客户端 TLS 握手出示的证书与配对证书不一致（旧版 Moonlight 客户端的钥匙串缺陷，iOS 上实测复现）。删除并重装客户端 Moonlight 后重新配对即可（重装会重新生成钥匙串身份）；Mac 客户端无此问题。
- Moonlight 报「uniqueid already exists」：上一轮配对会话还没结束（服务端在等 PIN，客户端快速重试撞上自己的会话）。等 5 分钟会话过期或对该屏点「重启串流」清掉会话，再发起配对；一次配对流程里不要反复点主机。
- 配对窗口一直「等待客户端发起配对」（列表始终为空）而客户端在等待：实例 Web 凭据脱钩——credentials/state.json 顶层的 username/salt/password（Web UI 凭据哈希）丢失导致服务器凭据归零，全部 API 请求被 302 打回 /welcome。修复：删除实例 credentials/webui.json，关掉并重开该屏配对窗口（App 检测到凭据为空会自动重新预置）。反例（webui.json 丢失但服务器凭据还在，App 提示改走 Web UI）：先手工删去 state.json 顶层凭据字段并对该屏点「重启串流」归零服务器凭据，再按前述自动预置。
- 配对窗口提示成功但客户端仍失败：以实例日志为准（~/.local/state/moonrise/sunshine-<uuid 前 8 位>.log）搜「verified / denied / SSL」——「-- verified」= TLS 校验通过；「SSL Verification error :: Client certificate identity is not enabled」= 见第一条。App 侧日志用 `log stream --level info --predicate 'subsystem == "com.moonrise" OR subsystem == "com.rexzhang.moonrise"'` 实时查看（info 级日志不落盘，`log show` 查不到）。
- App 显示已配对、重启后又要求配对：配对状态没落盘——检查实例 conf 是否含 file_state 键（正常由 MoonRise 写入；手动改过 conf 请对该屏点「重启串流」让其重新同步）。
- PIN 提交后一直转圈：POST /api/pin 会阻塞到客户端完成三步握手才返回（最长 30 秒）——客户端必须保持在前台配对界面；超时多为客户端侧断开。

## 进程类

- 两个 Sunshine 冲突：首屏 Sunshine 由 MoonRise 以子进程独占托管（首次启动自动解除 brew services 注册）；扩展屏实例是 MoonRise 主动拉起的独立副本（各自 conf/端口/凭据），清杀按进程归属判定，不会误伤兄弟实例。不要手动另起实例。
- MoonRise 退出后屏消失、Sunshine 停止：设计如此（生命周期即进程，含全部扩展屏实例）；重新打开即按上次开关状态恢复。
- /Library/ColorSync/Profiles/Displays 里的 ICC 文件：每个虚拟屏身份一个，属主 root，属正常副作用，不要手删。

## 多屏类（多实例）

- 客户端搜不到 Moon 2 之后的屏：Moonlight 客户端的自动发现按 IP 去重（同 IP 多实例只显示其一）——手动添加 `本机IP:端口`（本机 IP 见 设置 → 屏幕 顶部公共信息区）；连接后主机名与屏名一致。
- 连接扩展屏要求 PIN：每个实例独立配对（设计如此）。在 Moonlight 客户端选择该屏主机并连接后，打开 MoonRise 的配对窗口（设置 → 屏幕 → 该屏「配对…」），输入客户端显示的 4 位 PIN 提交即可——无需登录实例 Web UI。
- 实例起不来 / 串流黑帧：先看 设置 → 诊断 页的逐屏 output_name 与实例日志（~/.local/state/moonrise/sunshine-<uuid 前 8 位>.log）；同一路径并发捕获会被 macOS 串行化——MoonRise 已按实例复制独立二进制副本，若手动改动实例目录请点「重启串流」让其按源刷新。
- 端口冲突提示（启用屏幕时）：实例端口冻结（客户端保存了 IP:端口），被其它程序占用时报错不迁移；请释放占用该端口的程序后再启用。
- 改了屏幕名称：会销毁重建该屏（身份随名变化），该屏位置与 Retina 记忆重置一次；客户端主机名同步更新。
