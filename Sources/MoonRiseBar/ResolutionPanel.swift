// ResolutionPanel.swift — 自定义分辨率小窗：宽、高、刷新率下拉。

import AppKit
import MoonRiseCore

final class ResolutionPanelWindow: NSWindow, NSWindowDelegate {
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let refreshPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var onApply: ((Int, Int, Int) -> Void)?
    private let refreshChoices = [30, 60, 75, 120]

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 130),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        title = "自定义分辨率"
        level = .floating
        delegate = self
        isReleasedWhenClosed = false
        buildContentView()
        center()
    }

    func show(initialSpec: DisplaySpec, onApply: @escaping (Int, Int, Int) -> Void) {
        self.onApply = onApply
        widthField.stringValue = String(initialSpec.width)
        heightField.stringValue = String(initialSpec.height)
        let index = refreshChoices.firstIndex(of: initialSpec.refreshRate) ?? 1
        refreshPopup.selectItem(at: index)
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContentView() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 130))
        contentView = content

        let widthLabel = label("宽")
        let heightLabel = label("高")
        let refreshLabel = label("刷新率")

        for value in refreshChoices {
            refreshPopup.addItem(withTitle: "\(value) Hz")
        }

        let grid = NSGridView(views: [
            [widthLabel, widthField],
            [heightLabel, heightField],
            [refreshLabel, refreshPopup]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        content.addSubview(grid)

        let applyButton = NSButton(title: "应用", target: self, action: #selector(applyClicked))
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [cancelButton, applyButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        content.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttonRow.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    @objc private func applyClicked() {
        guard let width = Int(widthField.stringValue),
              let height = Int(heightField.stringValue) else {
            alert("宽高必须是整数")
            return
        }
        let rate = refreshChoices[min(refreshPopup.indexOfSelectedItem, refreshChoices.count - 1)]
        let spec = DisplaySpec(name: "", width: width, height: height, refreshRate: rate)
        do {
            _ = try spec.validated()
        } catch {
            alert(error.localizedDescription)
            return
        }
        close()
        onApply?(width, height, rate)
    }

    @objc private func cancelClicked() {
        close()
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }

    private func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}
