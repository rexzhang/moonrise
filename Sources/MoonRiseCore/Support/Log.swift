import Foundation
import os

/// 统一日志出口（Console.app 里按 subsystem 过滤）。
public enum Log {
    private static let logger = Logger(subsystem: "com.moonrise", category: "app")

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
