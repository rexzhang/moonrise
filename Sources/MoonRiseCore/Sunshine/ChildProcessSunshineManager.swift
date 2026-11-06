import Foundation

/// 退避重启计算器：5s 起倍增，封顶 60s；运行稳定后可重置。
public struct RestartBackoff {
    public private(set) var attempt = 0
    public let base: TimeInterval
    public let cap: TimeInterval

    public init(base: TimeInterval = 5, cap: TimeInterval = 60) {
        self.base = base
        self.cap = cap
    }

    public mutating func nextDelay() -> TimeInterval {
        let delay = min(base * pow(2, Double(attempt)), cap)
        attempt += 1
        return delay
    }

    public mutating func reset() {
        attempt = 0
    }
}

/// 以子进程方式独占管理 Sunshine（MoonRise 为父进程）：
/// 退出连带停止，异常退出退避重启。
///
/// TCC 归属：子进程的屏幕捕获/辅助功能按"责任进程"归属 MoonRise.app，
/// 由 scripts/make-cert.sh 生成的自签代码签名证书（MoonRiseDev）保证
/// 跨重建稳定——ad-hoc 签名每次重建 cdhash 变化会导致授权失效。
/// 启动走 /opt/homebrew/opt/sunshine/bin/sunshine（opt 稳定符号链接）。
public final class ChildProcessSunshineManager: SunshineManaging {

    public enum RunState: Equatable {
        case idle
        case running(pid: Int32)
        case crashed(retries: Int)
    }

    private let queue = DispatchQueue(label: "com.moonrise.sunshine-child")
    private let binPath: String
    private let confPath: String
    private let logURL: URL
    private let hideTrayIcon: Bool

    private var process: Process?
    private var startedAt: Date?
    private var isStopping = false
    private var backoff = RestartBackoff()
    private var brewMigrationDone = false
    private var runState: RunState = .idle

    public init(binPath: String, confPath: String, logURL: URL, hideTrayIcon: Bool = true) {
        self.binPath = binPath
        self.confPath = confPath
        self.logURL = logURL
        self.hideTrayIcon = hideTrayIcon
        try? Paths.ensureParentDirectory(of: logURL)
    }

    // MARK: - SunshineManaging

    public func detect() -> SunshineInstallInfo? {
        Self.detectBinary().map { SunshineInstallInfo(binaryPath: $0) }
    }

    public func start() throws {
        try queue.sync { try startLocked() }
    }

    public func stop() throws {
        // 摘引用在队列内；SIGTERM 与轮询在队列外（避免阻塞 statusLine 等调用）
        let victim: Process? = queue.sync { () -> Process? in
            guard let p = process, p.isRunning else {
                process = nil
                runState = .idle
                backoff.reset()
                return nil
            }
            isStopping = true
            return p
        }
        guard let victim else { return }
        victim.interrupt()  // SIGTERM
        let deadline = Date().addingTimeInterval(5)
        while victim.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if victim.isRunning {
            kill(victim.processIdentifier, SIGKILL)
        }
        queue.sync {
            process = nil
            runState = .idle
            backoff.reset()
        }
    }

    public func restart() throws {
        try stop()
        try start()
    }

    public func statusLine() -> String {
        queue.sync {
            switch runState {
            case .idle:
                return "未运行"
            case .running(let pid):
                return "运行中 pid=\(pid)"
            case .crashed(let retries):
                return "退避重启中（第 \(retries) 次失败）"
            }
        }
    }

    // MARK: - 内部

    public static func detectBinary() -> String? {
        [
            "/opt/homebrew/opt/sunshine/bin/sunshine",
            "/opt/homebrew/bin/sunshine",
            "/usr/local/opt/sunshine/bin/sunshine",
            "/usr/local/bin/sunshine"
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func startLocked() throws {
        if case .running = runState { return }  // 幂等
        if !brewMigrationDone {
            migrateAwayFromBrewServices()
            brewMigrationDone = true
        }
        // 单实例：清掉外部实例（brew 残留 / Sunshine 保存配置时自我 fork 的孤儿）
        let foreign = Self.findRunningSunshinePIDs(pattern: binPath)
        if !foreign.isEmpty {
            Log.info("发现外部 Sunshine 实例 \(foreign)，终止后由本 App 接管")
            for pid in foreign {
                Self.terminate(pid: pid, graceSeconds: 3)
            }
        }
        try spawnLocked()
    }

    private func spawnLocked() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binPath)
        p.arguments = [confPath]
        if hideTrayIcon {
            // Qt 托盘是 Sunshine 唯一的 GUI 用途；minimal 平台下托盘创建失败
            // 且 Sunshine 优雅继续（捕获/编码/Web UI 均不走 Qt）——图标从
            // 菜单栏消失，"退出 Sunshine" 的旁路入口也随之消失
            var env = ProcessInfo.processInfo.environment
            env["QT_QPA_PLATFORM"] = "minimal"
            p.environment = env
        }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            p.standardOutput = handle
            p.standardError = handle
        }

        let spawnTime = Date()
        p.terminationHandler = { [weak self] terminated in
            self?.handleTermination(process: terminated, spawnTime: spawnTime)
        }
        try p.run()

        process = p
        startedAt = spawnTime
        isStopping = false
        runState = .running(pid: p.processIdentifier)
        Log.info("Sunshine 子进程已启动 pid=\(p.processIdentifier)")
    }

    private func handleTermination(process terminated: Process, spawnTime: Date) {
        queue.async { [weak self] in
            guard let self, self.process === terminated else { return }
            self.process = nil

            if self.isStopping {
                self.isStopping = false
                self.runState = .idle
                self.backoff.reset()
                Log.info("Sunshine 已停止")
                return
            }

            // 异常退出：稳定运行超过 120s 视为偶发，重置退避
            if Date().timeIntervalSince(spawnTime) > 120 {
                self.backoff.reset()
            }

            // Sunshine 保存配置时会 fork 新进程再退出旧进程——
            // 终止孤儿并由本 App 重新拉起，保持单实例与所有权
            let orphans = Self.findRunningSunshinePIDs(pattern: self.binPath)
            if !orphans.isEmpty {
                Log.info("Sunshine 自我 fork 检测：终止孤儿实例 \(orphans)")
                for pid in orphans {
                    Self.terminate(pid: pid, graceSeconds: 3)
                }
            }

            let retries = self.backoff.attempt
            let delay = self.backoff.nextDelay()
            self.runState = .crashed(retries: retries)
            Log.info("Sunshine 异常退出（code=\(terminated.terminationStatus)），\(Int(delay))s 后重启")
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.process == nil, !self.isStopping else { return }
                if case .crashed = self.runState {
                    _ = try? self.spawnLocked()
                }
            }
        }
    }

    /// 一次性迁移：解除 brew services 注册，防 brew upgrade 拉起双实例
    private func migrateAwayFromBrewServices() {
        guard let brew = BrewServicesSunshineManager.detectBrew() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = ["services", "stop", "sunshine"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            Log.info("brew services stop sunshine → 退出码 \(p.terminationStatus)")
        } catch {
            Log.error("brew services stop 失败：\(error.localizedDescription)")
        }
    }

    /// pgrep 找出全部运行中的 Sunshine 实例（含我们自己的子进程）
    static func findRunningSunshinePIDs(pattern: String) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", pattern]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) } ?? []
    }

    /// SIGTERM 宽限 → SIGKILL 兜底
    static func terminate(pid: pid_t, graceSeconds: TimeInterval) {
        guard kill(pid, SIGTERM) == 0 else { return }
        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }  // 已退出
            Thread.sleep(forTimeInterval: 0.1)
        }
        kill(pid, SIGKILL)
    }
}
