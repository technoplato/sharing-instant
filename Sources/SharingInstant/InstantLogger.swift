// InstantLogger.swift
// SharingInstant
//
// A logger that syncs logs to InstantDB for remote debugging.

import Dependencies
import Foundation
import IdentifiedCollections
import os.log
import Sharing

// MARK: - Log Level

/// Log levels for categorizing log messages.
public enum LogLevel: String, Codable, Sendable, CaseIterable {
  case debug = "DEBUG"
  case info = "INFO"
  case warning = "WARNING"
  case error = "ERROR"
  
  var osLogType: OSLogType {
    switch self {
    case .debug: return .debug
    case .info: return .info
    case .warning: return .default
    case .error: return .error
    }
  }
  
  public var emoji: String {
    switch self {
    case .debug: return "🔍"
    case .info: return "ℹ️"
    case .warning: return "⚠️"
    case .error: return "❌"
    }
  }
}

// MARK: - Log Entry

/// A log entry that can be synced to InstantDB.
///
/// ## Why This Exists
/// This struct provides a structured way to capture logs from the iOS app
/// and sync them to InstantDB for remote debugging. Each log entry captures:
/// - The log level (debug, info, warning, error)
/// - The message and optional JSON payload
/// - Source file and line number for traceability
/// - A human-readable timestamp in the device's timezone
///
/// ## Schema Requirements
/// To use InstantLogger, add a "logs" namespace to your InstantDB schema:
///
/// ```typescript
/// // instant.schema.ts
/// const logs = i.entity("logs", {
///   level: i.string(),
///   message: i.string(),
///   jsonPayload: i.string().optional(),
///   file: i.string(),
///   line: i.number(),
///   timestamp: i.date(),
///   formattedDate: i.string(),
///   timezone: i.string(),
/// });
/// ```
public struct LogEntry: Codable, EntityIdentifiable, Sendable, Equatable {
  public static var namespace: String { "logs" }
  
  public var id: String
  public var level: String
  public var message: String
  public var jsonPayload: String?
  public var file: String
  public var line: Int
  public var timestamp: Date
  public var formattedDate: String
  public var timezone: String
  
  public init(
    id: String = UUID().uuidString,
    level: LogLevel,
    message: String,
    jsonPayload: String? = nil,
    file: String,
    line: Int,
    timestamp: Date = Date()
  ) {
    self.id = id
    self.level = level.rawValue
    self.message = message
    self.jsonPayload = jsonPayload
    self.file = file
    self.line = line
    self.timestamp = timestamp
    
    // Format: "Thursday, December 18, 3:14 AM EST"
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d, h:mm a zzz"
    formatter.timeZone = TimeZone.current
    self.formattedDate = formatter.string(from: timestamp)
    self.timezone = TimeZone.current.identifier
  }
}

// MARK: - Logger Configuration

/// Configuration for the InstantDB logger.
///
/// ## Setup
///
/// Configure the logger early in your app's lifecycle:
///
/// ```swift
/// @main
/// struct MyApp: App {
///   init() {
///     // Configure InstantDB app ID (required for all SharingInstant features)
///     prepareDependencies {
///       $0.instantAppID = "your-app-id"
///     }
///     
///     // Optional: Configure logger behavior
///     InstantLoggerConfig.printToStdout = true
///     InstantLoggerConfig.logToOSLog = true
///     InstantLoggerConfig.syncToInstantDB = true
///   }
/// }
/// ```
///
/// ## Schema Requirements
///
/// Add a "logs" namespace to your InstantDB schema:
///
/// ```typescript
/// // instant.schema.ts
/// const logs = i.entity("logs", {
///   level: i.string(),
///   message: i.string(),
///   jsonPayload: i.string().optional(),
///   file: i.string(),
///   line: i.number(),
///   timestamp: i.date(),
///   formattedDate: i.string(),
///   timezone: i.string(),
/// });
/// ```
///
/// Then push the schema:
/// ```bash
/// npx instant-cli@latest push schema
/// ```
public struct InstantLoggerConfig {
  /// Whether to print logs to stdout (using print()).
  /// Default: true
  public static var printToStdout = true
  
  /// Whether to log to os.log (system log).
  /// Default: true
  public static var logToOSLog = true
  
  /// Whether to sync logs to InstantDB.
  /// Requires a "logs" namespace in your schema.
  /// Default: true
  public static var syncToInstantDB = true
  
  /// Whether logging is enabled at all.
  /// Default: true
  public static var isEnabled = true
}

// MARK: - Logger

/// A logger that sends logs to InstantDB for remote debugging.
///
/// ## Why This Exists
/// Debugging real-time features like presence and sync is challenging because:
/// 1. Issues often occur on real devices, not simulators
/// 2. Multiple devices need to be coordinated
/// 3. Timing-sensitive bugs are hard to reproduce
///
/// By logging to InstantDB, we can:
/// - View logs from multiple devices in one place
/// - Tail logs in real-time from a CLI tool
/// - Correlate events across devices by timestamp
///
/// ## Usage
///
/// ```swift
/// // Basic logging
/// InstantLogger.info("User tapped button")
/// InstantLogger.debug("State changed", json: ["count": 42])
/// InstantLogger.error("Connection failed", error: someError)
///
/// // Convenience methods
/// InstantLogger.viewAppeared("HomeScreen")
/// InstantLogger.userAction("tapped_button", details: ["buttonId": "submit"])
/// InstantLogger.stateChanged("counter", from: 0, to: 1)
/// ```
///
/// ## Default Arguments
/// The `file` and `line` parameters use `#file` and `#line` macros as defaults,
/// so they're captured automatically at the call site.
@MainActor
public final class InstantLogger {
  
  // MARK: - Shared State
  
  /// The shared log entries synced to InstantDB.
  @Shared(
    .instantSync(
      configuration: SharingInstantSync.CollectionConfiguration<LogEntry>(
        namespace: "logs",
        orderBy: OrderBy.desc("timestamp")
      )
    )
  )
  private static var logs: IdentifiedArrayOf<LogEntry> = []
  
  /// OS Logger for system logging
  private static let osLogger = os.Logger(subsystem: "SharingInstant", category: "Logger")
  
  // MARK: - Public API
  
  /// Log a debug message.
  ///
  /// Debug logs are for detailed information useful during development.
  /// They are typically filtered out in production.
  ///
  /// - Parameters:
  ///   - message: The log message.
  ///   - json: Optional JSON payload to include with the log.
  ///   - file: The source file (defaults to #file).
  ///   - line: The source line (defaults to #line).
  public static func debug(
    _ message: String,
    json: [String: Any]? = nil,
    file: String = #file,
    line: Int = #line
  ) {
    log(level: .debug, message: message, json: json, file: file, line: line)
  }
  
  /// Log an info message.
  ///
  /// Info logs are for general information about app operation.
  /// Use these for significant events like user actions or state changes.
  ///
  /// - Parameters:
  ///   - message: The log message.
  ///   - json: Optional JSON payload to include with the log.
  ///   - file: The source file (defaults to #file).
  ///   - line: The source line (defaults to #line).
  public static func info(
    _ message: String,
    json: [String: Any]? = nil,
    file: String = #file,
    line: Int = #line
  ) {
    log(level: .info, message: message, json: json, file: file, line: line)
  }
  
  /// Log a warning message.
  ///
  /// Warning logs indicate potential issues that don't prevent operation
  /// but should be investigated.
  ///
  /// - Parameters:
  ///   - message: The log message.
  ///   - json: Optional JSON payload to include with the log.
  ///   - file: The source file (defaults to #file).
  ///   - line: The source line (defaults to #line).
  public static func warning(
    _ message: String,
    json: [String: Any]? = nil,
    file: String = #file,
    line: Int = #line
  ) {
    log(level: .warning, message: message, json: json, file: file, line: line)
  }
  
  /// Log an error message.
  ///
  /// Error logs indicate failures that affect app functionality.
  /// These should always be investigated.
  ///
  /// - Parameters:
  ///   - message: The log message.
  ///   - json: Optional JSON payload to include with the log.
  ///   - file: The source file (defaults to #file).
  ///   - line: The source line (defaults to #line).
  public static func error(
    _ message: String,
    json: [String: Any]? = nil,
    file: String = #file,
    line: Int = #line
  ) {
    log(level: .error, message: message, json: json, file: file, line: line)
  }
  
  /// Log an error with an Error object.
  ///
  /// Convenience method that extracts error information automatically.
  ///
  /// - Parameters:
  ///   - message: The log message.
  ///   - error: The error to log.
  ///   - file: The source file (defaults to #file).
  ///   - line: The source line (defaults to #line).
  public static func error(
    _ message: String,
    error: Error,
    file: String = #file,
    line: Int = #line
  ) {
    let json: [String: Any] = [
      "errorType": String(describing: type(of: error)),
      "errorDescription": error.localizedDescription,
    ]
    log(level: .error, message: message, json: json, file: file, line: line)
  }
  
  // MARK: - Private Implementation
  
  private static func log(
    level: LogLevel,
    message: String,
    json: [String: Any]?,
    file: String,
    line: Int
  ) {
    guard InstantLoggerConfig.isEnabled else { return }
    
    // Extract just the filename from the full path
    let fileName = (file as NSString).lastPathComponent
    
    // Convert JSON to string if provided
    var jsonString: String? = nil
    if let json = json {
      if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
         let string = String(data: data, encoding: .utf8) {
        jsonString = string
      }
    }
    
    // Create the log entry
    let entry = LogEntry(
      level: level,
      message: message,
      jsonPayload: jsonString,
      file: fileName,
      line: line
    )
    
    // Format for stdout/os.log
    let formattedMessage = formatLogMessage(entry: entry, level: level)
    
    // Print to stdout if enabled
    if InstantLoggerConfig.printToStdout {
      print(formattedMessage)
    }
    
    // Log to os.log if enabled
    if InstantLoggerConfig.logToOSLog {
      osLogger.log(level: level.osLogType, "\(formattedMessage)")
    }
    
    // Send to InstantDB if enabled
    if InstantLoggerConfig.syncToInstantDB {
      $logs.withLock { logs in
        logs.insert(entry, at: 0)
      }
    }
  }
  
  private static func formatLogMessage(entry: LogEntry, level: LogLevel) -> String {
    var parts: [String] = []
    parts.append("[\(entry.formattedDate)]")
    parts.append(level.emoji)
    parts.append("[\(level.rawValue)]")
    parts.append("[\(entry.file):\(entry.line)]")
    parts.append(entry.message)
    
    var result = parts.joined(separator: " ")
    
    if let json = entry.jsonPayload {
      result += "\n  JSON: \(json.replacingOccurrences(of: "\n", with: "\n  "))"
    }
    
    return result
  }
}

// MARK: - Convenience Extensions

extension InstantLogger {
  
  /// Log a view appearing.
  public static func viewAppeared(
    _ viewName: String,
    file: String = #file,
    line: Int = #line
  ) {
    info("View appeared: \(viewName)", file: file, line: line)
  }
  
  /// Log a view disappearing.
  public static func viewDisappeared(
    _ viewName: String,
    file: String = #file,
    line: Int = #line
  ) {
    info("View disappeared: \(viewName)", file: file, line: line)
  }
  
  /// Log a user action.
  public static func userAction(
    _ action: String,
    details: [String: Any]? = nil,
    file: String = #file,
    line: Int = #line
  ) {
    info("User action: \(action)", json: details, file: file, line: line)
  }
  
  /// Log a state change.
  public static func stateChanged(
    _ description: String,
    from: Any? = nil,
    to: Any? = nil,
    file: String = #file,
    line: Int = #line
  ) {
    var json: [String: Any] = [:]
    if let from = from {
      json["from"] = String(describing: from)
    }
    if let to = to {
      json["to"] = String(describing: to)
    }
    debug("State changed: \(description)", json: json.isEmpty ? nil : json, file: file, line: line)
  }
  
  /// Log data received from the server.
  public static func dataReceived(
    _ description: String,
    count: Int? = nil,
    details: [String: Any]? = nil,
    file: String = #file,
    line: Int = #line
  ) {
    var json = details ?? [:]
    if let count = count {
      json["count"] = count
    }
    info("Data received: \(description)", json: json.isEmpty ? nil : json, file: file, line: line)
  }
  
  /// Log presence update.
  public static func presenceUpdate(
    _ description: String,
    peerCount: Int? = nil,
    details: [String: Any]? = nil,
    file: String = #file,
    line: Int = #line
  ) {
    var json = details ?? [:]
    if let peerCount = peerCount {
      json["peerCount"] = peerCount
    }
    debug("Presence: \(description)", json: json.isEmpty ? nil : json, file: file, line: line)
  }
  
  /// Log a connection state change.
  public static func connectionStateChanged(
    _ state: InstantConnectionState,
    file: String = #file,
    line: Int = #line
  ) {
    switch state {
    case .disconnected:
      info("Connection: Disconnected", file: file, line: line)
    case .connecting:
      debug("Connection: Connecting...", file: file, line: line)
    case .connected:
      debug("Connection: Connected, authenticating...", file: file, line: line)
    case .authenticated(let session):
      info(
        "Connection: Authenticated",
        json: [
          "sessionID": session.sessionID,
          "isGuest": session.isGuest,
          "attributeCount": session.attributeCount
        ],
        file: file,
        line: line
      )
    case .error(let error):
      self.error(
        "Connection: Error",
        json: [
          "isSSLError": error.isSSLError,
          "description": error.localizedDescription
        ],
        file: file,
        line: line
      )
    }
  }
}
