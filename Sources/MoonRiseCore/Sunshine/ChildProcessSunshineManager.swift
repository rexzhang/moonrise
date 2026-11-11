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

/// 以子进程方式管理一个 Sunshine 实例（MoonRise 为父进程）：
/// 退出连带停止，异常退出退避重启；支持多实例（首屏主 conf + 扩展屏各自独立
/// conf/二进制副本/日志——D1/D13/D16）。
///
/// TCC 归属：子进程的屏幕捕获/辅助功能按"责任进程"归属 MoonRise.app，
/// 由 scripts/make-cert.sh 生成的自签代码签名证书（MoonRiseDev）保证
/// 跨重建稳定——ad-hoc 签名每次重建 cdhash 变化会导致授权失效。
/// 主实例走 /opt/homebrew/opt/sunshine/bin/sunshine（opt 稳定符号链接）。
public final class ChildProcessSunshineManager: SunshineManaging {

    public enum RunState: Equatable {
        case idle
        case running(pid: Int32)
        case crashed(retries: Int)
    }

    /// 实例名（日志与诊断区分用；首屏 = "Sunshine"，扩展屏 = 屏幕显示名）
    public let label: String

    private let queue = DispatchQueue(label: "com.moonrise.sunshine-child")
    private let binPath: String
    private let confPath: String
    private let logURL: URL
    private let hideTrayIcon: Bool

    private var process: Process?
    private var startedAt: Date?
    private var isStopping = false
    private var backoff = RestartBackoff()
    private var runState: RunState = .idle

    /// brew services 迁移为进程级一次性（多实例不再逐个执行）
    private static var brewMigrationDone = false
    private static let brewMigrationLock = NSLock()

    public init(binPath: String, confPath: String, logURL: URL, hideTrayIcon: Bool = true, label: String = "Sunshine") {
        self.binPath = binPath
        self.confPath = confPath
        self.logURL = logURL
        self.hideTrayIcon = hideTrayIcon
        self.label = label
        try? Paths.ensureParentDirectory(of: logURL)
    }

    // MARK: - SunshineManaging

    public func detect() -> SunshineInstallInfo? {
        BrewServicesSunshineManager.detectBinary().map { SunshineInstallInfo(binaryPath: $0) }
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
        ManagedProcessFamily.shared.remove(pid_t(victim.processIdentifier))
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

    private func startLocked() throws {
        if case .running = runState { return }  // 幂等
        Self.migrateAwayFromBrewServicesIfNeeded()
        // 外部实例清杀：排除 MoonRise 全家族（兄弟实例同路径副本属正常形态，D16）
        let foreign = ManagedProcessFamily.shared.foreign(from: SunshineProcessDiscovery.findCandidates())
        if !foreign.isEmpty {
            Log.info("[\(label)] 发现外部 Sunshine 实例 \(foreign)，终止后由本 App 接管")
            for pid in foreign {
                SunshineProcessDiscovery.terminate(pid: pid, graceSeconds: 3)
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

        ManagedProcessFamily.shared.add(pid_t(p.processIdentifier))
        process = p
        startedAt = spawnTime
        isStopping = false
        runState = .running(pid: p.processIdentifier)
        Log.info("[\(label)] Sunshine 子进程已启动 pid=\(p.processIdentifier)")
    }

    private func handleTermination(process terminated: Process, spawnTime: Date) {
        let terminatedPID = pid_t(terminated.processIdentifier)
        ManagedProcessFamily.shared.remove(terminatedPID)
        queue.async { [weak self] in
            guard let self, self.process === terminated else { return }
            self.process = nil

            if self.isStopping {
                self.isStopping = false
                self.runState = .idle
                self.backoff.reset()
                Log.info("[\(self.label)] Sunshine 已停止")
                return
            }

            // 异常退出：稳定运行超过 120s 视为偶发，重置退避
            if Date().timeIntervalSince(spawnTime) > 120 {
                self.backoff.reset()
            }

            // Sunshine 保存配置时会 fork 新进程再退出旧进程——
            // 终止孤儿（家族外的 sunshine 进程）并由本 App 重新拉起
            let orphans = ManagedProcessFamily.shared.foreign(from: SunshineProcessDiscovery.findCandidates())
            if !orphans.isEmpty {
                Log.info("[\(self.label)] Sunshine 自我 fork 检测：终止孤儿实例 \(orphans)")
                for pid in orphans {
                    SunshineProcessDiscovery.terminate(pid: pid, graceSeconds: 3)
                }
            }

            let retries = self.backoff.attempt
            let delay = self.backoff.nextDelay()
            self.runState = .crashed(retries: retries)
            Log.info("[\(self.label)] Sunshine 异常退出（code=\(terminated.terminationStatus)），\(Int(delay))s 后重启")
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.process == nil, !self.isStopping else { return }
                if case .crashed = self.runState {
                    _ = try? self.spawnLocked()
                }
            }
        }
    }

    /// 一次性迁移：解除 brew services 注册，防 brew upgrade 拉起双实例
    private static func migrateAwayFromBrewServicesIfNeeded() {
        brewMigrationLock.lock()
        defer { brewMigrationLock.unlock() }
        guard !brewMigrationDone else { return }
        brewMigrationDone = true
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
}
