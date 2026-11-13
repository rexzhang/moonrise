// MenuBarPanelView.swift — 菜单栏面板（MenuBarExtra .window）：
// 状态行 / 每屏整行点击切换（四态彩色圆点）/ 内联错误 / 设置与退出。

import SwiftUI
import AppKit
import MoonRiseCore

/// 菜单面板可观察状态：AppController 经 syncPanel 主线程推送（真源在 AppController）。
final class PanelModel: ObservableObject {
    static let shared = PanelModel()
    @Published var phase: AppController.Phase = .starting
    @Published var summaries: [AppController.ScreenSummary] = []
    @Published var busy = false
    @Published var panelError: String?

    private init() {}
}

struct MenuBarPanelView: View {
    @ObservedObject var model: PanelModel
    let controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow
            Divider()
            ForEach(model.summaries) { summary in
                screenRow(summary)
            }
            if let error = model.panelError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            actionsRow
        }
        .padding(12)
        .frame(width: 280)
    }

    // MARK: - 状态行

    @ViewBuilder
    private var statusRow: some View {
        switch model.phase {
        case .starting:
            Label("启动中…", systemImage: "hourglass")
                .font(.callout)
                .foregroundColor(.secondary)
        case .locked:
            Button {
                SettingsCoordinator.shared.showSettings(page: .sunshine)
            } label: {
                Label("Sunshine 未就绪 — 点击设置", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.orange)
        case .running:
            Text(aggregateText)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .degraded(let message):
            Text("错误：\(message)")
                .font(.callout)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var aggregateText: String {
        let summaries = model.summaries
        let enabledCount = summaries.filter(\.enabled).count
        let streamingCount = summaries.filter { $0.state == .streaming }.count
        let instancesTotal = summaries.filter { $0.enabled }.count
        let instancesRunning = summaries.filter { $0.enabled && $0.instanceStatus != "未运行" }.count
        return "\(enabledCount) 屏 · 串流 \(streamingCount) · 实例 \(instancesRunning)/\(instancesTotal)"
    }

    // MARK: - 每屏行（整行点击切换启用）

    private func screenRow(_ summary: AppController.ScreenSummary) -> some View {
        let locked = model.phase == .locked
        return Button {
            controller.toggleScreen(slotID: summary.slotID)
        } label: {
            HStack(spacing: 8) {
                dot(for: summary.state)
                Text("\(summary.name) · \(locked ? "未就绪" : summary.state.label)")
                    .font(.callout)
                    .foregroundColor(locked ? .secondary : .primary)
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked || model.busy)
    }

    /// 圆点四态：串流 = 绿实心；空闲 = 绿描边；停用 = 灰描边；离线 = 橙实心。
    private func dot(for state: ScreenState) -> some View {
        Group {
            switch state {
            case .streaming: Circle().fill(.green)
            case .idle: Circle().strokeBorder(.green, lineWidth: 1.5)
            case .disabled: Circle().strokeBorder(.secondary, lineWidth: 1.5)
            case .offline: Circle().fill(.orange)
            }
        }
        .frame(width: 9, height: 9)
    }

    // MARK: - 操作行

    private var actionsRow: some View {
        HStack {
            SettingsLink {
                Label("设置…", systemImage: "gearshape")
                    .font(.callout)
            }
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
                    .font(.callout)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
