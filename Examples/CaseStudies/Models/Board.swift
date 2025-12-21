
import Foundation
import InstantDB

// MARK: - Board Entity (for TileGameDemo)

/// A game board that can be synced with InstantDB.
public struct Board: Sendable, Identifiable, Codable, Equatable {
  public var id: String
  public var state: [String: String]
  
  public init(id: String = UUID().uuidString, state: [String: String] = [:]) {
    self.id = id
    self.state = state
  }
  
  nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.state == rhs.state
  }
  
  nonisolated public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.state = try container.decode([String: String].self, forKey: .state)
  }
  
  nonisolated public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(state, forKey: .state)
  }
  
  private enum CodingKeys: String, CodingKey {
    case id, state
  }
}

nonisolated extension Board: EntityIdentifiable {
  public static var namespace: String { "boards" }
}
