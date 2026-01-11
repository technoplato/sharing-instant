import Foundation
import InstantDB
import XCTest

@testable import SharingInstant

// MARK: - Attribute Factory Helper

/// Creates an Attribute from component parts using JSON decoding.
/// Extracted from TripleStoreReverseLinkResolutionTests for reuse across tests.
func makeAttribute(
    id: String,
    forwardIdentity: [String],
    reverseIdentity: [String]? = nil,
    valueType: String,
    cardinality: String,
    unique: Bool? = nil,
    indexed: Bool? = nil,
    onDelete: String? = nil,
    onDeleteReverse: String? = nil
) throws -> Attribute {
    var dict: [String: Any] = [
        "id": id,
        "forward-identity": forwardIdentity,
        "value-type": valueType,
        "cardinality": cardinality,
    ]

    if let reverseIdentity {
        dict["reverse-identity"] = reverseIdentity
    }

    if let unique {
        dict["unique?"] = unique
    }

    if let indexed {
        dict["index?"] = indexed
    }

    if let onDelete {
        dict["on-delete"] = onDelete
    }

    if let onDeleteReverse {
        dict["on-delete-reverse"] = onDeleteReverse
    }

    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(Attribute.self, from: data)
}

// MARK: - Test Assertion Helpers

extension XCTestCase {
    /// Asserts that resolving an entity from the store produces the expected result.
    func assertResolvesTo<T: Decodable & Equatable>(
        store: InstantDB.TripleStore,
        entityId: String,
        attrsStore: AttrsStore,
        expected: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolved: T? = store.get(id: entityId, attrsStore: attrsStore)
        XCTAssertNotNil(resolved, "Entity \(entityId) should resolve", file: file, line: line)
        XCTAssertEqual(resolved, expected, file: file, line: line)
    }

    /// Asserts that an entity can be resolved and passes a custom validation closure.
    func assertResolves<T: Decodable>(
        store: InstantDB.TripleStore,
        entityId: String,
        attrsStore: AttrsStore,
        as type: T.Type = T.self,
        file: StaticString = #filePath,
        line: UInt = #line,
        validation: (T) -> Void
    ) {
        guard let resolved: T = store.get(id: entityId, attrsStore: attrsStore) else {
            XCTFail("Entity \(entityId) should resolve to \(T.self)", file: file, line: line)
            return
        }
        validation(resolved)
    }
}

// MARK: - Triple Creation Helpers

extension InstantDB.TripleStore {
    /// Convenience method to add a string value triple.
    func addStringTriple(
        entityId: String,
        attributeId: String,
        value: String,
        timestamp: Int64 = 0
    ) {
        addTriple(
            Triple(
                entityId: entityId,
                attributeId: attributeId,
                value: .string(value),
                createdAt: timestamp
            ),
            hasCardinalityOne: true
        )
    }

    /// Convenience method to add an integer value triple.
    func addIntTriple(
        entityId: String,
        attributeId: String,
        value: Int64,
        timestamp: Int64 = 0
    ) {
        addTriple(
            Triple(
                entityId: entityId,
                attributeId: attributeId,
                value: .int(value),
                createdAt: timestamp
            ),
            hasCardinalityOne: true
        )
    }

    /// Convenience method to add a reference (link) triple.
    func addRefTriple(
        entityId: String,
        attributeId: String,
        targetId: String,
        timestamp: Int64 = 0,
        hasCardinalityOne: Bool = false
    ) {
        addTriple(
            Triple(
                entityId: entityId,
                attributeId: attributeId,
                value: .ref(targetId),
                createdAt: timestamp
            ),
            hasCardinalityOne: hasCardinalityOne,
            isRef: true
        )
    }
}
