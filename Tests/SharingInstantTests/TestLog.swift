import Foundation

// MARK: - TestLog

/// Minimal test logging that can be enabled explicitly via environment variable.
///
/// ## Why This Exists
/// SwiftPM/XCTest output is shared between local development and CI. `print` statements are
/// useful while iterating, but they quickly drown out actionable failures when tests are
/// otherwise passing.
///
/// This helper keeps debugging output available, while making it opt-in:
/// - Set `INSTANT_TEST_VERBOSE=1` to enable.
enum TestLog {
  static let isEnabled = ProcessInfo.processInfo.environment["INSTANT_TEST_VERBOSE"] == "1"

  static func log(_ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    Swift.print(message())
  }
}

