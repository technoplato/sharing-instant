// GenerationContext.swift
// InstantSchemaCodegen
//
// Captures metadata about the generation environment for inclusion in headers.

import Foundation

// MARK: - Generation Context

/// Metadata about the generation environment, captured at code generation time.
///
/// This information is included in generated file headers to provide:
/// - Traceability back to the source schema and git state
/// - Reproducibility of the generation
/// - Debugging information when generated code doesn't match expectations
public struct GenerationContext: Sendable {
  
  // MARK: - Properties
  
  /// When the generation occurred
  public let generatedAt: Date
  
  /// The timezone of the machine running the generator
  public let timezone: TimeZone
  
  /// Information about the machine running the generator
  public let machine: MachineInfo
  
  /// Path to the generator executable (relative to repo root)
  public let generatorPath: String
  
  /// The full command that was issued to generate the code
  public let command: String
  
  /// Path to the source schema file (relative to repo root)
  public let sourceSchemaPath: String
  
  /// Path to the output directory (relative to repo root)
  public let outputDirectory: String
  
  /// Git state at the time of generation
  public let gitState: GitState
  
  // MARK: - Initialization
  
  public init(
    generatedAt: Date = Date(),
    timezone: TimeZone = .current,
    machine: MachineInfo,
    generatorPath: String,
    command: String,
    sourceSchemaPath: String,
    outputDirectory: String,
    gitState: GitState
  ) {
    self.generatedAt = generatedAt
    self.timezone = timezone
    self.machine = machine
    self.generatorPath = generatorPath
    self.command = command
    self.sourceSchemaPath = sourceSchemaPath
    self.outputDirectory = outputDirectory
    self.gitState = gitState
  }
  
  // MARK: - Formatted Output
  
  /// Returns a human-readable date string like "December 19, 2025 at 4:12 PM EST"
  public var formattedDate: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM d, yyyy 'at' h:mm a zzz"
    formatter.timeZone = timezone
    return formatter.string(from: generatedAt)
  }
}

// MARK: - Machine Info

/// Information about the machine running the generator.
public struct MachineInfo: Sendable {
  /// The computer's hostname (e.g., "mlustig-HY7L9XRD61")
  public let hostname: String
  
  /// The chip/processor (e.g., "Apple M4 Pro")
  public let chip: String
  
  /// The OS version (e.g., "macOS Tahoe 26.1")
  public let osVersion: String
  
  public init(hostname: String, chip: String, osVersion: String) {
    self.hostname = hostname
    self.chip = chip
    self.osVersion = osVersion
  }
  
  /// Capture machine info from the current system
  public static func current() -> MachineInfo {
    let hostname = ProcessInfo.processInfo.hostName
    let chip = getMacChip()
    let osVersion = getOSVersion()
    return MachineInfo(hostname: hostname, chip: chip, osVersion: osVersion)
  }
  
  /// Formatted string for display (e.g., "mlustig-HY7L9XRD61 (Apple M4 Pro, macOS Tahoe 26.1)")
  public var formatted: String {
    "\(hostname) (\(chip), \(osVersion))"
  }
}

// MARK: - Git State

/// Git state at the time of generation.
public struct GitState: Sendable {
  /// The HEAD commit
  public let headCommit: GitCommit
  
  /// The commit that last modified the schema file
  public let schemaLastModified: GitCommit
  
  public init(headCommit: GitCommit, schemaLastModified: GitCommit) {
    self.headCommit = headCommit
    self.schemaLastModified = schemaLastModified
  }
}

/// Information about a git commit.
public struct GitCommit: Sendable {
  /// The full SHA hash
  public let sha: String
  
  /// The commit date
  public let date: Date
  
  /// The commit author (name and email)
  public let author: String
  
  /// The commit message (first line)
  public let message: String
  
  public init(sha: String, date: Date, author: String, message: String) {
    self.sha = sha
    self.date = date
    self.author = author
    self.message = message
  }
  
  /// Formatted date string
  public func formattedDate(timezone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM d, yyyy 'at' h:mm a zzz"
    formatter.timeZone = timezone
    return formatter.string(from: date)
  }
}

// MARK: - Git Utilities

/// Errors that can occur during git operations.
public enum GitError: Error, LocalizedError {
  case dirtyWorkingDirectory(files: [String])
  case notAGitRepository
  case commandFailed(String)
  
  public var errorDescription: String? {
    switch self {
    case .dirtyWorkingDirectory(let files):
      let fileList = files.prefix(10).joined(separator: "\n  ")
      let moreCount = files.count > 10 ? "\n  ... and \(files.count - 10) more" : ""
      return """
        ❌ ERROR: Working directory has uncommitted changes.
        
        Code generation requires a clean git state to ensure generated code
        can be traced back to a specific commit.
        
        Uncommitted files:
          \(fileList)\(moreCount)
        
        Please commit your changes before running code generation:
          git add -A && git commit -m "Your commit message"
        """
    case .notAGitRepository:
      return "Not a git repository. Code generation requires git for traceability."
    case .commandFailed(let message):
      return "Git command failed: \(message)"
    }
  }
}

/// Utilities for interacting with git.
public enum GitUtilities {
  
  /// Check if the working directory is clean (no uncommitted changes).
  /// Throws `GitError.dirtyWorkingDirectory` if there are uncommitted changes.
  public static func ensureCleanWorkingDirectory() throws {
    let (output, exitCode) = runGitCommand(["status", "--porcelain"])
    
    guard exitCode == 0 else {
      throw GitError.notAGitRepository
    }
    
    let dirtyFiles = output.split(separator: "\n").map { String($0) }
    if !dirtyFiles.isEmpty {
      throw GitError.dirtyWorkingDirectory(files: dirtyFiles)
    }
  }
  
  /// Get information about the HEAD commit.
  public static func getHeadCommit() throws -> GitCommit {
    try getCommitInfo(ref: "HEAD")
  }
  
  /// Get information about the commit that last modified a file.
  public static func getLastModifyingCommit(forFile path: String) throws -> GitCommit {
    // Get the commit that last modified this file
    let (sha, exitCode) = runGitCommand(["log", "-1", "--format=%H", "--", path])
    guard exitCode == 0, !sha.isEmpty else {
      // If file hasn't been committed yet, use HEAD
      return try getHeadCommit()
    }
    return try getCommitInfo(ref: sha.trimmingCharacters(in: .whitespacesAndNewlines))
  }
  
  /// Get the repository root path.
  public static func getRepoRoot() -> String? {
    let (output, exitCode) = runGitCommand(["rev-parse", "--show-toplevel"])
    guard exitCode == 0 else { return nil }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  
  /// Convert an absolute path to a path relative to the repo root.
  public static func relativePath(from absolutePath: String) -> String {
    guard let repoRoot = getRepoRoot() else { return absolutePath }
    
    let absURL = URL(fileURLWithPath: absolutePath).standardized
    let rootURL = URL(fileURLWithPath: repoRoot).standardized
    
    let absPath = absURL.path
    let rootPath = rootURL.path
    
    if absPath.hasPrefix(rootPath) {
      var relative = String(absPath.dropFirst(rootPath.count))
      if relative.hasPrefix("/") {
        relative = String(relative.dropFirst())
      }
      return relative
    }
    return absolutePath
  }
  
  // MARK: - Private Helpers
  
  private static func getCommitInfo(ref: String) throws -> GitCommit {
    // Format: SHA|Unix timestamp|Author Name <email>|Subject
    let format = "%H|%at|%an <%ae>|%s"
    let (output, exitCode) = runGitCommand(["log", "-1", "--format=\(format)", ref])
    
    guard exitCode == 0 else {
      throw GitError.commandFailed("Could not get commit info for \(ref)")
    }
    
    let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", maxSplits: 3)
    guard parts.count >= 4 else {
      throw GitError.commandFailed("Unexpected git log output format")
    }
    
    let sha = String(parts[0])
    let timestamp = TimeInterval(parts[1]) ?? 0
    let author = String(parts[2])
    let message = String(parts[3])
    
    return GitCommit(
      sha: sha,
      date: Date(timeIntervalSince1970: timestamp),
      author: author,
      message: message
    )
  }
  
  private static func runGitCommand(_ arguments: [String]) -> (output: String, exitCode: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    
    do {
      try process.run()
      process.waitUntilExit()
      
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8) ?? ""
      
      return (output, process.terminationStatus)
    } catch {
      return ("", -1)
    }
  }
}

// MARK: - System Info Helpers

/// Get the Mac chip name (e.g., "Apple M4 Pro")
private func getMacChip() -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
  process.arguments = ["-n", "machdep.cpu.brand_string"]
  
  let pipe = Pipe()
  process.standardOutput = pipe
  
  do {
    try process.run()
    process.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !output.isEmpty {
      return output
    }
  } catch {}
  
  // Fallback: try to get chip from system_profiler
  let fallbackProcess = Process()
  fallbackProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
  fallbackProcess.arguments = ["SPHardwareDataType"]
  
  let fallbackPipe = Pipe()
  fallbackProcess.standardOutput = fallbackPipe
  
  do {
    try fallbackProcess.run()
    fallbackProcess.waitUntilExit()
    
    let data = fallbackPipe.fileHandleForReading.readDataToEndOfFile()
    if let output = String(data: data, encoding: .utf8) {
      // Look for "Chip:" line
      for line in output.split(separator: "\n") {
        if line.contains("Chip:") {
          let parts = line.split(separator: ":")
          if parts.count >= 2 {
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
          }
        }
      }
    }
  } catch {}
  
  return "Unknown"
}

/// Get the OS version string (e.g., "macOS Tahoe 26.1")
private func getOSVersion() -> String {
  let version = ProcessInfo.processInfo.operatingSystemVersion
  let versionString = "\(version.majorVersion).\(version.minorVersion)"
  
  // Try to get the marketing name
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
  process.arguments = ["-productName"]
  
  let pipe = Pipe()
  process.standardOutput = pipe
  
  do {
    try process.run()
    process.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let productName = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !productName.isEmpty {
      return "\(productName) \(versionString)"
    }
  } catch {}
  
  return "macOS \(versionString)"
}

