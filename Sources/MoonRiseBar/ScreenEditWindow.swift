// ScreenEditWindow.swift — 屏幕修改窗口（W2，SwiftUI）：修改 / 添加双模式。
// 预设下拉（分组，自带 HiDPI 标记）联动填充；应用 = 校验 → rebuild / create；无删除（在 W1）。

import AppKit
import SwiftUI
import MoonRiseCore

/// 窗口模式。
enum ScreenEditMode {
    /// 修改既有屏（应用 = 该屏销毁重建；停用屏只写配置）。
    case edit(DisplayConfig)
    /// 添加模式（应用 = 创建，编号/命名/端口由 AppController 分配）。
    case add(initialName: String)
}

struct ScreenEditView: View {
    let mode: ScreenEditMode
    let streaming: Bool
    let others: [DisplayConfig]
    /// 应用回调：第二参为就地报错（非 nil = 失败，窗口保持）。
    let onApply: (DisplayConfig, @escaping (String?) -> Void) -> Void
    let onClose: () -> Void
    /// 内容高度实测回调（宿主窗口据此自动调整大小并居中）。
    var onContentHeight: ((CGFloat) -> Void)?

    @State private var name: String
    @State private var width: Int
    @State private var height: Int
    @State private var refreshRate: Int
    @State private var hiDPI: Bool
    @State private var presetID: String = ScreenEditView.customPresetID
    @State private var inlineError: String?

    private static let customPresetID = "custom"
    private let refreshChoices = [30, 60, 75, 120]
    private let original: DisplayConfig?
    private let initialName: String

    init(mode: ScreenEditMode, streaming: Bool, others: [DisplayConfig],
         onApply: @escaping (DisplayConfig, @escaping (String?) -> Void) -> Void,
         onClose: @escaping () -> Void) {
        self.mode = mode
        self.streaming = streaming
        self.others = others
        self.onApply = onApply
        self.onClose = onClose

        let base: DisplayConfig
        let initialAutoName: String
        switch mode {
        case .edit(let display):
            base = display
            initialAutoName = display.name
        case .add(let initialName):
            base = DisplayConfig(slotNumber: 0, name: initialName, width: 2560, height: 1600, refreshRate: 60)
            initialAutoName = initialName
        }
        self.original = mode.editDisplay
        self.initialName = initialAutoName
        _name = State(initialValue: initialAutoName)
        _width = State(initialValue: base.width)
        _height = State(initialValue: base.height)
        _refreshRate = State(initialValue: base.refreshRate)
        _hiDPI = State(initialValue: base.hiDPI)
    }

    private var isAdd: Bool {
        if case .add = mode { return true }
        return false
    }

    private var isPrimary: Bool {
        original?.sunshinePort == nil
    }

    private var disabledScreen: Bool {
        original?.enabled == false
    }

    private var applyTitle: String {
        if isAdd { return "添加" }
        let streamingSuffix = streaming ? "（将短暂中断串流）" : ""
        return "应用修改\(streamingSuffix)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if disabledScreen {
                Text("停用中：修改将在启用后生效")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Form {
                Picker("预设", selection: $presetID) {
                    Text("自定义（当前值）").tag(ScreenEditView.customPresetID)
                    Section("MacBook") {
                        ForEach(DisplayPresets.macbook) { presetTag($0) }
                    }
                    Section("iPad") {
                        ForEach(DisplayPresets.ipad) { presetTag($0) }
                    }
                    Section("Apple 显示器") {
                        ForEach(DisplayPresets.appleDisplay) { presetTag($0) }
                    }
                    Section("通用") {
                        ForEach(DisplayPresets.general) { presetTag($0) }
                    }
                }
                .onChange(of: presetID) { newID in
                    // 选预设即填充规格（HiDPI 随预设标记）；再手改字段不回弹选择器
                    guard newID != Self.customPresetID,
                          let preset = DisplayPresets.all.first(where: { $0.id == newID }) else { return }
                    width = preset.width
                    height = preset.height
                    refreshRate = preset.refreshRate
                    hiDPI = preset.hiDPI
                }
                TextField("名称", text: $name)
                if !isAdd && name != original?.name {
                    Text("⚠ 改名将重置该屏位置与 Retina 记忆")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                HStack {
                    TextField("宽", value: $width, formatter: NumberFormatter())
                    TextField("高", value: $height, formatter: NumberFormatter())
                }
                Picker("刷新率", selection: $refreshRate) {
                    ForEach(refreshChoices, id: \.self) { Text("\($0) Hz").tag($0) }
                }
                Toggle("HiDPI", isOn: $hiDPI)
            }
            if let inlineError {
                Text("✗ \(inlineError)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            HStack {
                Spacer()
                Button("取消") { onClose() }
                Button(applyTitle) { apply() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 450)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ListContentHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(ListContentHeightKey.self) { height in
            onContentHeight?(height)
        }
    }

    private func presetTag(_ preset: DisplayPreset) -> some View {
        Text("\(preset.name)  \(preset.width)×\(preset.height)\(preset.hiDPI ? " · HiDPI ✓" : "")")
            .tag(preset.id)
    }

    private func apply() {
        let candidateName = name.isEmpty ? initialName : name
        let candidate: DisplayConfig
        switch mode {
        case .edit(let originalDisplay):
            candidate = DisplayConfig(
                id: originalDisplay.id,
                slotNumber: originalDisplay.slotNumber,
                name: candidateName,
                width: width,
                height: height,
                refreshRate: refreshRate,
                hiDPI: hiDPI,
                enabled: originalDisplay.enabled,
                sunshinePort: originalDisplay.sunshinePort)
        case .add:
            candidate = DisplayConfig(
                slotNumber: 0,
                name: candidateName,
                width: width,
                height: height,
                refreshRate: refreshRate,
                hiDPI: hiDPI,
                enabled: true)
        }
        do {
            try ScreenChangeValidator.validate(candidate, others: others)
        } catch {
            inlineError = error.localizedDescription
            return
        }
        onApply(candidate) { errorMessage in
            inlineError = errorMessage
        }
    }
}

private extension ScreenEditMode {
    var editDisplay: DisplayConfig? {
        if case .edit(let display) = self { return display }
        return nil
    }
}
