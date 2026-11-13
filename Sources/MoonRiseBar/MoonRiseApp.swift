// MoonRiseApp.swift — @main SwiftUI 入口：MenuBarExtra(.menu) 标准菜单（菜单栏）+
// Settings 场景（设置窗口）+ WindowGroup / Window 场景（修改 / 配对 / 添加子窗口）。

import SwiftUI
import AppKit
import MoonRiseCore

/// 菜单面板可观察状态：AppController 经 syncPanel 主线程推送（真源在 AppController）。
final class PanelModel: ObservableObject {
    static let shared = PanelModel()
    @Published var phase: AppController.Phase = .starting
    @Published var summaries: [AppController.ScreenSummary] = []
    @Published var busy = false

    private init() {}
}

@main
struct MoonRiseApp: App {
    @NSApplicationDelegateAdaptor(AppController.self) private var appDelegate
    @StateObject private var panel = PanelModel.shared

    var body: some Scene {
        MenuBarExtra {
            menuContent
        } label: {
            switch panel.phase {
            case .starting, .running:
                Image(nsImage: BrandGlyph.normal())
            case .locked, .degraded:
                Image(nsImage: BrandGlyph.problem())
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsRootView(model: SettingsCoordinator.shared.model)
        }

        WindowGroup("修改屏幕", id: "moonrise.edit", for: UUID.self) { $slotID in
            EditWindowRootView(slotID: $slotID)
        }
        .windowResizability(.contentSize)

        WindowGroup("配对", id: "moonrise.pairing", for: UUID.self) { $slotID in
            PairingWindowRootView(slotID: $slotID)
        }
        .windowResizability(.contentSize)

        Window("添加屏幕", id: "moonrise.add") {
            AddWindowRootView()
        }
        .windowResizability(.contentSize)
    }

    // MARK: - 菜单项（标准菜单）

    @ViewBuilder
    private var menuContent: some View {
        switch panel.phase {
        case .starting:
            Text("启动中…")
        case .locked:
            Button("Sunshine 未就绪 — 点击设置") {
                SettingsCoordinator.shared.showSettings(page: .sunshine)
            }
        case .running:
            Text(aggregateText)
        case .degraded(let message):
            Text("错误：\(message)")
        }
        Divider()
        ForEach(panel.summaries) { summary in
            Button {
                appDelegate.toggleScreen(slotID: summary.slotID)
            } label: {
                Label(title: { Text("\(summary.name) · \(summary.state.label)") },
                      icon: { Image(nsImage: BrandGlyph.dot(for: summary.state)) })
            }
            .disabled(panel.busy || panel.phase == .locked)
        }
        Divider()
        SettingsLink {
            Label("设置…", systemImage: "gearshape")
        }
        Divider()
        Button("退出") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var aggregateText: String {
        let summaries = panel.summaries
        let enabledCount = summaries.filter(\.enabled).count
        let streamingCount = summaries.filter { $0.state == .streaming }.count
        let instancesTotal = summaries.filter { $0.enabled }.count
        let instancesRunning = summaries.filter { $0.enabled && $0.instanceStatus != "未运行" }.count
        return "\(enabledCount) 屏 · 串流 \(streamingCount) · 实例 \(instancesRunning)/\(instancesTotal)"
    }
}

// MARK: - 修改窗口（按屏）

struct EditWindowRootView: View {
    @Binding var slotID: UUID?
    @ObservedObject private var model = SettingsCoordinator.shared.model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let slotID, let display = model.displays.first(where: { $0.id == slotID }) {
            ScreenEditView(
                mode: .edit(display),
                streaming: model.summary(for: display.id)?.state == .streaming,
                others: model.displays.filter { $0.id != display.id },
                onApply: { candidate, reportError in
                    // applyEdit 的结果回调在 runBusy 后台线程触发——切回主线程再碰视图状态
                    model.callbacks.applyEdit?(candidate) { errorMessage in
                        DispatchQueue.main.async {
                            if let errorMessage {
                                reportError(errorMessage)
                            } else {
                                dismiss()
                            }
                        }
                    }
                },
                onClose: { dismiss() })
                .navigationTitle("修改屏幕 — \(display.name)")
                .onChange(of: model.displays.map(\.id)) { ids in
                    // 屏幕被删除：编辑窗口随之关闭（原 closeEdit 语义）
                    if !ids.contains(slotID) { dismiss() }
                }
        } else {
            VStack(spacing: 10) {
                Text("该屏幕不存在或已被删除")
                    .foregroundColor(.secondary)
                Button("关闭") { dismiss() }
            }
            .padding(20)
            .frame(width: 280)
        }
    }
}

// MARK: - 配对窗口（按屏）

struct PairingWindowRootView: View {
    @Binding var slotID: UUID?
    @ObservedObject private var model = SettingsCoordinator.shared.model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let slotID, let display = model.displays.first(where: { $0.id == slotID }) {
            PairingView(
                slotID: display.id,
                screenName: display.name,
                webPort: (display.sunshinePort ?? 47989) + 1,
                isPrimary: display.sunshinePort == nil,
                credentialsURL: display.sunshinePort == nil
                    ? model.primaryCredentialsURL ?? InstanceWebAPI.primaryWebUICredentialsURL(
                        configPath: AppConfig().sunshine.configPath)
                    : InstanceWebAPI.webUICredentialsURL(for: display.id),
                onClose: { dismiss() })
                .navigationTitle("配对 — \(display.name)")
        } else {
            VStack(spacing: 10) {
                Text("该屏幕不存在或已被删除")
                    .foregroundColor(.secondary)
                Button("关闭") { dismiss() }
            }
            .padding(20)
            .frame(width: 280)
        }
    }
}

// MARK: - 添加窗口（单例）

struct AddWindowRootView: View {
    @ObservedObject private var model = SettingsCoordinator.shared.model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScreenEditView(
            mode: .add(initialName: AppController.nextAutoName(used: Set(model.displays.map(\.name)))),
            streaming: false,
            others: model.displays,
            onApply: { candidate, reportError in
                model.callbacks.applyAdd?(candidate) { errorMessage in
                    DispatchQueue.main.async {
                        if let errorMessage {
                            reportError(errorMessage)
                        } else {
                            dismiss()
                        }
                    }
                }
            },
            onClose: { dismiss() })
            .navigationTitle("添加屏幕")
    }
}
