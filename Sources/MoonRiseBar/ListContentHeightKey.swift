// ListContentHeightKey.swift — 设置页面内容实测尺寸（驱动设置窗口高度）。

import SwiftUI

/// 列表内容实测尺寸（宽高双向，驱动 W1 窗口大小）。
struct ListContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = CGSize(width: max(value.width, nextValue().width),
                       height: max(value.height, nextValue().height))
    }
}
