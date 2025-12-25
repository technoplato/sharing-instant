import InstantDB
import XCTest

// MARK: - InstantTestAuth

/// Test-only authentication helpers for the Instant iOS SDK.
///
/// ## Why This Exists
/// The Instant iOS SDK sends its `init` message when the WebSocket opens, using the current
/// refresh token from `AuthManager`. For a brand-new app ID (like an ephemeral integration app),
/// there is no token yet, so `init` may be sent without authentication and never reach the
/// `.authenticated` connection state.
///
/// In tests we want a deterministic, explicit sequence:
/// 1. Sign in (guest) to obtain a refresh token.
/// 2. Reconnect so the `init` message is sent with that token.
/// 3. Await `.authenticated` before running assertions that require a hydrated backend session.
enum InstantTestAuth {

  // MARK: - Guest Auth

  /// Signs in as a guest, forces a reconnect, and waits for the WebSocket session to authenticate.
  @MainActor
  static func signInAsGuestAndReconnect(
    client: InstantClient,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    _ = try await client.authManager.signInAsGuest()

    client.disconnect()
    client.connect()

    try await waitForAuthenticated(client, timeout: timeout, file: file, line: line)
  }

  // MARK: - Connection Readiness

  /// Polls until the client reports an authenticated connection state.
  @MainActor
  static func waitForAuthenticated(
    _ client: InstantClient,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if client.connectionState == .authenticated { return }

      if case .error(let error) = client.connectionState {
        throw error
      }

      try await Task.sleep(nanoseconds: 100_000_000)
    }

    XCTFail("Timed out waiting for authenticated connection state.", file: file, line: line)
  }
}

