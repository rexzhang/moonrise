# 多扩展屏 Spike 验证报告

日期：2026-11-10。环境：MacBook（Apple M4）· macOS 27.2 (26B123) · Sunshine 2026.914.233613（brew，主实例经 MoonRise 托管在跑）· Moonlight 客户端：一台 Mac（moonlight-qt）+ 一台 iPad。

方法：spike 工具链全部位于 /private/tmp/spike/（不触碰产品代码）——vd-harness（复用产品 shim 建两块 2560×1600@60 HiDPI 虚拟屏，挪出主屏区域后常驻）；两份实例 conf（独立端口 48089/48189、独立 output_name、独立 credentials_file、独立 log_path）；launchd submit 拉起实例；客户端手动添加 IP:端口 配对并串流。

## 结论总表

| # | 验证项 | 结果 | 结论 |
|---|---|---|---|
| S1 | 双实例共存 | 通过 | 两实例同时存活、各自日志钉住各自屏（22/23）；前提是**不同二进制路径**，见 S7 |
| S2 | 共享 CA 免重复配对 | 不成立 | 客户端按主机条目（IP:端口）各自建立配对，共享 CA + 播种配对状态不免 PIN；逐实例 PIN 配对 + App 配对辅助为主路径（用户已接受） |
| S3 | 双并发串流 | 通过 | 双路 VideoToolbox H.264 并发 ≥12 分钟零断连，单路约 38% CPU，M4 余量充足 |
| S4 | 输入注入坐标 | 通过 | 两客户端键鼠各归各屏，四角点击无串扰 |
| S5 | 日志分流 | 通过 | log_path 键生效（逐实例独立日志）；实例状态文件独立；无共享写冲突 |
| S6 | 自动发现 + 名称对应 | 部分通过 | 自动发现不可用（Moonlight 客户端按 IP 去重，同 IP 多实例只认其一）；**手动添加 IP:端口 为主路径**；连接后客户端显示 sunshine_name（Spike A/B），屏名对应有效 |
| S7 | 捕获路径序列化（新发现） | 关键机制 | 同一二进制路径的第二个进程进入捕获即永久挂起（探测阶段 dummy 帧不送达）；不同路径（各自授权）完全共存，见下 |

## S7 机制与实验记录

现象：同路径两实例并发或先后进入编码探测，后到者永久卡死在 `probe_encoders → dummy_img → dispatch_semaphore_wait`（等待永不送达的首帧）；先到者不受影响。同路径对（无论 16/17、22/23 哪块屏、无论间隔 33 秒错峰）100% 复现；不同路径对（各自 TCC 授权）零复现。未授权路径的新实例快速失败（"No screen capture permission"），与挂起是两种签名。TCC 授权按二进制路径记账（同 cdhash 不同路径不共享授权）。

产品对策：

1. 每个实例持有独立二进制副本路径：实例目录 sunshine-instances/<uuid>/bin/sunshine（约 17 MB × N）；创建实例时从探测到的主二进制复制，实例启动时校验副本与源一致，不一致则刷新副本并重启该实例。
2. 外部实例清杀按父进程判定（ppid），不按路径——同路径副本属正常形态。
3. 遗留验证（实现期 R3 验收必做）：MoonRise.app 直接 spawn 两个不同路径副本作为子进程，确认 MoonRise 归属（responsible process）下并发捕获可用。若归属级序列化仍存在（即路径对策无效），架构需回退评估：单实例 + 串流目标切换（多客户端同时各连一块屏的需求降级）。目前证据倾向路径级机制（不同授权路径共存成立），归属级风险偏低但必须实证。

## 其它观察

- Moon 屏 displayID 漂移 15 → 19：spike 建屏触发 MoonRise 重建自家屏并自动重写主 conf 的 output_name——现有漂移对冲行为符合预期，多屏设计继续沿用（逐实例重写）。
- A 会话两次偶发 "Encoder did not produce IDR frame when requested!"，自愈，会话不中断。
- spike 实例未写 stream_audio 键（音频默认启用）；产品保持全局默认禁用不变。
- 虚拟屏若被 WindowServer 叠在主屏区域内不影响捕获（早期重叠假设被否定：22/23 挪位后且互不重叠时单实例可捕获，互卡与重叠无关；但布局仍建议引导用户在系统设置中排列整齐）。
- Moonlight 客户端手动添加主机、PIN 配对、双会话操作全程顺畅；iPad 与 Mac 表现一致。

## 设计修订（已折回计划）

1. D4 改写：免配对方案废除；配对逐实例 PIN + 管理窗口配对引导；实例凭据完全自包含（独立 CA + 配对状态于实例目录）。
2. D1 补充：实例独立二进制副本路径（对策见上）。
3. D6 改写：自动发现不可用为实测结论；手动添加 IP:端口 为标准路径，管理窗口突出一键复制；sunshine_name 名称对应保持。
4. R3 新增：二进制副本管理 + 归属级序列化验证（实现期）。
5. AGENTS.md（R5 执行）：新增"多实例二进制路径必须独立；外部实例清杀按 ppid 判定"。

## 环境清理清单（测完执行）

- launchctl remove spike.sunshineA / spike.sunshineB2；pkill spike sunshine 进程；kill vd-harness（两块 spike 屏随之销毁）。
- 系统设置中移除两条屏幕录制 / 辅助功能授权（/private/tmp/spike/bin/sunshine-spike 与 sunshine-spike-b）。
- /private/tmp/spike/ 整目录删除。

## 配对排障实测结论（2026-11-11，配对窗口联调期）

1. conf 键：实例 conf 必须写 file_state（nvhttp 配对状态落盘路径）。credentials_file 只重定向 Web UI 凭据存储（confighttp）；缺 file_state 时配对状态落到全局默认 ~/.config/sunshine/sunshine_state.json，与主实例及其它实例互相污染（实测已发生：实例配对条目写入全局文件）。credentials_file 缺省取 file_state 值，两键同值即可自包含。
2. state.json 双用途格式：顶层 username/salt/password = Web UI 凭据哈希（confighttp 启动时读取），root = 配对状态（uniqueid/named_devices）。预写或清理该文件时顶层凭据字段必须保留，否则 Web 凭据归零、全部 /api/* 请求 302 回 /welcome——App 侧表现为永远 0 个待配对设备（URLSession 自动跟随 302，掩盖了 401）。
3. 配对 API 语义：POST /api/pin 阻塞到客户端三步握手（challenge → secret）完成才返回 {"status": 最终结果}（最长 ping_timeout=30s）；GET /api/pin 只列 phase=NONE 的会话，握手中的会话不可见；会话 5 分钟过期；成功与失败都会移除会话——"会话消失"不能作为成功判据，权威判定 = 响应 status 或 GET /api/clients/list。
4. 同证书多条目陷阱：同一客户端证书在 named_devices 存 ≥2 条时，is_client_enabled 判歧义返回 false——即使客户端出示的就是该证书也永远拒绝。落盘路径正确后不再积累；历史上重复条目需手动清理或实例重启清内存。
5. /unpair 端点已从 nvhttp 移除（配对管理走 Web UI /api/clients/unpair）：客户端发起的 /unpair 落 404，无副作用。
6. iPad（moonlight-iOS，iPad mini 4 / iOS 15.8）实测：getservercert 查询参数与 clientpairingsecret 签名是同一张证书（服务端哈希/签名校验通过、入库成功、{"status":true}），但随后 HTTPS（base−5 端口）TLS 握手出示的证书与之不同 → "Client certificate identity is not enabled" → 客户端报"证书校验失败"。同一进程内首轮即复现（内存仅一条时即被拒），排除多条目歧义。结论：iPad 端 TLS 身份与配对证书不一致（旧版 app 的证书未进钥匙串/未同步给 URLSession）。已验证对策（2026-11-11）：删除并重装 iPad Moonlight 后重新配对一次成功——钥匙串身份随重装重新生成，TLS 证书与配对证书一致（新证书指纹不同于旧证书），TLS 校验连续通过、配对状态正确落盘实例 state.json。同场景 Mac 客户端（moonlight-qt）无此问题。

## S8 捕获错位、AVFoundation 停滞与官方 .app 升级链（2026-11-12）

环境：macOS 27.2.1（26B131，11-06 从 26B123 升级）· Sunshine 2026.914.233613（brew，AVFoundation 捕获路径）。

1. 捕获错位（串屏）：主实例按 output_name 指定 displayID 请求捕获，实际拿到另一块虚拟屏的实时像素。conf 映射、EDID 名称、CG 镜像集（CGDisplayIsInMirrorSet=0）、WindowServer 布局 UUID、实例↔客户端对应全部核实正确；两个实例日志均声明 "Configuring selected display (自己的 ID)"——错接发生在 AVCaptureScreenInput/CMIO 取帧环节，与屏/实例的创建顺序相关（先 Moon 2 后 Moon 1 触发），可演化为两个客户端同看一块屏。单向：按"原主"屏捕获的实例不受影响。
2. AVFoundation 停滞（断连）：Moonlight 客户端弹窗报错后自动重连，会话 51s~4m 不等，宿主日志零错误、编码器正常。单屏基线也断连（10 分钟 5 次）→ 停滞是 2026.914 捕获路径自身问题，与错捕同屏后的双重捕获竞争叠加放大。
3. 上游对照：PR #5511（2026-11-11 合并，v2026.1112.* 起包含）承认 AVFoundation 捕获不可靠，以 ScreenCaptureKit 重写为默认捕获后端（按 SCDisplay 对象绑定 + SCShareableContent 刷新重试 + OBS 式流参数）。升级官方 Sunshine.app 2026.1112.40957 后实测：双屏内容各归各屏（16:10/4:3 矩阵正确）、双路 SCCapture 就绪、双客户端并发 10 分钟零断连零异常（对照升级前单屏基线 10 分钟断连 5 次）。
4. 官方 .app 二进制带启动约束（锚定自身 bundle 身份）：裸二进制拷贝到任何路径 exec 即 SIGKILL（exit 137，无任何输出、AMFI 无击杀记录）；剥 com.apple.provenance xattr 无效；整 bundle 拷贝后内层二进制可正常启动。实例副本布局因此改为 <实例>/bin/<源 bundle 名>/ 整 bundle 拷贝（InstanceConf.ensureBinaryCopy 按 hostAppBundle 分支），可执行路径指向副本内层二进制。
5. 官方包 Qt 静态链接且只带 cocoa 平台插件（无 minimal）：MoonRise 的 hideTrayIcon（QT_QPA_PLATFORM=minimal）会令其启动即退（"no Qt platform plugin could be initialized"）。现行折中 hideTrayIcon=false（cocoa 正常，Sunshine 托盘图标可见，每实例一个）。
6. 主实例二进制路径新增 sunshine.binaryPath 配置覆盖（AppConfig.SunshineConfig；nil = brew 自动探测回退，路径不可执行时记错误日志并回退）。
7. 诊断教训：MoonRise info 级 os_log 不落盘，`log show` 查不到实例 spawn/退出详情——必须 `log stream --level info` 实时抓取（troubleshooting 已有记载，实测再次验证）。
8. 托盘抑制正解（2026-11-13 实测）：上游 conf 键 `system_tray`（默认 true，v2026.1112.40957 src/config.cpp:1891 起）写 disabled 后进程跳过主线程事件循环（src/main.cpp:156-162），托盘不创建、串流正常——S8 第 5 条的 Qt minimal 插件死结就此解除。to_bool 语义：仅 true/yes/enabled/on/含 "1" 为真，其余为假。
