
// Helper for recursive value types
public final class Box<T: Codable & Sendable>: Codable, Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try container.decode(T.self)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
