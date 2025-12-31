// GenerationContext.swift
// InstantSchemaCodegen
//
// Captures metadata about the generation environment for inclusion in headers.

import Foundation

// MARK: - Generation Mode

/// The mode under which code generation is running.
///
/// Each mode has different requirements and produces different header metadata:
/// - `.production`: Full traceability with git state, requires clean working directory
/// - `.sample`: Quick start generation, no git requirements
/// - `.plugin`: SPM build plugin, automatic regeneration on schema changes
public enum GenerationMode: Sendable {
  
  /// Production generation from the CLI `generate` command.
  ///
  /// Requires:
  /// - Clean git working directory
  /// - Full git state tracking (HEAD commit, schema last modified)
  ///
  /// Use this for:
  /// - Generating code that will be committed to version control
  /// - CI/CD pipelines
  /// - Any situation where traceability is important
  case production(ProductionContext)
  
  /// Sample generation from the CLI `sample` command.
  ///
  /// No git requirements - designed for quick start and experimentation.
  ///
  /// Use this for:
  /// - Getting started with sharing-instant
  /// - Generating example types to explore the API
  /// - Tutorials and documentation
  case sample(SampleContext)
  
  /// Plugin generation from the SPM build plugin.
  ///
  /// Automatic regeneration on every build when schema changes.
  ///
  /// Use this for:
  /// - Development workflow where types auto-update
  /// - Projects using the InstantSchemaPlugin
  case plugin(PluginContext)
}

/// Context for production generation (full traceability).
public struct ProductionContext: Sendable {
  /// Git state at the time of generation
  public let gitState: GitState
  
  /// The full command that was issued
  public let command: String
  
  public init(gitState: GitState, command: String) {
    self.gitState = gitState
    self.command = command
  }
}

/// Context for sample generation (quick start, no git).
public struct SampleContext: Sendable {
  /// Description of what sample was generated
  public let description: String
  
  public init(description: String = "Sample schema for sharing-instant quick start") {
    self.description = description
  }
}

/// Context for SPM build plugin generation.
public struct PluginContext: Sendable {
  /// The plugin that triggered generation
  public let pluginName: String
  
  /// The target being built
  public let targetName: String
  
  public init(pluginName: String = "InstantSchemaPlugin", targetName: String) {
    self.pluginName = pluginName
    self.targetName = targetName
  }
}

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
  
  /// Path to the generator (relative to repo root or plugin name)
  public let generatorPath: String
  
  /// Path to the source schema file (relative to repo root)
  public let sourceSchemaPath: String
  
  /// Path to the output directory (relative to repo root)
  public let outputDirectory: String
  
  /// The generation mode with its associated context
  public let mode: GenerationMode
  
  // MARK: - Initialization
  
  public init(
    generatedAt: Date = Date(),
    timezone: TimeZone = .current,
    machine: MachineInfo,
    generatorPath: String,
    sourceSchemaPath: String,
    outputDirectory: String,
    mode: GenerationMode
  ) {
    self.generatedAt = generatedAt
    self.timezone = timezone
    self.machine = machine
    self.generatorPath = generatorPath
    self.sourceSchemaPath = sourceSchemaPath
    self.outputDirectory = outputDirectory
    self.mode = mode
  }
  
  // MARK: - Convenience Accessors
  
  /// The command string (for production mode) or a description of the generation
  public var commandOrDescription: String {
    switch mode {
    case .production(let ctx):
      return ctx.command
    case .sample(let ctx):
      return "swift run instant-schema sample  // \(ctx.description)"
    case .plugin(let ctx):
      return "SPM Build Plugin: \(ctx.pluginName) (target: \(ctx.targetName))"
    }
  }
  
  /// Git state if available (only for production mode)
  public var gitState: GitState? {
    switch mode {
    case .production(let ctx):
      return ctx.gitState
    case .sample, .plugin:
      return nil
    }
  }
  
  /// Whether this is a production build with full traceability
  public var isProduction: Bool {
    if case .production = mode { return true }
    return false
  }
  
  // MARK: - Formatted Output
  
  /// Returns a human-readable date string like "December 19, 2025 at 4:12 PM EST"
  public var formattedDate: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM d, yyyy 'at' h:mm a zzz"
    formatter.timeZone = timezone
    return formatter.string(from: generatedAt)
  }
  
  /// A short description of the generation mode for headers
  public var modeDescription: String {
    switch mode {
    case .production:
      return "Production (full traceability)"
    case .sample:
      return "Sample (quick start)"
    case .plugin:
      return "SPM Build Plugin (auto-regeneration)"
    }
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
  case dirtySchemaFile(file: String, status: String)
  case dirtyOutputFiles(files: [String])
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
    case .dirtySchemaFile(let file, let status):
      return """
        ❌ ERROR: Schema file has uncommitted changes.
        
        The input schema file must be committed so that generated code
        can be traced back to a specific version of the schema.
        
        Dirty file: \(file)
        Status: \(status)
        
        Please commit your schema changes before running code generation:
          git add \(file) && git commit -m "Update schema"
        """
    case .dirtyOutputFiles(let files):
      let fileList = files.prefix(10).joined(separator: "\n  ")
      let moreCount = files.count > 10 ? "\n  ... and \(files.count - 10) more" : ""
      return """
        ❌ ERROR: Output directory has uncommitted changes.
        
        The output files have uncommitted changes that would be overwritten.
        
        Dirty files:
          \(fileList)\(moreCount)
        
        Please commit or discard your changes before running code generation:
          git add <files> && git commit -m "Your commit message"
        Or to discard:
          git checkout -- <files>
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
  
  /// Check if a specific file is committed and not dirty.
  ///
  /// ## Why This Exists
  /// When generating code from a schema file, we need to ensure the schema
  /// is committed so that the generated code can be traced back to a specific
  /// version of the schema. This allows other developers to understand exactly
  /// what schema produced the generated code.
  ///
  /// - Parameter path: Path to the file to check (absolute or relative)
  /// - Throws: `GitError.dirtySchemaFile` if the file has uncommitted changes
  public static func ensureFileIsClean(_ path: String) throws {
    let relativePath = GitUtilities.relativePath(from: path)
    let (output, exitCode) = runGitCommand(["status", "--porcelain", "--", relativePath])
    
    guard exitCode == 0 else {
      throw GitError.notAGitRepository
    }
    
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      // Parse the status code (first 2 characters)
      // e.g., "M  file.ts" = modified, "?? file.ts" = untracked
      let status = String(trimmed.prefix(2)).trimmingCharacters(in: .whitespaces)
      let statusDescription: String
      switch status {
      case "M":
        statusDescription = "modified (staged)"
      case " M":
        statusDescription = "modified (unstaged)"
      case "MM":
        statusDescription = "modified (staged and unstaged)"
      case "A":
        statusDescription = "added (staged)"
      case "??":
        statusDescription = "untracked (not committed)"
      case "D":
        statusDescription = "deleted"
      default:
        statusDescription = "has changes (\(status))"
      }
      throw GitError.dirtySchemaFile(file: relativePath, status: statusDescription)
    }
  }
  
  /// Check if any files in a directory have uncommitted changes.
  ///
  /// ## Why This Exists
  /// Before overwriting generated files, we check that the output directory
  /// doesn't have uncommitted changes. This prevents accidentally losing
  /// manual edits that haven't been committed yet.
  ///
  /// - Parameter directory: Path to the directory to check
  /// - Throws: `GitError.dirtyOutputFiles` if any files in the directory are dirty
  public static func ensureDirectoryIsClean(_ directory: String) throws {
    let relativePath = GitUtilities.relativePath(from: directory)
    
    // Use trailing slash to match directory contents
    let pathPattern = relativePath.hasSuffix("/") ? relativePath : relativePath + "/"
    let (output, exitCode) = runGitCommand(["status", "--porcelain", "--", pathPattern])
    
    guard exitCode == 0 else {
      throw GitError.notAGitRepository
    }
    
    let dirtyFiles = output.split(separator: "\n")
      .map { String($0) }
      .filter { !$0.isEmpty }
    
    if !dirtyFiles.isEmpty {
      throw GitError.dirtyOutputFiles(files: dirtyFiles)
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

