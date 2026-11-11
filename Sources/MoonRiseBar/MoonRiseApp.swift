// MoonRiseApp.swift — @main SwiftUI 入口：Settings 场景（设置窗口）+ WindowGroup / Window
// 场景（修改 / 配对 / 添加子窗口，按值定位窗口，同屏重复打开自动聚焦既有窗口）。
// 菜单栏 NSStatusItem 仍由 AppController 承载（AGENTS.md 允许的例外）。

import SwiftUI

@main
struct MoonRiseApp: App {
    @NSApplicationDelegateAdaptor(AppController.self) private var appDelegate

    var body: some Scene {
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
                    // applySlotEdit 的结果回调在 runBusy 后台线程触发——切回主线程再碰视图状态
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
