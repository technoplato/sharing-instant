import Foundation
import os.log

// MARK: - SharingInstantInternalLog

/// Lightweight internal logging for SharingInstant.
///
/// ## Why This Exists
/// SharingInstant sometimes needs to log diagnostics that are useful during development
/// and integration testing (e.g., decoding failures from the triple store), but would be
/// too noisy if always printed to stdout.
///
/// This logger routes internal diagnostics through `os.Logger` and can be explicitly
/// enabled via environment variables.
enum SharingInstantInternalLog {
  enum Level: Int {
    case off = 0
    case error = 1
    case info = 2
    case debug = 3
  }

  private static let logger = os.Logger(subsystem: "SharingInstant", category: "Internal")

  static let level: Level = {
    let env = ProcessInfo.processInfo.environment

    if env["SHARINGINSTANT_DEBUG"] == "1" || env["INSTANTDB_DEBUG"] == "1" {
      return .debug
    }

    if let rawLevel = env["SHARINGINSTANT_LOG_LEVEL"]?.lowercased() {
      return parseLevel(rawLevel) ?? .error
    }

    if let rawLevel = env["INSTANTDB_LOG_LEVEL"]?.lowercased() {
      return parseLevel(rawLevel) ?? .error
    }

    return .error
  }()

  static func debug(_ message: @autoclosure () -> String) {
    guard level.rawValue >= Level.debug.rawValue else { return }
    let resolvedMessage = message()
    logger.debug("\(resolvedMessage, privacy: .public)")
  }

  static func info(_ message: @autoclosure () -> String) {
    guard level.rawValue >= Level.info.rawValue else { return }
    let resolvedMessage = message()
    logger.info("\(resolvedMessage, privacy: .public)")
  }

  static func warning(_ message: @autoclosure () -> String) {
    guard level.rawValue >= Level.error.rawValue else { return }
    let resolvedMessage = message()
    logger.warning("\(resolvedMessage, privacy: .public)")
  }

  static func error(_ message: @autoclosure () -> String) {
    guard level.rawValue >= Level.error.rawValue else { return }
    let resolvedMessage = message()
    logger.error("\(resolvedMessage, privacy: .public)")
  }

  private static func parseLevel(_ raw: String) -> Level? {
    switch raw {
    case "off", "none", "0":
      return .off
    case "error":
      return .error
    case "info":
      return .info
    case "debug":
      return .debug
    default:
      return nil
    }
  }
}

