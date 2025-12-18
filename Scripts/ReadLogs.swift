#!/usr/bin/env swift
/// ReadLogs - A CLI tool to tail logs from InstantDB
///
/// ## Why This Exists
/// This tool allows you to view logs sent from iOS devices to InstantDB
/// in real-time from your terminal. This is invaluable for debugging
/// real-time features like presence and sync across multiple devices.
///
/// ## Usage
/// ```bash
/// # Show the last 100 logs
/// swift ReadLogs.swift --tail 100
///
/// # Show all logs from today
/// swift ReadLogs.swift --today
///
/// # Follow logs in real-time (like tail -f)
/// swift ReadLogs.swift --follow
///
/// # Filter by log level
/// swift ReadLogs.swift --level error --tail 50
///
/// # Filter by file
/// swift ReadLogs.swift --file SwiftUISyncDemo.swift --tail 50
/// ```
///
/// ## Configuration
/// Update the appID and adminKey constants below, or set environment variables:
/// - INSTANT_LOGGER_APP_ID
/// - INSTANT_LOGGER_ADMIN_KEY

import Foundation

// MARK: - Configuration

/// InstantDB App ID for the logging database.
let appID = ProcessInfo.processInfo.environment["INSTANT_LOGGER_APP_ID"]
  ?? "b9319949-2f2d-410b-8f8a-6990177c1d44"

/// Admin key for querying logs.
let adminKey = ProcessInfo.processInfo.environment["INSTANT_LOGGER_ADMIN_KEY"]
  ?? "3b5e84e8-d90d-4dd3-a127-1b7f3c91de8b"

/// InstantDB API endpoint
let apiEndpoint = "https://api.instantdb.com"

// MARK: - Log Entry

struct LogEntry: Codable {
  let id: String
  let level: String
  let message: String
  let jsonPayload: String?
  let file: String
  let line: Int
  let timestamp: Double
  let formattedDate: String
  let timezone: String
}

// MARK: - API Response

struct QueryResponse: Codable {
  let logs: [LogEntry]?
}

// MARK: - CLI Arguments

struct CLIArguments {
  var tail: Int = 100
  var follow: Bool = false
  var level: String? = nil
  var file: String? = nil
  var today: Bool = false
  var help: Bool = false
  
  static func parse(_ args: [String]) -> CLIArguments {
    var result = CLIArguments()
    var i = 1 // Skip program name
    
    while i < args.count {
      let arg = args[i]
      
      switch arg {
      case "--tail", "-n":
        if i + 1 < args.count, let count = Int(args[i + 1]) {
          result.tail = count
          i += 1
        }
      case "--follow", "-f":
        result.follow = true
      case "--level", "-l":
        if i + 1 < args.count {
          result.level = args[i + 1]
          i += 1
        }
      case "--file":
        if i + 1 < args.count {
          result.file = args[i + 1]
          i += 1
        }
      case "--today":
        result.today = true
      case "--help", "-h":
        result.help = true
      default:
        break
      }
      i += 1
    }
    
    return result
  }
}

// MARK: - Formatting

func levelEmoji(_ level: String) -> String {
  switch level.uppercased() {
  case "DEBUG": return "🔍"
  case "INFO": return "ℹ️"
  case "WARNING": return "⚠️"
  case "ERROR": return "❌"
  default: return "📝"
  }
}

func levelColor(_ level: String) -> String {
  switch level.uppercased() {
  case "DEBUG": return "\u{001B}[36m"   // Cyan
  case "INFO": return "\u{001B}[32m"    // Green
  case "WARNING": return "\u{001B}[33m" // Yellow
  case "ERROR": return "\u{001B}[31m"   // Red
  default: return "\u{001B}[0m"         // Reset
  }
}

let resetColor = "\u{001B}[0m"
let dimColor = "\u{001B}[2m"

func formatLog(_ log: LogEntry) -> String {
  let emoji = levelEmoji(log.level)
  let color = levelColor(log.level)
  
  var output = ""
  output += "\(dimColor)[\(log.formattedDate)]\(resetColor) "
  output += "\(emoji) \(color)[\(log.level)]\(resetColor) "
  output += "\(dimColor)[\(log.file):\(log.line)]\(resetColor) "
  output += log.message
  
  if let json = log.jsonPayload, !json.isEmpty {
    let indentedJson = json.split(separator: "\n").map { "    \($0)" }.joined(separator: "\n")
    output += "\n\(dimColor)  JSON:\(resetColor)\n\(indentedJson)"
  }
  
  return output
}

// MARK: - API

func fetchLogs(limit: Int, levelFilter: String?, fileFilter: String?, sinceTimestamp: Double?) async throws -> [LogEntry] {
  let urlString = "\(apiEndpoint)/runtime/query?app_id=\(appID)"
  
  // Build the query
  let query: [String: Any] = [
    "logs": [
      "$": [
        "order": ["serverCreatedAt": "desc"],
        "limit": limit
      ]
    ]
  ]
  
  guard let url = URL(string: urlString) else {
    throw NSError(domain: "ReadLogs", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
  }
  
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
  
  let queryData = try JSONSerialization.data(withJSONObject: query)
  request.httpBody = queryData
  
  let (data, response) = try await URLSession.shared.data(for: request)
  
  guard let httpResponse = response as? HTTPURLResponse else {
    throw NSError(domain: "ReadLogs", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
  }
  
  guard httpResponse.statusCode == 200 else {
    let body = String(data: data, encoding: .utf8) ?? "Unknown error"
    throw NSError(domain: "ReadLogs", code: httpResponse.statusCode, 
                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(body)"])
  }
  
  let decoder = JSONDecoder()
  let queryResponse = try decoder.decode(QueryResponse.self, from: data)
  
  var logs = queryResponse.logs ?? []
  
  // Client-side filtering
  if let levelFilter = levelFilter {
    logs = logs.filter { $0.level.uppercased() == levelFilter.uppercased() }
  }
  
  if let fileFilter = fileFilter {
    logs = logs.filter { $0.file.contains(fileFilter) }
  }
  
  if let sinceTimestamp = sinceTimestamp {
    logs = logs.filter { $0.timestamp > sinceTimestamp }
  }
  
  return logs
}

// MARK: - Help

func printHelp() {
  print("""
  ReadLogs - Tail logs from InstantDB
  
  USAGE:
    swift ReadLogs.swift [OPTIONS]
  
  OPTIONS:
    --tail, -n <count>    Number of recent logs to show (default: 100)
    --follow, -f          Follow logs in real-time (poll every 2 seconds)
    --level, -l <level>   Filter by log level (debug, info, warning, error)
    --file <filename>     Filter by source file name
    --today               Show only logs from today
    --help, -h            Show this help message
  
  EXAMPLES:
    swift ReadLogs.swift --tail 50
    swift ReadLogs.swift --follow
    swift ReadLogs.swift --level error --tail 100
    swift ReadLogs.swift --file SwiftUISyncDemo.swift
  
  CONFIGURATION:
    Set these environment variables or edit the script:
    - INSTANT_LOGGER_APP_ID: Your InstantDB app ID
    - INSTANT_LOGGER_ADMIN_KEY: Your admin key
  """)
}

// MARK: - Main Entry Point

func main() async {
  let args = CLIArguments.parse(CommandLine.arguments)
  
  if args.help {
    printHelp()
    return
  }
  
  // Calculate "today" timestamp if needed
  var sinceTimestamp: Double? = nil
  if args.today {
    let calendar = Calendar.current
    let startOfDay = calendar.startOfDay(for: Date())
    sinceTimestamp = startOfDay.timeIntervalSince1970 * 1000 // milliseconds
  }
  
  print("📋 ReadLogs - Fetching logs from InstantDB...")
  print("   App ID: \(appID)")
  print("")
  
  var seenIds = Set<String>()
  
  // Initial fetch
  do {
    let logs = try await fetchLogs(
      limit: args.tail,
      levelFilter: args.level,
      fileFilter: args.file,
      sinceTimestamp: sinceTimestamp
    )
    
    // Print in chronological order (oldest first)
    for log in logs.reversed() {
      seenIds.insert(log.id)
      print(formatLog(log))
    }
    
    if logs.isEmpty {
      print("No logs found.")
    } else {
      print("\n--- Showing \(logs.count) logs ---\n")
    }
  } catch {
    print("❌ Error fetching logs: \(error.localizedDescription)")
    return
  }
  
  // Follow mode
  if args.follow {
    print("👀 Following logs (Ctrl+C to stop)...\n")
    
    while true {
      try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
      
      do {
        let logs = try await fetchLogs(
          limit: 50, // Check recent logs
          levelFilter: args.level,
          fileFilter: args.file,
          sinceTimestamp: sinceTimestamp
        )
        
        // Print only new logs
        for log in logs.reversed() {
          if !seenIds.contains(log.id) {
            seenIds.insert(log.id)
            print(formatLog(log))
          }
        }
      } catch {
        print("⚠️ Error polling: \(error.localizedDescription)")
      }
    }
  }
}

// Run the async main function
Task {
  await main()
}

// Keep the script running for async code
RunLoop.main.run()
