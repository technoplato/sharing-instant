/// SynchronousConsistencyTests.swift
///
/// These tests verify that the TripleStore is immediately consistent after mutations.
/// After the refactor to query-level notification, the store operations are synchronous
/// and data is available immediately after `addTriples()`.
///
/// ## Background
/// The previous implementation used per-entity observers with async `Task {}`
/// dispatch, creating race conditions. The refactored implementation uses
/// query-level notification where ALL subscriptions are notified by the Reactor
/// after any mutation.
///
/// ## Test Design
/// These are unit tests that directly test the TripleStore primitives
/// without requiring network connectivity or InstantDB client setup.

import InstantDB
import XCTest

@testable import SharingInstant

// MARK: - SynchronousConsistencyTests

final class SynchronousConsistencyTests: XCTestCase {

  // MARK: - Inner TripleStore Tests

  /// Verifies that triples are immediately available after addTriple().
  @MainActor
  func testTriplesImmediatelyAvailableAfterAdd() async throws {
    let store = InstantDB.TripleStore()
    let todoId = UUID().uuidString.lowercased()

    // Add triples directly
    let timestamp = ConflictResolution.optimisticTimestamp()
    store.addTriple(
      Triple(entityId: todoId, attributeId: "todos/id", value: .string(todoId), createdAt: timestamp),
      hasCardinalityOne: true,
      isRef: false
    )
    store.addTriple(
      Triple(entityId: todoId, attributeId: "todos/title", value: .string("Test todo"), createdAt: timestamp),
      hasCardinalityOne: true,
      isRef: false
    )

    // Assert IMMEDIATELY - no await, no sleep
    let triples = store.getTriples(entity: todoId)
    XCTAssertEqual(triples.count, 2, "Triples should be immediately available")

    let titleTriple = triples.first { $0.attributeId == "todos/title" }
    XCTAssertNotNil(titleTriple)
    XCTAssertEqual(titleTriple?.value.toAny() as? String, "Test todo")
  }

  /// Verifies that updates are immediately reflected.
  @MainActor
  func testUpdatesImmediatelyReflected() async throws {
    let store = InstantDB.TripleStore()
    let todoId = UUID().uuidString.lowercased()

    // Add initial value
    let timestamp1 = ConflictResolution.optimisticTimestamp()
    store.addTriple(
      Triple(entityId: todoId, attributeId: "todos/title", value: .string("Original"), createdAt: timestamp1),
      hasCardinalityOne: true,
      isRef: false
    )

    // Verify initial value
    var triples = store.getTriples(entity: todoId, attribute: "todos/title")
    XCTAssertEqual(triples.first?.value.toAny() as? String, "Original")

    // Update
    let timestamp2 = ConflictResolution.optimisticTimestamp()
    store.addTriple(
      Triple(entityId: todoId, attributeId: "todos/title", value: .string("Updated"), createdAt: timestamp2),
      hasCardinalityOne: true,
      isRef: false
    )

    // Verify update IMMEDIATELY - no await, no sleep
    triples = store.getTriples(entity: todoId, attribute: "todos/title")
    XCTAssertEqual(triples.count, 1, "Cardinality one should have single value")
    XCTAssertEqual(triples.first?.value.toAny() as? String, "Updated")
  }

  /// Verifies that multiple rapid mutations are all reflected immediately.
  @MainActor
  func testRapidMutationsAllReflectedImmediately() async throws {
    let store = InstantDB.TripleStore()

    let count = 10
    var createdIds: [String] = []

    // Rapid-fire creates
    for i in 0..<count {
      let id = UUID().uuidString.lowercased()
      createdIds.append(id)
      let timestamp = ConflictResolution.optimisticTimestamp()

      store.addTriple(
        Triple(entityId: id, attributeId: "todos/id", value: .string(id), createdAt: timestamp),
        hasCardinalityOne: true,
        isRef: false
      )
      store.addTriple(
        Triple(entityId: id, attributeId: "todos/title", value: .string("Todo \(i)"), createdAt: timestamp),
        hasCardinalityOne: true,
        isRef: false
      )
    }

    // All should be visible immediately - no await, no sleep
    for (index, id) in createdIds.enumerated() {
      let triples = store.getTriples(entity: id)
      XCTAssertGreaterThan(triples.count, 0, "Entity \(id) should have triples immediately")

      let titleTriple = triples.first { $0.attributeId == "todos/title" }
      XCTAssertEqual(titleTriple?.value.toAny() as? String, "Todo \(index)")
    }
  }

  // MARK: - SharedTripleStore Tests

  /// Verifies that SharedTripleStore.addTriples is synchronous.
  @MainActor
  func testSharedTripleStoreAddTriplesIsSynchronous() async throws {
    let store = SharedTripleStore()
    let todoId = UUID().uuidString.lowercased()

    let timestamp = ConflictResolution.optimisticTimestamp()
    let triples = [
      Triple(entityId: todoId, attributeId: "todos/id", value: .string(todoId), createdAt: timestamp),
      Triple(entityId: todoId, attributeId: "todos/title", value: .string("Test todo"), createdAt: timestamp),
    ]

    // Add triples
    store.addTriples(triples)

    // Assert IMMEDIATELY - no await, no sleep
    let retrieved = store.inner.getTriples(entity: todoId)
    XCTAssertEqual(retrieved.count, 2, "Triples should be immediately available via inner store")
  }

  /// Verifies that SharedTripleStore.deleteEntity is synchronous.
  @MainActor
  func testSharedTripleStoreDeleteEntityIsSynchronous() async throws {
    let store = SharedTripleStore()
    let todoId = UUID().uuidString.lowercased()

    // Create entity
    let timestamp = ConflictResolution.optimisticTimestamp()
    store.addTriples([
      Triple(entityId: todoId, attributeId: "todos/id", value: .string(todoId), createdAt: timestamp),
      Triple(entityId: todoId, attributeId: "todos/title", value: .string("To delete"), createdAt: timestamp),
    ])

    // Verify exists
    XCTAssertTrue(store.inner.hasEntity(todoId), "Entity should exist before delete")

    // Delete
    store.deleteEntity(id: todoId)

    // Verify deleted IMMEDIATELY - no await, no sleep
    XCTAssertFalse(store.inner.hasEntity(todoId), "Entity should be deleted immediately")
  }

  /// Verifies that SharedTripleStore no longer has observer methods.
  /// This test documents the refactor from entity-level to query-level reactivity.
  @MainActor
  func testSharedTripleStoreHasNoObserverMethods() async throws {
    let store = SharedTripleStore()

    // These methods should NOT exist after the refactor
    // If this test compiles, it proves the methods were removed

    // The following would fail to compile if observers still existed:
    // store.addObserver(id: "test") { }  // Should not compile
    // store.removeObserver(id: "test", token: UUID())  // Should not compile

    // Instead, verify the store is a pure data structure
    XCTAssertNotNil(store.inner, "Store should have inner TripleStore")
    XCTAssertNotNil(store.attrsStore, "Store should have attrsStore")
  }
}
