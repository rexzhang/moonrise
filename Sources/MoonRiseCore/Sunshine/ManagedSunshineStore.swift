import Foundation

/// 受管 Sunshine 来源：官方 GitHub release 下载 → 验签 → 原子换装（Sunshine 唯一合法获取途径）。
/// 获取仅由用户在设置窗口手动触发；芯片类型贯穿全链路（资产按本机编译架构匹配）。
public final class ManagedSunshineStore: Sendable {

    /// 支持的最低版本（此前版本的捕获路径在 macOS 27 存在串屏/停滞缺陷，S8）
    public static let minimumSupportedVersion = "v2026.1112"

    /// 换装任务阶段（Sunshine 页进度区呈现；任务瞬态，不属于 readiness）
    public enum Phase: Equatable, Sendable {
        case fetching     // 查询 release / 资产
        case downloading  // DMG 下载中（进度：字节）
        case extracting   // 挂载 + 提取
        case verifying    // 验签
        case swapping     // 原子换装
    }

    public struct Release: Identifiable, Equatable, Sendable {
        public let tag: String          // "v2026.1112.40957"
        public let publishedAt: String  // ISO8601 原文（展示用）
        public let isPrerelease: Bool
        public let downloadURL: URL?    // 本机架构资产；nil = 缺资产不可获取
        public let size: Int64?
        public var id: String { tag }

        /// 支持的最低版本判定（tag 语义比较）
        public var isSupported: Bool {
            ManagedSunshineStore.isVersion(tag, atLeast: ManagedSunshineStore.minimumSupportedVersion)
        }
    }

    public enum SunshineError: LocalizedError, Sendable {
        case assetMissing(tag: String, arch: String)
        case rateLimited(resetInMinutes: Int)
        case verifyFailed(reason: String)
        case releaseNotFound(tag: String)
        case unexpectedResponse

        public var errorDescription: String? {
            switch self {
            case .assetMissing(let tag, let arch):
                return "\(tag) 未提供本机架构（\(arch)）的下载资产，无法获取"
            case .rateLimited(let minutes):
                return "GitHub API 限流，约 \(minutes) 分钟后恢复，请稍后重试"
            case .verifyFailed(let reason):
                return "验签未通过：\(reason)"
            case .releaseNotFound(let tag):
                return "未找到版本 \(tag)"
            case .unexpectedResponse:
                return "GitHub API 响应异常"
            }
        }
    }

    private struct GHRelease: Decodable {
        let tag_name: String
        let published_at: String?
        let prerelease: Bool
        let assets: [GHAsset]
    }

    private struct GHAsset: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int64
    }

    private static let expectedTeamIdentifier = "F8XQ7XCN2R"   // LizardByte Developer ID
    private static let apiBase = "https://api.github.com/repos/SunshineStream/Sunshine"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - 就绪与版本查询

    /// 就绪判定唯一来源：受管副本存在且内层可执行（落位时已验签，此处不再验）。
    public static func isReady() -> Bool {
        let path = Paths.managedSunshineExecutableURL.path
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// 已装版本（bundle Info.plist CFBundleShortVersionString）。
    public static func installedVersion() -> String? {
        guard let bundle = Bundle(url: Paths.managedSunshineBundleURL) else { return nil }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// 本机编译架构 → 资产名后缀（arm64 / x86_64）。
    static var archAssetName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return ""
        #endif
    }

    /// tag 语义比较：a ≥ b（按 "." 数字分段，缺段补 0；忽略 v 前缀与空白）。
    public static func isVersion(_ a: String, atLeast b: String) -> Bool {
        let lhs = Self.versionComponents(a)
        let rhs = Self.versionComponents(b)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return true
    }

    private static func versionComponents(_ tag: String) -> [Int] {
        tag.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .compactMap { Int($0) }
    }

    // MARK: - Release 查询

    /// 最新 release（首个含本机架构资产者；不含则报缺资产）。
    public func fetchLatest() async throws -> Release {
        let releases = try await fetchReleases(limit: 20)
        guard let release = releases.first(where: { $0.downloadURL != nil }) else {
            throw SunshineError.assetMissing(tag: releases.first?.tag ?? "-", arch: Self.archAssetName)
        }
        return release
    }

    /// 版本列表（近 N 条正式+预发布；缺本机架构资产者 downloadURL = nil）。
    public func fetchReleases(limit: Int = 20) async throws -> [Release] {
        let data = try await getJSON(path: "releases?per_page=\(limit)")
        let raw = try JSONDecoder().decode([GHRelease].self, from: data)
        return raw.map { r in
            let asset = r.assets.first { $0.name == "Sunshine-macOS-\(Self.archAssetName).dmg" }
            return Release(
                tag: r.tag_name,
                publishedAt: r.published_at ?? "",
                isPrerelease: r.prerelease,
                downloadURL: asset?.browser_download_url,
                size: asset?.size)
        }
    }

    // MARK: - 获取（下载 → 提取 → 验签 → staging 就绪）

    /// 下载并验签指定 tag（nil = 跟随最新），返回 staging 内已验签的 bundle URL。
    /// progress 在调用方指定的线程回调（本实现透传 URLSession 回调线程，UI 侧自行切主线程）。
    @discardableResult
    public func acquire(
        tag: String?,
        progress: @escaping @Sendable (Phase, Int64, Int64) -> Void
    ) async throws -> URL {
        let staging = Paths.managedSunshineStagingDirectory
        try? FileManager.default.removeItem(at: staging)
        try Paths.ensureParentDirectory(of: staging.appendingPathComponent("x"))
        do {
            let staged = try await acquireInner(tag: tag, staging: staging, progress: progress)
            try? FileManager.default.removeItem(at: staging.appendingPathComponent("mnt"))
            return staged
        } catch {
            try? FileManager.default.removeItem(at: staging)   // 失败急切清理（成功路径留给 swapIn）
            throw error
        }
    }

    private func acquireInner(
        tag: String?,
        staging: URL,
        progress: @escaping @Sendable (Phase, Int64, Int64) -> Void
    ) async throws -> URL {
        progress(.fetching, 0, 0)
        let release: Release
        if let tag {
            release = try await releaseByTag(tag)
        } else {
            release = try await fetchLatest()
        }
        guard let downloadURL = release.downloadURL else {
            throw SunshineError.assetMissing(tag: release.tag, arch: Self.archAssetName)
        }

        progress(.downloading, 0, release.size ?? 0)
        let dmgURL = staging.appendingPathComponent("Sunshine-macOS.dmg")
        try await download(downloadURL, to: dmgURL, expected: release.size ?? 0) { done, total in
            progress(.downloading, done, total)
        }

        progress(.extracting, 0, 0)
        let stagedBundle = try extract(dmg: dmgURL, staging: staging)

        progress(.verifying, 0, 0)
        try verify(stagedBundle: stagedBundle, expectedTag: release.tag)

        // 清掉 dmg，只留 bundle（换装原料）
        try? FileManager.default.removeItem(at: dmgURL)
        return stagedBundle
    }

    /// 原子换装：旧 bundle 改名遗留 → staged 就位 → 删遗留（失败回滚旧版）。
    /// 实例的停止与重建由调用方编排（换装前后钩子）。
    public func swapIn(stagedBundle: URL) throws {
        let fm = FileManager.default
        try Paths.ensureParentDirectory(of: Paths.managedSunshineBundleURL)
        let legacy = Paths.managedSunshineDirectory
            .appendingPathComponent("Sunshine.app.legacy-\(UUID().uuidString.prefix(6))")
        if fm.fileExists(atPath: Paths.managedSunshineBundleURL.path) {
            try fm.moveItem(at: Paths.managedSunshineBundleURL, to: legacy)
        }
        do {
            try fm.moveItem(at: stagedBundle, to: Paths.managedSunshineBundleURL)
        } catch {
            if fm.fileExists(atPath: legacy.path) {
                try? fm.moveItem(at: legacy, to: Paths.managedSunshineBundleURL)
            }
            throw error
        }
        try? fm.removeItem(at: legacy)
    }

    // MARK: - 内部：API / 下载 / 提取 / 验签

    private func releaseByTag(_ tag: String) async throws -> Release {
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        let data = try await getJSON(path: "releases/tags/\(encoded)")
        let raw = try JSONDecoder().decode(GHRelease.self, from: data)
        let asset = raw.assets.first { $0.name == "Sunshine-macOS-\(Self.archAssetName).dmg" }
        return Release(
            tag: raw.tag_name,
            publishedAt: raw.published_at ?? "",
            isPrerelease: raw.prerelease,
            downloadURL: asset?.browser_download_url,
            size: asset?.size)
    }

    private func getJSON(path: String) async throws -> Data {
        guard let url = URL(string: "\(Self.apiBase)/\(path)") else {
            throw SunshineError.unexpectedResponse
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Self.throwOnHTTPError(response)
        return data
    }

    fileprivate static func throwOnHTTPError(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SunshineError.unexpectedResponse
        }
        guard !(400...599).contains(http.statusCode) else {
            if http.statusCode == 403 || http.statusCode == 429 {
                let reset = Double(http.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? "") ?? 0
                let minutes = max(1, Int((reset - Date().timeIntervalSince1970) / 60) + 1)
                throw SunshineError.rateLimited(resetInMinutes: minutes)
            }
            throw SunshineError.unexpectedResponse
        }
    }

    private func download(_ url: URL, to destination: URL, expected: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let (bytes, response) = try await session.bytes(from: url)
        try Self.throwOnHTTPError(response)
        let total = expected > 0 ? expected : response.expectedContentLength
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var done: Int64 = 0
        var lastReport: Int64 = 0
        for try await byte in bytes {
            try handle.write(contentsOf: [byte])
            done += 1
            if done - lastReport >= (total > 0 ? total / 100 : 1 << 20) {
                lastReport = done
                progress(done, total)
            }
        }
        progress(done, total)
    }

    /// hdiutil 挂载 → cp -R bundle 到 staging → detach。
    private func extract(dmg: URL, staging: URL) throws -> URL {
        let mountPoint = staging.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        do {
            try runTool("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly",
                                             "-mountpoint", mountPoint.path, dmg.path])
            let source = mountPoint.appendingPathComponent("Sunshine.app")
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw SunshineError.verifyFailed(reason: "DMG 内未找到 Sunshine.app")
            }
            let stagedBundle = staging.appendingPathComponent("Sunshine.app")
            try FileManager.default.copyItem(at: source, to: stagedBundle)
            try? runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
            try? FileManager.default.removeItem(at: mountPoint)
            return stagedBundle
        } catch {
            try? runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
            try? FileManager.default.removeItem(at: mountPoint)
            throw error
        }
    }

    /// 落位前硬校验：TeamIdentifier + 版本一致 + 可执行位。
    private func verify(stagedBundle: URL, expectedTag: String) throws {
        let output = try runTool("/usr/bin/codesign", ["-dv", stagedBundle.path])
        guard output.contains("TeamIdentifier=\(Self.expectedTeamIdentifier)") else {
            throw SunshineError.verifyFailed(reason: "签名身份非 LizardByte 官方（TeamIdentifier 不匹配）")
        }
        guard let bundle = Bundle(url: stagedBundle),
              let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else {
            throw SunshineError.verifyFailed(reason: "bundle Info.plist 缺失或无版本号")
        }
        let expected = expectedTag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard version == expected else {
            throw SunshineError.verifyFailed(reason: "版本不符（期望 \(expected)，实际 \(version)）")
        }
        let executable = stagedBundle.appendingPathComponent("Contents/MacOS/sunshine")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SunshineError.verifyFailed(reason: "内层可执行不可执行")
        }
    }

    /// 运行外部工具（stdout+stderr 合并返回文本）；非零退出抛错。
    @discardableResult
    private func runTool(_ path: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw SunshineError.verifyFailed(reason: "\(URL(fileURLWithPath: path).lastPathComponent) 退出码 \(p.terminationStatus)：\(text.prefix(200))")
        }
        return text
    }
}
