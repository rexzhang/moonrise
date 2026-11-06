import Foundation

/// sunshine.conf 行级编辑器。
/// 原则：只动目标键，其余行逐字节保留（Sunshine Web UI 也会重写此文件，
/// 手动编辑的注释与顺序必须共存）；变更才写盘、才重启。
public enum ConfFile {
    public enum EditResult: Equatable {
        case unchanged
        case changed
    }

    /// 读取 key 的当前值（跳过 # 注释行；值两侧空白去除）。无则 nil。
    public static func readValue(in text: String, key: String) -> String? {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let candidate = line[..<eq].trimmingCharacters(in: .whitespaces)
            if candidate == key {
                return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 把 key 更新为 value：存在则原位替换（保留行首缩进），不存在则追加。
    /// 其余行逐字节保留。返回结果与新文本。
    public static func setValue(in text: String, key: String, value: String) -> (result: EditResult, text: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var replaced = false

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let candidate = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            guard candidate == key else { continue }

            let current = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if current == value {
                return (.unchanged, text)
            }
            let indent = lines[index].prefix(while: { $0 == " " || $0 == "\t" })
            lines[index] = "\(indent)\(candidate) = \(value)"
            replaced = true
            break
        }

        if replaced {
            return (.changed, lines.joined(separator: "\n"))
        }

        // 追加：确保前文以换行结尾
        var output = text
        if !output.isEmpty && !output.hasSuffix("\n") {
            output += "\n"
        }
        output += "\(key) = \(value)\n"
        return (.changed, output)
    }

    /// 文件级联动：读文件 → 逐键更新 → 任一变化才写盘（先备份 .bak）。
    /// 文件不存在视为缺失（调用方提示安装指引，不整体代建）。
    public static func syncValues(configPath: String, values: [String: String]) throws -> EditResult {
        let url = URL(fileURLWithPath: Paths.expandTilde(configPath))
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfFileError.configMissing(url.path)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var output = text
        var changed = false
        for (key, value) in values {
            let (result, newText) = setValue(in: output, key: key, value: value)
            if result == .changed {
                output = newText
                changed = true
            }
        }
        guard changed else { return .unchanged }

        let backupURL = url.deletingLastPathComponent().appendingPathComponent("sunshine.conf.bak")
        try? FileManager.default.copyItem(at: url, to: backupURL)
        try output.write(to: url, atomically: true, encoding: .utf8)
        return .changed
    }
}

public enum ConfFileError: LocalizedError {
    case configMissing(String)

    public var errorDescription: String? {
        switch self {
        case .configMissing(let path):
            return "Sunshine 配置文件不存在：\(path)（先启动一次 Sunshine 让它生成，再重试同步）"
        }
    }
}
