import Foundation
import XCTest

// MARK: - IntegrationTestGate

/// Centralizes opt-in gating for tests that hit the real InstantDB backend.
///
/// ## Why This Exists
/// SwiftPM runs `swift test` in many contexts (CI, local development, editor tooling).
/// Backend integration tests are valuable, but they are inherently non-deterministic:
///
/// - they require network access
/// - they depend on an external service being available
/// - they may mutate shared app IDs if not isolated
///
/// Making these suites opt-in keeps the default unit test run fast and reliable, while still
/// allowing developers to run the full backend suite explicitly.
enum IntegrationTestGate {
  static func requireEnabled(
    envVar: String = "INSTANT_RUN_INTEGRATION_TESTS",
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    guard ProcessInfo.processInfo.environment[envVar] == "1" else {
      throw XCTSkip(
        "Backend integration tests are disabled (set \(envVar)=1, or use INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS=1)."
      )
    }
  }

  static func requireEphemeralEnabled(
    envVar: String = "INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS",
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    guard ProcessInfo.processInfo.environment[envVar] == "1" else {
      throw XCTSkip(
        """
        Ephemeral backend integration tests are disabled.

        Set `\(envVar)=1` to run tests that create a fresh InstantDB app on each run via \
        `/dash/apps/ephemeral`.
        """
      )
    }
  }
}
