import Foundation

// MARK: - Instant Epoch Timestamp

enum InstantEpochTimestamp {
  static func date(from raw: Double) -> Date {
    Date(timeIntervalSince1970: seconds(from: raw))
  }

  static func seconds(from raw: Double) -> Double {
    guard raw.isFinite else { return 0 }

    // InstantDB schemas often model timestamps as `number`.
    //
    // Some writers use Unix epoch seconds (`Date().timeIntervalSince1970`),
    // while others use Unix epoch milliseconds (`Date.now()` in JS).
    //
    // We recommend epoch milliseconds for parity with the TypeScript SDK.
    //
    // Treat anything that looks like milliseconds as ms and normalize to seconds.
    //
    // `10_000_000_000` seconds is ~2286-11-20, far beyond any realistic createdAt.
    if raw > 10_000_000_000 {
      return raw / 1_000
    }

    return raw
  }
}
