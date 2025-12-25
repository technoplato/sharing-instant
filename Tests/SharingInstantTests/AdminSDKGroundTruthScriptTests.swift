import Foundation
import XCTest

// MARK: - AdminSDKGroundTruthScriptTests

/// Validates InstantDB backend behavior using the JavaScript Admin SDK "ground truth" scripts.
///
/// ## Why This Exists
/// When diagnosing Swift-side sync and query issues, it's easy to misattribute failures:
/// - A Swift decode/cache/reconciliation bug can look like “the backend lost my link”.
/// - A backend ordering/broadcast problem can look like “the Swift client is flaky”.
///
/// The scripts in `../scripts` query InstantDB directly via `@instantdb/admin`, which makes them
/// a reliable, independent source of truth for "what the backend returns".
///
/// These tests run the scripts in `--ephemeral` mode so they:
/// - do not require credentials
/// - do not mutate shared app IDs
/// - produce deterministic, isolated results per run
final class AdminSDKGroundTruthScriptTests: XCTestCase {
  private struct ScriptOutput: Decodable {
    struct Assertions: Decodable {
      let ok: Bool
      let failures: [String]
    }

    let assertions: Assertions
  }

  // MARK: - Tests

  func testMicroblogGroundTruthScriptPasses() throws {
    try Self.requireEphemeralIntegrationEnabled()

    let output = try Self.runBun(
      args: [
        "run",
        "gt:microblog",
        "--",
        "--ephemeral",
        "--seed",
        "--assert",
        "--json",
        "--settle-timeout-ms",
        "15000",
      ]
    )

    let decoded = try JSONDecoder().decode(ScriptOutput.self, from: output.stdout)
    XCTAssertTrue(decoded.assertions.ok, decoded.assertions.failures.joined(separator: "\n"))
  }

  func testTodosGroundTruthScriptPasses() throws {
    try Self.requireEphemeralIntegrationEnabled()

    let output = try Self.runBun(
      args: [
        "run",
        "gt:todos",
        "--",
        "--ephemeral",
        "--seed",
        "--mutate",
        "--assert",
        "--json",
        "--settle-timeout-ms",
        "15000",
      ]
    )

    let decoded = try JSONDecoder().decode(ScriptOutput.self, from: output.stdout)
    XCTAssertTrue(decoded.assertions.ok, decoded.assertions.failures.joined(separator: "\n"))
  }

  func testTileGameGroundTruthScriptPasses() throws {
    try Self.requireEphemeralIntegrationEnabled()

    let output = try Self.runBun(
      args: [
        "run",
        "gt:tile-game",
        "--",
        "--ephemeral",
        "--seed",
        "--assert",
        "--json",
        "--board-size",
        "4",
        "--settle-timeout-ms",
        "15000",
      ]
    )

    let decoded = try JSONDecoder().decode(ScriptOutput.self, from: output.stdout)
    XCTAssertTrue(decoded.assertions.ok, decoded.assertions.failures.joined(separator: "\n"))
  }

  // MARK: - Helpers

  private struct ProcessOutput {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
  }

  private static func requireEphemeralIntegrationEnabled(
    envVar: String = "INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS"
  ) throws {
    if ProcessInfo.processInfo.environment[envVar] != "1" {
      throw XCTSkip(
        """
        Admin SDK ground-truth script tests are disabled.

        Set `\(envVar)=1` to run tests that create fresh ephemeral InstantDB apps and \
        validate backend behavior via `@instantdb/admin`.
        """
      )
    }
  }

  private static func runBun(args: [String]) throws -> ProcessOutput {
    let scriptsDir = repoRootURL().appendingPathComponent("scripts", isDirectory: true)
    let envURL = URL(fileURLWithPath: "/usr/bin/env")

    let process = Process()
    process.executableURL = envURL
    process.arguments = ["bun"] + args
    process.currentDirectoryURL = scriptsDir

    var environment = ProcessInfo.processInfo.environment
    environment["BUN_DISABLE_TELEMETRY"] = "1"
    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      try process.run()
    } catch {
      throw XCTSkip(
        """
        Failed to execute bun.

        Expected `bun` to be installed and available on PATH.
        Error: \(error)
        """
      )
    }

    process.waitUntilExit()

    let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let exitCode = process.terminationStatus

    if exitCode != 0 {
      let stderrString = String(data: stderr, encoding: .utf8) ?? "<non-utf8>"
      let stdoutString = String(data: stdout, encoding: .utf8) ?? "<non-utf8>"
      XCTFail(
        """
        Ground-truth script failed (exit code \(exitCode)).

        Command:
          bun \(args.joined(separator: " "))

        Stdout:
        \(stdoutString)

        Stderr:
        \(stderrString)
        """
      )

      struct ScriptFailed: Error {}
      throw ScriptFailed()
    }

    return ProcessOutput(stdout: stdout, stderr: stderr, exitCode: exitCode)
  }

  private static func repoRootURL(filePath: StaticString = #filePath) -> URL {
    let fileURL = URL(fileURLWithPath: String(describing: filePath))
    let sharingInstantDir = fileURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    return sharingInstantDir.deletingLastPathComponent()
  }
}
