import InstantDB
import XCTest

@testable import SharingInstant

// MARK: - SharedTripleStoreObserverPropagationTests

/// Validates that `SharedTripleStore` publishes changes for both sides of ref triples.
///
/// ## Why This Test Exists
/// SharingInstant derives reverse links (e.g. `media.transcriptionRuns`) by resolving reverse
/// reference triples from the underlying `InstantDB.TripleStore`.
///
/// When we add a ref triple like:
///   `TranscriptionRun(id=R).media = Media(id=M)`
///
/// the *resolved view* of **both** `R` (forward link) and `M` (reverse link) changes.
///
/// Reactor subscriptions in SharingInstant only re-yield values when the observer for an
/// entity ID fires. If we only notify `R`, views driven by a `Media` subscription can stay
/// stale until a server refresh or app restart, which matches the "link didn't show up"
/// symptom we saw in SpeechRecorderApp.
final class SharedTripleStoreObserverPropagationTests: XCTestCase {
  // MARK: - Tests

  func testAddTriples_refTripleNotifiesBothSubjectAndTarget() async throws {
    let store = SharedTripleStore()

    let refAttr = try makeAttribute(
      id: "attr-run-media",
      valueType: "ref",
      cardinality: "one"
    )
    store.updateAttributes([refAttr])

    let runId = "run-1"
    let mediaId = "media-1"

    let subjectNotified = XCTestExpectation(description: "Subject entity observer is notified")
    let targetNotified = XCTestExpectation(description: "Target entity observer is notified")

    let subjectToken = store.addObserver(id: runId) {
      subjectNotified.fulfill()
    }
    let targetToken = store.addObserver(id: mediaId) {
      targetNotified.fulfill()
    }
    defer {
      store.removeObserver(id: runId, token: subjectToken)
      store.removeObserver(id: mediaId, token: targetToken)
    }

    store.addTriples([
      Triple(
        entityId: runId,
        attributeId: refAttr.id,
        value: .ref(mediaId),
        createdAt: 0
      )
    ])

    await fulfillment(of: [subjectNotified, targetNotified], timeout: 1.0)
  }

  func testAddTriples_nonRefTripleNotifiesOnlySubject() async throws {
    let store = SharedTripleStore()

    let nonRefAttr = try makeAttribute(
      id: "attr-run-status",
      valueType: "string",
      cardinality: "one"
    )
    store.updateAttributes([nonRefAttr])

    let runId = "run-1"
    let unrelatedId = "media-1"

    let subjectNotified = XCTestExpectation(description: "Subject entity observer is notified")
    let targetNotNotified = XCTestExpectation(description: "Target entity observer is not notified")
    targetNotNotified.isInverted = true

    let subjectToken = store.addObserver(id: runId) {
      subjectNotified.fulfill()
    }
    let targetToken = store.addObserver(id: unrelatedId) {
      targetNotNotified.fulfill()
    }
    defer {
      store.removeObserver(id: runId, token: subjectToken)
      store.removeObserver(id: unrelatedId, token: targetToken)
    }

    store.addTriples([
      Triple(
        entityId: runId,
        attributeId: nonRefAttr.id,
        value: .string("active"),
        createdAt: 0
      )
    ])

    await fulfillment(of: [subjectNotified, targetNotNotified], timeout: 0.5)
  }

  // MARK: - Helpers

  private func makeAttribute(
    id: String,
    valueType: String,
    cardinality: String
  ) throws -> Attribute {
    let dict: [String: Any] = [
      "id": id,
      "forward-identity": ["ident-\(id)", "tests", id],
      "value-type": valueType,
      "cardinality": cardinality,
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(Attribute.self, from: data)
  }
}

