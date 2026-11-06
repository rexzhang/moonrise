# 开发

## 常用命令

```bash
swift build                   # 构建
swift test                    # 单测（身份推导与校验向量、conf 编辑器、规格校验、边界判定、退避序列）
bash scripts/install-app.sh   # 签名并安装为 /Applications/MoonRise.app
bash scripts/make-cert.sh --trust   # 一次性：生成自签代码签名证书（弹框点"始终信任"）
```

### App 图标更新

改 logo 后运行：

```bash
.venv/bin/python scripts/logo_process.py <新logo源图.png>   # 抠图裁剪合成，重出 masters + iconset
bash scripts/install-app.sh
```

若要使用 macOS 26+ 的新格式（IconComposer 导出的 .icon，系统直出无系统托盘白圈）：
1. IconComposer 打开 `assets/brand/logo/moonrise-fg-1044x865.png`（透明双屏前景图层）
2. 背景设纯色 `#101318`，导出为 `assets/brand/MoonRise.icon`
3. 重新运行 `bash scripts/install-app.sh`（脚本检测到 .icon 会自动装入 bundle）
```

## 模块结构

- Sources/VirtualDisplayObjC：CGVirtualDisplay 私有 API 薄封装（MRC，-fno-objc-arc；运行时类/selector 全量校验，缺失时点名报错，不崩溃）
- Sources/MoonRiseCore：规格/身份/控制器、配置、状态、Sunshine 联动（ConfFile 多键编辑、ChildProcessSunshineManager）、权限检测
- Sources/MoonRiseBar：菜单栏 App（AppController / PermissionPanel / DiagnosticsWindow / ResolutionPanel）
- Tests/MoonRiseCoreTests：核心库单测
- AGENTS.md / CLAUDE.md：AI 编码代理的项目规则（含硬约束清单，改动 VirtualDisplay 层前必读）
- Plans/implementation-plan.md：设计决策与实测结论记录

## 签名阶梯

install-app.sh 自动按优先级选择签名身份：Developer ID（付费开发者账号，最耐久且可分发）> MoonRiseDev 自签（本机稳定，免费）> ad-hoc（仅临时，TCC 授权不持久）。

- 生成 MoonRiseDev：bash scripts/make-cert.sh --trust（一次性机器配置）
- 证书/私钥在登录钥匙串，证书副本在 ~/.config/moonrise/certs/
- 切换到 Developer ID 后：TCC 授权锚点变化，需要重新授权一次；此后随 TeamID 稳定

## 约束与注意

- 私有 API 调用纪律、MRC、销毁语义、身份恒定等硬约束见 AGENTS.md——违反会造成静默功能损坏。
- 依赖 CoreGraphics 私有 API（macOS 更新可能失效；App 以菜单错误状态点名缺失项，不会崩溃）。
- 虚拟屏位置不做程序控制（避免“改排列后无法销毁”陷阱），首次手动拖放后由 macOS 记忆。
- 分辨率变更 = 销毁重建（约 1–2s），期间该屏上的窗口会暂时回到主屏。
