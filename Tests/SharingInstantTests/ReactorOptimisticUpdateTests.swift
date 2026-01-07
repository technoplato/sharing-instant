/// Tests ported from TypeScript SDK: Reactor.test.js
///
/// These tests verify that sharing-instant's Reactor matches the TypeScript SDK behavior
/// for optimistic updates, particularly around the notifyAll() pattern.
///
/// ## Key Behaviors Tested
/// 1. TripleStore observer pattern works correctly
/// 2. Entity deletion notifies observers
/// 3. Multiple entities can be tracked independently
///
/// ## Test Types
/// - Unit tests: Test the TripleStore observer mechanism directly (no network)
/// - Integration tests in other files test the full Reactor subscription flow
///
/// ## Reference
/// - TypeScript: `instant/client/packages/core/__tests__/src/Reactor.test.js`
/// - Test: "optimisticTx is not overwritten by refresh-ok"

import Dependencies
import IdentifiedCollections
import InstantDB
import XCTest

@testable import SharingInstant

// MARK: - Helper Actor for Thread-Safe Counting

private actor ObserverCounter {
  var count = 0

  func increment() {
    count += 1
  }
}

// MARK: - ReactorOptimisticUpdateTests

final class ReactorOptimisticUpdateTests: XCTestCase {

  // MARK: - Unit Tests (No Network Required)

  /// Tests that the TripleStore observer pattern correctly notifies when data changes.
  /// This is a lower-level test of the notification mechanism that powers optimistic updates.
  @MainActor
  func testTripleStoreObserverPatternWorks() async throws {
    let store = SharedTripleStore()

    let todoId = UUID().uuidString.lowercased()
    store.addTriples(createTodoTriples(id: todoId, title: "Initial", done: false))

    // Add observer using actor-isolated counter
    let counter = ObserverCounter()
    let token = store.addObserver(id: todoId) {
      Task { @MainActor in
        await counter.increment()
      }
    }

    // Update the entity
    store.addTriples(createTodoTriples(id: todoId, title: "Updated", done: true))
    try await Task.sleep(nanoseconds: 100_000_000)

    // Observer should have been called
    let count = await counter.count
    XCTAssertGreaterThan(count, 0, "Observer should be notified when entity changes")

    // Cleanup
    store.removeObserver(id: todoId, token: token)
  }

  /// Tests that deleting an entity notifies observers.
  @MainActor
  func testTripleStoreDeleteNotifiesObservers() async throws {
    let store = SharedTripleStore()

    let todoId = UUID().uuidString.lowercased()
    store.addTriples(createTodoTriples(id: todoId, title: "To Delete", done: false))

    // Add observer
    let counter = ObserverCounter()
    let token = store.addObserver(id: todoId) {
      Task { @MainActor in
        await counter.increment()
      }
    }

    // Delete entity
    store.deleteEntity(id: todoId)
    try await Task.sleep(nanoseconds: 100_000_000)

    // Observer should have been called
    let count = await counter.count
    XCTAssertGreaterThan(count, 0, "Observer should be notified when entity is deleted")

    // Cleanup
    store.removeObserver(id: todoId, token: token)
  }

  /// Tests that observers for different entities are independent.
  @MainActor
  func testMultipleEntityObserversAreIndependent() async throws {
    let store = SharedTripleStore()

    let todoId1 = UUID().uuidString.lowercased()
    let todoId2 = UUID().uuidString.lowercased()

    store.addTriples(createTodoTriples(id: todoId1, title: "Todo 1", done: false))
    store.addTriples(createTodoTriples(id: todoId2, title: "Todo 2", done: false))

    // Add observers for each entity
    let counter1 = ObserverCounter()
    let counter2 = ObserverCounter()

    let token1 = store.addObserver(id: todoId1) {
      Task { @MainActor in
        await counter1.increment()
      }
    }

    let token2 = store.addObserver(id: todoId2) {
      Task { @MainActor in
        await counter2.increment()
      }
    }

    // Update only entity 1
    store.addTriples(createTodoTriples(id: todoId1, title: "Updated Todo 1", done: true))
    try await Task.sleep(nanoseconds: 100_000_000)

    let count1 = await counter1.count
    let count2 = await counter2.count

    // Only observer 1 should have been called
    XCTAssertGreaterThan(count1, 0, "Observer 1 should be notified")
    XCTAssertEqual(count2, 0, "Observer 2 should NOT be notified (different entity)")

    // Cleanup
    store.removeObserver(id: todoId1, token: token1)
    store.removeObserver(id: todoId2, token: token2)
  }

  /// Tests that cardinality-one attributes overwrite previous values.
  ///
  /// Note: The TripleStore.addTriple() for cardinality-one simply overwrites (no timestamp check).
  /// This is the correct behavior - the server is the source of truth.
  /// See: instant/client/packages/core/src/store.ts addTriple()
  @MainActor
  func testTripleStoreCardinalityOneOverwrites() async throws {
    let store = SharedTripleStore()

    let todoId = UUID().uuidString.lowercased()
    let attrId = "todos/title"

    // Add initial version with cardinality-one directly
    let timestamp1 = Int64(Date().timeIntervalSince1970 * 1000)
    store.inner.addTriple(
      Triple(
        entityId: todoId,
        attributeId: attrId,
        value: .string("Original"),
        createdAt: timestamp1
      ),
      hasCardinalityOne: true,
      isRef: false
    )

    // Verify initial value exists
    var triples = store.inner.getTriples(entity: todoId, attribute: attrId)
    XCTAssertEqual(triples.count, 1, "Should have one triple")
    XCTAssertEqual(triples.first?.value.toAny() as? String, "Original")

    // Add updated version (simulating server overwrite)
    let timestamp2 = timestamp1 + 1000
    store.inner.addTriple(
      Triple(
        entityId: todoId,
        attributeId: attrId,
        value: .string("Updated"),
        createdAt: timestamp2
      ),
      hasCardinalityOne: true,
      isRef: false
    )

    // Verify the value was overwritten (cardinality-one replaces, doesn't add)
    triples = store.inner.getTriples(entity: todoId, attribute: attrId)
    XCTAssertEqual(triples.count, 1, "Should still have one triple (cardinality one)")
    XCTAssertEqual(triples.first?.value.toAny() as? String, "Updated", "Later write should overwrite")
  }

  /// Tests that cardinality-many attributes accumulate values.
  @MainActor
  func testTripleStoreCardinalityManyAccumulates() async throws {
    let store = SharedTripleStore()

    let todoId = UUID().uuidString.lowercased()
    let attrId = "todos/tags"  // Tags would be cardinality-many

    // Add first value with cardinality-many
    let timestamp1 = Int64(Date().timeIntervalSince1970 * 1000)
    store.inner.addTriple(
      Triple(
        entityId: todoId,
        attributeId: attrId,
        value: .string("urgent"),
        createdAt: timestamp1
      ),
      hasCardinalityOne: false,
      isRef: false
    )

    // Verify first value exists
    var triples = store.inner.getTriples(entity: todoId, attribute: attrId)
    XCTAssertEqual(triples.count, 1, "Should have one triple")

    // Add second value
    store.inner.addTriple(
      Triple(
        entityId: todoId,
        attributeId: attrId,
        value: .string("work"),
        createdAt: timestamp1
      ),
      hasCardinalityOne: false,
      isRef: false
    )

    // Verify both values exist (cardinality-many accumulates)
    triples = store.inner.getTriples(entity: todoId, attribute: attrId)
    XCTAssertEqual(triples.count, 2, "Should have two triples (cardinality many)")
    let values = Set(triples.map { $0.value.toAny() as? String ?? "" })
    XCTAssertEqual(values, ["urgent", "work"], "Both values should be present")
  }

  // MARK: - Helpers

  private func createTodoTriples(id: String, title: String, done: Bool) -> [Triple] {
    let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
    return [
      Triple(
        entityId: id,
        attributeId: "todos/id",
        value: .string(id),
        createdAt: timestamp
      ),
      Triple(
        entityId: id,
        attributeId: "todos/title",
        value: .string(title),
        createdAt: timestamp
      ),
      Triple(
        entityId: id,
        attributeId: "todos/done",
        value: .bool(done),
        createdAt: timestamp
      ),
      Triple(
        entityId: id,
        attributeId: "todos/createdAt",
        value: .double(Double(timestamp)),
        createdAt: timestamp
      ),
    ]
  }
}
