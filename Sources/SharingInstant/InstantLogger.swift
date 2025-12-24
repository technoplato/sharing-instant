// InstantLogger.swift
// SharingInstant
//
// A logger that syncs logs to InstantDB for remote debugging.
//
// ## Smart Deduplication
//
// The logger includes a smart deduplication system that prevents log spam from
// repeated identical messages. When the same message + JSON payload is logged
// multiple times in rapid succession:
//
// 1. The first occurrence is logged immediately
// 2. Subsequent identical messages within the deduplication window are suppressed
// 3. When a different message is logged, a summary is printed showing how many
//    times the previous message was repeated
//
// This is particularly useful for connection state changes and other events that
// may fire rapidly but only the transitions are meaningful.

import Dependencies
import Foundation
import IdentifiedCollections
import os.lock
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
    id: String = UUID().uuidString.lowercased(),
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
/// The logger is enabled by default with stdout and os.log output.
/// InstantDB sync is disabled by default to avoid performance impact.
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
///     // Logger defaults (no configuration needed for basic logging):
///     // - printToStdout: true (logs to Xcode console)
///     // - logToOSLog: true (logs to system log, tail with `log stream`)
///     // - syncToInstantDB: false (disabled by default)
///     
///     // Enable InstantDB sync only when you need remote debugging:
///     // InstantLoggerConfig.syncToInstantDB = true
///   }
/// }
/// ```
///
/// ## Tailing Logs from Terminal
///
/// With os.log enabled, you can tail logs from Terminal:
/// ```bash
/// log stream --predicate 'subsystem == "SharingInstant"' --level debug
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
  ///
  /// - Note: Uses `nonisolated(unsafe)` because this is a configuration flag
  ///   that is typically set once at app launch and then read-only.
  nonisolated(unsafe) public static var printToStdout = true
  
  /// Whether to log to os.log (system log).
  /// Default: true
  ///
  /// - Note: Uses `nonisolated(unsafe)` because this is a configuration flag
  ///   that is typically set once at app launch and then read-only.
  nonisolated(unsafe) public static var logToOSLog = true
  
  /// Whether to sync logs to InstantDB.
  /// Requires a "logs" namespace in your schema.
  /// Default: false (disabled to avoid performance impact on your real data)
  ///
  /// Enable this when you need remote debugging across devices:
  /// ```swift
  /// InstantLoggerConfig.syncToInstantDB = true
  /// ```
  ///
  /// - Note: Uses `nonisolated(unsafe)` because this is a configuration flag
  ///   that is typically set once at app launch and then read-only.
  nonisolated(unsafe) public static var syncToInstantDB = false
  
  /// Whether logging is enabled at all.
  /// Default: true
  ///
  /// - Note: Uses `nonisolated(unsafe)` because this is a configuration flag
  ///   that is typically set once at app launch and then read-only.
  nonisolated(unsafe) public static var isEnabled = true
  
  /// Whether smart deduplication is enabled.
  /// When true, identical consecutive log messages are suppressed and a count
  /// is shown when the message changes.
  /// Default: true
  ///
  /// - Note: Uses `nonisolated(unsafe)` because this is a configuration flag
  ///   that is typically set once at app launch and then read-only.
  nonisolated(unsafe) public static var deduplicationEnabled = true
  
  /// Time window (in seconds) for deduplication.
  /// Messages older than this are considered "new" even if identical.
  /// Default: 60 seconds
  ///
  /// - Note: Uses `nonisolated(unsafe)` because this is a configuration flag
  ///   that is typically set once at app launch and then read-only.
  nonisolated(unsafe) public static var deduplicationWindow: TimeInterval = 60.0
}

// MARK: - Log Deduplication Tracker

/// Tracks recent log messages to detect and suppress duplicates.
///
/// ## Why This Exists
/// Real-time systems like InstantDB often emit the same state repeatedly (e.g.,
/// connection state changes from CombineLatest publishers). This creates log spam
/// that obscures meaningful events.
///
/// ## Algorithm
/// 1. Each log message is fingerprinted by combining: message + jsonPayload + file + line
/// 2. When a log comes in, we check if it matches the previous fingerprint
/// 3. If it matches and is within the deduplication window, we suppress it and increment a counter
/// 4. When a different message arrives, we flush the suppressed count as a summary
///
/// ## Thread Safety
/// Uses `os_unfair_lock` for fast, thread-safe access to the tracking state.
final class LogDeduplicationTracker: @unchecked Sendable {
  
  struct TrackedMessage: Equatable {
    let fingerprint: String
    let level: LogLevel
    let message: String
    let jsonPayload: String?
    let file: String
    let line: Int
    let firstTimestamp: Date
    var count: Int
    
    /// Creates a fingerprint from the log components
    static func makeFingerprint(
      message: String,
      jsonPayload: String?,
      file: String,
      line: Int
    ) -> String {
      var hasher = Hasher()
      hasher.combine(message)
      hasher.combine(jsonPayload)
      hasher.combine(file)
      hasher.combine(line)
      return String(hasher.finalize())
    }
  }
  
  private var lastMessage: TrackedMessage?
  private let lock = os_unfair_lock_t.allocate(capacity: 1)
  
  init() {
    lock.initialize(to: os_unfair_lock())
  }
  
  deinit {
    lock.deinitialize(count: 1)
    lock.deallocate()
  }
  
  /// Result of checking a log message against the deduplication tracker.
  enum CheckResult {
    /// This is a new/different message. Log it and optionally flush the previous summary.
    case newMessage(suppressedSummary: SuppressedSummary?)
    /// This is a duplicate. Don't log it.
    case duplicate
  }
  
  /// Summary of suppressed duplicate messages.
  struct SuppressedSummary {
    let level: LogLevel
    let message: String
    let count: Int
    let duration: TimeInterval
  }
  
  /// Check if a log message should be logged or suppressed.
  ///
  /// - Parameters:
  ///   - level: The log level
  ///   - message: The log message
  ///   - jsonPayload: Optional JSON payload
  ///   - file: Source file
  ///   - line: Source line
  /// - Returns: Whether to log this message and any suppressed summary to flush
  func check(
    level: LogLevel,
    message: String,
    jsonPayload: String?,
    file: String,
    line: Int
  ) -> CheckResult {
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    
    let now = Date()
    let fingerprint = TrackedMessage.makeFingerprint(
      message: message,
      jsonPayload: jsonPayload,
      file: file,
      line: line
    )
    
    // Check if this matches the last message
    if let last = lastMessage {
      let age = now.timeIntervalSince(last.firstTimestamp)
      let withinWindow = age < InstantLoggerConfig.deduplicationWindow
      
      if last.fingerprint == fingerprint && withinWindow {
        // Same message within window - suppress it
        lastMessage?.count += 1
        return .duplicate
      } else {
        // Different message or outside window
        // Create summary if we suppressed any messages
        let summary: SuppressedSummary?
        if last.count > 1 {
          summary = SuppressedSummary(
            level: last.level,
            message: last.message,
            count: last.count,
            duration: age
          )
        } else {
          summary = nil
        }
        
        // Start tracking the new message
        lastMessage = TrackedMessage(
          fingerprint: fingerprint,
          level: level,
          message: message,
          jsonPayload: jsonPayload,
          file: file,
          line: line,
          firstTimestamp: now,
          count: 1
        )
        
        return .newMessage(suppressedSummary: summary)
      }
    } else {
      // First message ever
      lastMessage = TrackedMessage(
        fingerprint: fingerprint,
        level: level,
        message: message,
        jsonPayload: jsonPayload,
        file: file,
        line: line,
        firstTimestamp: now,
        count: 1
      )
      return .newMessage(suppressedSummary: nil)
    }
  }
  
  /// Reset the tracker, returning any pending summary.
  func reset() -> SuppressedSummary? {
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    
    guard let last = lastMessage, last.count > 1 else {
      lastMessage = nil
      return nil
    }
    
    let summary = SuppressedSummary(
      level: last.level,
      message: last.message,
      count: last.count,
      duration: Date().timeIntervalSince(last.firstTimestamp)
    )
    lastMessage = nil
    return summary
  }
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
  
  /// Deduplication tracker for suppressing repeated identical messages
  private static let deduplicationTracker = LogDeduplicationTracker()
  
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
    
    // Check deduplication if enabled
    if InstantLoggerConfig.deduplicationEnabled {
      let checkResult = deduplicationTracker.check(
        level: level,
        message: message,
        jsonPayload: jsonString,
        file: fileName,
        line: line
      )
      
      switch checkResult {
      case .duplicate:
        // Suppress this log - it's identical to the previous one
        return
        
      case .newMessage(let suppressedSummary):
        // Print summary of suppressed messages if any
        if let summary = suppressedSummary {
          printSuppressedSummary(summary)
        }
        // Continue to log the new message
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
      _ = $logs.withLock { logs in
        logs.insert(entry, at: 0)
      }
    }
  }
  
  /// Prints a summary of suppressed duplicate messages.
  private static func printSuppressedSummary(_ summary: LogDeduplicationTracker.SuppressedSummary) {
    let durationStr: String
    if summary.duration < 1 {
      durationStr = String(format: "%.0fms", summary.duration * 1000)
    } else if summary.duration < 60 {
      durationStr = String(format: "%.1fs", summary.duration)
    } else {
      durationStr = String(format: "%.1fm", summary.duration / 60)
    }
    
    let summaryMessage = "  ↳ (repeated \(summary.count)x over \(durationStr))"
    
    if InstantLoggerConfig.printToStdout {
      print(summaryMessage)
    }
    
    if InstantLoggerConfig.logToOSLog {
      osLogger.debug("\(summaryMessage)")
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
