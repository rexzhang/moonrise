import Foundation
import CryptoKit
import Darwin

/// 扩展屏 Sunshine 实例的文件布局、conf 键集与端口分配（D1/D3/D4/D16）。
/// 实例目录：~/.config/moonrise/sunshine-instances/<槽位UUID>/
///   sunshine.conf / bin/（独立可执行副本：brew 源为裸二进制 sunshine，
///   官方 .app 源为整 bundle 副本——带启动约束的二进制离开 bundle 即被 SIGKILL）
///   / credentials/（独立 CA + 配对状态）
public enum InstanceConf {
    // MARK: - 文件布局

    public static func directory(for slotID: UUID) -> URL {
        Paths.instanceDirectory(for: slotID)
    }

    public static func confURL(for slotID: UUID) -> URL {
        directory(for: slotID).appendingPathComponent("sunshine.conf")
    }

    public static func binaryURL(for slotID: UUID) -> URL {
        directory(for: slotID).appendingPathComponent("bin/sunshine")
    }

    public static func credentialsDirectory(for slotID: UUID) -> URL {
        directory(for: slotID).appendingPathComponent("credentials")
    }

    public static func credentialsFileURL(for slotID: UUID) -> URL {
        credentialsDirectory(for: slotID).appendingPathComponent("state.json")
    }

    public static func logURL(for slotID: UUID) -> URL {
        Paths.instanceLogURL(for: slotID)
    }

    // MARK: - 端口分配（D3：48089 起步进 100，分配后冻结）

    public enum PortAllocator {
        public static let firstPort = 48_089
        public static let step = 100
        /// base 端口族向上占 ~21 个偏移端口，预留余量防越界
        public static let lastPort = 65_135

        /// 从 firstPort 起步进 step，取第一个不在 taken 集合的端口；耗尽返回 nil。
        public static func nextFree(taken: Set<Int>) -> Int? {
            var port = firstPort
            while port <= lastPort {
                if !taken.contains(port) {
                    return port
                }
                port += step
            }
            return nil
        }
    }

    /// bind 探测端口当前可否占用（AF_INET 直绑，不设 SO_REUSEADDR；成功即关闭）。
    public static func isBindable(_ port: Int) -> Bool {
        guard port > 0, port <= 65_535 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    // MARK: - conf 键集（R3；凭据自包含——D4）

    /// 实例 conf 目标键值。首屏（sunshinePort == nil）走主 conf，不适用，返回 [:]。
    /// 键集：output_name / stream_audio / port / sunshine_name / log_path / pkey / cert /
    /// credentials_file（Web UI 凭据存储）/ file_state（配对状态——不写则落到全局默认路径，
    /// 与主实例及其它实例互相污染）。
    public static func targetValues(for display: DisplayConfig, outputName: UInt32, audioDisabled: Bool) -> [String: String] {
        guard display.sunshinePort != nil else { return [:] }
        let credentials = credentialsDirectory(for: display.id)
        return [
            "output_name": String(outputName),
            "stream_audio": audioDisabled ? "disabled" : "enabled",
            "port": String(display.sunshinePort!),
            "sunshine_name": display.name,
            "log_path": logURL(for: display.id).path,
            "pkey": credentials.appendingPathComponent("cakey.pem").path,
            "cert": credentials.appendingPathComponent("cacert.pem").path,
            "credentials_file": credentialsFileURL(for: display.id).path,
            "file_state": credentialsFileURL(for: display.id).path,
        ]
    }

    // MARK: - 配对状态文件（D4：FRESH_STATE 防线）

    /// 实例配对状态文件（Sunshine 的 credentials_file）。
    /// 两个已知坑（2026-11-11 实测）：
    /// 1. 文件缺失 → Sunshine 置 FRESH_STATE 标志，其后所有配对只驻留内存、
    ///    永不落盘（实例重启即丢失，客户端反复要求重新配对）；
    /// 2. state 缺 root.uniqueid → 同样被视为未初始化。
    /// 因此预写必须带 uniqueid（从槽位 UUID 确定性派生，跨重启稳定）。
    public static func stateFileURL(for slotID: UUID) -> URL {
        credentialsDirectory(for: slotID).appendingPathComponent("state.json")
    }

    /// 槽位唯一ID（大写带连字符 UUID 形式，与 Sunshine uniqueid 格式一致）。
    public static func uniqueID(for slotID: UUID) -> String {
        slotID.uuidString.uppercased()
    }

    /// 确保实例 state 文件存在且含 root.uniqueid。
    /// 幂等：文件已含 uniqueid 时原样保留（不覆盖已配对设备）；
    /// 存在但缺 uniqueid（旧版预写或异常残留）时就地补齐。
    public static func ensureStateFile(for slotID: UUID) throws {
        let url = stateFileURL(for: slotID)
        try Paths.ensureParentDirectory(of: url)
        let fm = FileManager.default
        let uniqueID = uniqueID(for: slotID)

        guard fm.fileExists(atPath: url.path) else {
            let content = "{\"root\": {\"uniqueid\": \"\(uniqueID)\"}}"
            try content.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        // 就地补 uniqueid（保留既有凭据与设备）
        guard let data = try? Data(contentsOf: url),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let fallback = "{\"root\": {\"uniqueid\": \"\(uniqueID)\"}}"
            try fallback.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        var root = object["root"] as? [String: Any] ?? [:]
        guard root["uniqueid"] == nil else { return }
        root["uniqueid"] = uniqueID
        object["root"] = root
        let updated = try JSONSerialization.data(withJSONObject: object)
        try updated.write(to: url, options: .atomic)
    }

    // MARK: - 二进制副本（D16：同一路径并发捕获被 macOS 27 串行化，实例必须独立路径）

    /// 源二进制的宿主 .app bundle（源位于 <bundle>/Contents/MacOS/ 内时返回该 bundle URL）。
    /// 上游官方 Sunshine.app 的二进制带启动约束（锚定自身 bundle 身份）——裸拷贝在
    /// bundle 外 exec 即被 SIGKILL（2026-11-12 实测），此类源必须整 bundle 副本。
    public static func hostAppBundle(of binaryPath: String) -> URL? {
        var url = URL(fileURLWithPath: binaryPath)
        for _ in 0..<4 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" {
                let standardized = (url.path as NSString).standardizingPath
                return URL(fileURLWithPath: standardized)
            }
        }
        return nil
    }

    /// 实例内 bundle 副本路径：<实例>/bin/<源 bundle 名>。
    public static func appBundleCopyURL(for slotID: UUID, bundleName: String) -> URL {
        directory(for: slotID).appendingPathComponent("bin").appendingPathComponent(bundleName)
    }

    /// 确保实例持有与源一致的独立可执行副本，返回可执行文件路径。
    /// 裸二进制源（brew）→ bin/sunshine；bundle 内的源（官方 .app）→ 整 bundle 副本。
    /// 副本已存在且 SHA-256 与源一致则不动，不一致（源升级后）则刷新。
    /// 调用方据此在需要时重启该实例；须在实例未运行时调用。
    @discardableResult
    public static func ensureBinaryCopy(sourceBinaryPath: String, slotID: UUID) throws -> URL {
        if let sourceBundle = hostAppBundle(of: sourceBinaryPath) {
            return try ensureAppBundleCopy(
                sourceBinaryPath: sourceBinaryPath,
                sourceBundle: sourceBundle,
                slotID: slotID)
        }
        let destination = binaryURL(for: slotID)
        try Paths.ensureParentDirectory(of: destination)
        let fm = FileManager.default
        let sourceHash = try sha256(of: sourceBinaryPath)
        if fm.fileExists(atPath: destination.path),
           let destinationHash = try? sha256(of: destination.path),
           destinationHash == sourceHash {
            return destination
        }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(atPath: sourceBinaryPath, toPath: destination.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    /// 整 bundle 副本：以源内层二进制的 SHA-256 为新鲜度锚点，不一致则递归刷新整个副本；
    /// 顺带清理裸二进制旧布局（bin/sunshine，仅实例未运行时可达此处）。
    private static func ensureAppBundleCopy(sourceBinaryPath: String, sourceBundle: URL, slotID: UUID) throws -> URL {
        let destinationBundle = appBundleCopyURL(for: slotID, bundleName: sourceBundle.lastPathComponent)
        let sourceExecutable = URL(fileURLWithPath: sourceBinaryPath)
        guard sourceExecutable.path.hasPrefix(sourceBundle.path + "/") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let relativePath = String(sourceExecutable.path.dropFirst(sourceBundle.path.count + 1))
        let destinationExecutable = destinationBundle.appendingPathComponent(relativePath)
        let fm = FileManager.default
        let sourceHash = try sha256(of: sourceBinaryPath)
        if fm.fileExists(atPath: destinationExecutable.path),
           let destinationHash = try? sha256(of: destinationExecutable.path),
           destinationHash == sourceHash {
            removeLeftoverBareBinaryCopy(slotID: slotID)
            return destinationExecutable
        }
        if fm.fileExists(atPath: destinationBundle.path) {
            try fm.removeItem(at: destinationBundle)
        }
        try Paths.ensureParentDirectory(of: destinationBundle)
        try fm.copyItem(atPath: sourceBundle.path, toPath: destinationBundle.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationExecutable.path)
        removeLeftoverBareBinaryCopy(slotID: slotID)
        return destinationExecutable
    }

    private static func removeLeftoverBareBinaryCopy(slotID: UUID) {
        try? FileManager.default.removeItem(at: binaryURL(for: slotID))
    }

    static func sha256(of path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
