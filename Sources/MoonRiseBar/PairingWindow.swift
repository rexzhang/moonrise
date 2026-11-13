// PairingWindow.swift — 配对窗口（W3，SwiftUI）：凭据预置 → 轮询待配对设备 → PIN 提交。
// 凭据为空即自动预置接管（首屏与扩展屏一致）；已自设凭据时首屏走 Web UI 引导（凭据归用户）。

import AppKit
import SwiftUI
import MoonRiseCore

@MainActor
final class PairingModel: ObservableObject {
    enum Phase: Equatable {
        case provisioning
        case fallback(String)   // 凭据预置失败（用户已自设 / 超时离线）
        case primaryGuide       // 首屏：Web UI 配对引导
        case running
    }

    @Published var phase: Phase = .provisioning
    @Published var devices: [InstanceWebAPI.PendingPairing] = []
    @Published var selectedDeviceID: String?
    @Published var pin: String = ""
    @Published var result: (text: String, ok: Bool)?
    /// 本轮配对已成功（停轮询，界面只显示成功态）。
    @Published var pairedDone = false
    @Published var credentials: InstanceWebAPI.Credentials?

    private var pollTask: Task<Void, Never>?

    /// 启动配对：先尝试自动预置凭据（凭据为空即接管，首屏与扩展屏一致——首屏重置后账号为空，
    /// 可一站式配对）；已自设凭据或实例未就绪时降级：首屏走 Web UI 引导，扩展屏走就地提示。
    func start(webPort: Int, isPrimary: Bool, credentialsURL: URL) {
        Task {
            if let credentials = await InstanceWebAPI.provisionCredentialsIfNeeded(credentialsURL: credentialsURL, webPort: webPort) {
                self.credentials = credentials
                phase = .running
                pollTask = Task { [weak self] in
                    while !Task.isCancelled {
                        await self?.poll(webPort: webPort)
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
                return
            }
            phase = isPrimary
                ? .primaryGuide
                : .fallback("该实例使用自设 Web UI 凭据（或实例未就绪），请到 Web UI 配对")
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func poll(webPort: Int) async {
        do {
            let newDevices = try await InstanceWebAPI.pendingPairings(credentials: credentials, webPort: webPort)
            if newDevices.map(\.id) != devices.map(\.id) {
                Log.info("配对轮询：待配对设备 \(newDevices.map(\.name))")
            }
            devices = newDevices
            if selectedDeviceID == nil {
                selectedDeviceID = newDevices.first?.id
            }
        } catch {
            // 轮询错误就地显示，继续轮询（D12 对账原则）
            Log.error("配对轮询失败：\(error.localizedDescription)")
            result = ("✗ \(error.localizedDescription)", false)
        }
    }

    func submit(webPort: Int) {
        guard let device = devices.first(where: { $0.id == selectedDeviceID }) else { return }
        guard let credentials else {
            result = ("✗ 实例 Web 凭据未预置", false)
            return
        }
        let pairingID = device.id
        let deviceName = device.name
        Log.info("配对提交：设备=\(deviceName) pairing_id=\(pairingID) pin=\(pin)")
        Task {
            do {
                let paired = try await InstanceWebAPI.submitPin(
                    credentials: credentials,
                    webPort: webPort,
                    pairingID: pairingID,
                    name: deviceName,
                    pin: pin)
                if paired {
                    Log.info("配对成功：设备=\(deviceName)")
                    pairedDone = true
                    result = ("✓ 已配对，客户端可连接", true)
                    pin = ""
                    devices = []
                    selectedDeviceID = nil
                    pollTask?.cancel()
                    pollTask = nil
                } else {
                    Log.error("配对被拒：PIN 错误或验证失败，清理残留会话 \(pairingID)")
                    result = ("✗ 配对失败：PIN 错误或验证失败（客户端重新发起后可再试）", false)
                    // 清理残留会话（失败后服务端可能仍挂着重试会话）
                    try? await InstanceWebAPI.cancelPairing(credentials: credentials, webPort: webPort, pairingID: pairingID)
                }
            } catch {
                Log.error("配对提交异常：\(error.localizedDescription)")
                result = ("✗ \(error.localizedDescription)", false)
                // 异常路径也可能留下半完成的会话，一并清理
                try? await InstanceWebAPI.cancelPairing(credentials: credentials, webPort: webPort, pairingID: pairingID)
            }
        }
    }
}

struct PairingView: View {
    let slotID: UUID
    let screenName: String
    let webPort: Int
    let isPrimary: Bool
    /// MoonRise 侧凭据副本路径（实例 webui.json 或主实例同目录 webui.json）。
    let credentialsURL: URL
    let onClose: () -> Void

    @StateObject private var model = PairingModel()
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .provisioning:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("准备中…")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .fallback(let message):
                Text("⚠ \(message)")
                    .font(.callout)
                Button("打开 Web UI") {
                    if let url = URL(string: "https://localhost:\(webPort)") {
                        openURL(url)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            case .primaryGuide:
                Text("\(screenName) 使用你自设的 Web UI 凭据，配对请到 Web UI 完成：")
                    .font(.callout)
                Text("1. 打开 \(webUIText)\n2. 登录后在「PIN」页输入客户端显示的 PIN")
                    .font(.callout)
                    .textSelection(.enabled)
                Button("打开 Web UI") {
                    if let url = URL(string: "https://localhost:\(webPort)") {
                        openURL(url)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            case .running:
                if model.pairedDone {
                    // 成功态只显示结果行，不再展示等待/待配对区域
                } else if model.devices.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("等待客户端发起配对…（在 Moonlight 上选择本主机并连接，客户端会显示 4 位 PIN）")
                            .font(.callout)
                    }
                } else {
                    Text("待配对设备").font(.callout).fontWeight(.semibold)
                    ForEach(model.devices, id: \.id) { device in
                        HStack {
                            Image(systemName: model.selectedDeviceID == device.id ? "record.circle" : "circle")
                            Text("\(device.name)（\(device.address)）")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedDeviceID = device.id }
                    }
                    HStack {
                        Text("PIN").font(.callout)
                        TextField("4 位数字", text: $model.pin)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 100)
                        Button("提交配对") { model.submit(webPort: webPort) }
                            .disabled(!InstanceWebAPI.isValidPin(model.pin) || model.selectedDeviceID == nil)
                    }
                }
                if let result = model.result {
                    Text(result.text)
                        .font(.callout)
                        .foregroundColor(result.ok ? .green : .red)
                }
                credentialsSection
            }
            HStack {
                Spacer()
                Button("关闭") { onClose() }
            }
        }
        .padding(16)
        .frame(width: 350, alignment: .leading)
        .task {
            model.start(
                webPort: webPort,
                isPrimary: isPrimary,
                credentialsURL: credentialsURL)
        }
        .onDisappear { model.stop() }
    }

    private var webUIText: String {
        "https://localhost:\(webPort)"
    }

    private func selectedDeviceID(_ model: PairingModel) -> Bool {
        model.selectedDeviceID != nil
    }

    @ViewBuilder
    private var credentialsSection: some View {
        if let credentials = model.credentials {
            DisclosureGroup("Web UI 凭据（MoonRise 预置）") {
                HStack {
                    Text(credentials.username).font(.system(.caption, design: .monospaced))
                    Button("复制") { AppController.copyToPasteboard(credentials.username) }
                }
                HStack {
                    Text(credentials.password).font(.system(.caption, design: .monospaced))
                    Button("复制") { AppController.copyToPasteboard(credentials.password) }
                }
            }
            .font(.caption)
        }
    }
}
