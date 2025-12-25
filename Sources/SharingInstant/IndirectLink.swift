import Foundation

// MARK: - IndirectLinkStorage

fileprivate indirect enum IndirectLinkStorage<Value> {
  case value(Value)

  var value: Value {
    switch self {
    case let .value(value):
      return value
    }
  }
}

extension IndirectLinkStorage: Sendable where Value: Sendable {}

// MARK: - IndirectLink

/// Stores an optional linked entity indirectly to avoid recursive value-type cycles.
///
/// ## Why This Exists
/// InstantSchemaCodegen generates entity types as Swift `struct`s for strong value
/// semantics and easy integration with SwiftUI and `IdentifiedCollections`.
///
/// When an InstantDB schema includes a has-one cycle (for example `Segment.parent`
/// linking back to `Segment`), a naïve generated property:
///
/// ```swift
/// public var parent: Segment?
/// ```
///
/// will not compile because `Optional` stores its payload inline and the compiler
/// rejects value types that (recursively) contain themselves.
///
/// `@IndirectLink` breaks that cycle by keeping the public API as `Entity?`, while
/// storing the value behind an `indirect` enum.
///
/// ## When It's Used
/// The `instant-schema generate` command applies `@IndirectLink` automatically for
/// has-one links that participate in a cycle. You generally do not need to add it
/// manually.
@propertyWrapper
public struct IndirectLink<Value> {
  private var storage: IndirectLinkStorage<Value>?

  // MARK: - Wrapped Value

  public var wrappedValue: Value? {
    get { storage?.value }
    set { storage = newValue.map(IndirectLinkStorage.value) }
  }

  // MARK: - Initialization

  public init(wrappedValue: Value? = nil) {
    self.storage = wrappedValue.map(IndirectLinkStorage.value)
  }
}

// MARK: - Codable

extension IndirectLink: Codable where Value: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self.storage = nil
      return
    }

    self.storage = .value(try container.decode(Value.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()

    guard let storage else {
      try container.encodeNil()
      return
    }

    try container.encode(storage.value)
  }
}

// MARK: - Conformances

extension IndirectLink: Equatable where Value: Equatable {
  public static func == (lhs: IndirectLink<Value>, rhs: IndirectLink<Value>) -> Bool {
    lhs.wrappedValue == rhs.wrappedValue
  }
}

extension IndirectLink: Sendable where Value: Sendable {}
