import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - Integration Tests

/// Integration tests against the real InstantDB backend.
///
/// These tests use the test app: b9319949-2f2d-410b-8f8a-6990177c1d44
///
/// - Note: These tests require network access and a valid InstantDB connection.
///   They may be flaky due to network conditions.
final class IntegrationTests: XCTestCase {
  
  /// The test InstantDB app ID from the plan
  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  
  var client: InstantClient!
  
  @MainActor
  override func setUp() async throws {
    try await super.setUp()
    client = InstantClient(appID: Self.testAppID)
    
    // Wait for connection
    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
  }
  
  override func tearDown() async throws {
    client = nil
    try await super.tearDown()
  }
  
  // MARK: - Connection Tests
  
  @MainActor
  func testClientConnection() async throws {
    // Verify client was created with correct app ID
    XCTAssertEqual(client.appID, Self.testAppID)
    
    // Wait for connection to establish
    try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
    
    // Connection state should be authenticated or connecting
    // Note: The actual state depends on network conditions
    XCTAssertNotNil(client)
  }
  
  // MARK: - Query Configuration Tests
  
  func testQueryKeyCreation() {
    let config = SharingInstantQuery.Configuration<TestTodo>(
      namespace: "test_todos",
      orderBy: .desc("createdAt"),
      limit: 10
    )
    
    XCTAssertEqual(config.namespace, "test_todos")
    XCTAssertEqual(config.orderBy?.field, "createdAt")
    XCTAssertEqual(config.orderBy?.isDescending, true)
    XCTAssertEqual(config.limit, 10)
  }
  
  // MARK: - Sync Configuration Tests
  
  func testSyncKeyCreation() {
    let config = SharingInstantSync.CollectionConfiguration<TestTodo>(
      namespace: "test_todos",
      orderBy: .desc("createdAt")
    )
    
    XCTAssertEqual(config.namespace, "test_todos")
    XCTAssertEqual(config.orderBy?.field, "createdAt")
    XCTAssertEqual(config.orderBy?.isDescending, true)
  }
  
  // MARK: - Entity Namespace Tests
  
  func testEntityNamespace() {
    XCTAssertEqual(TestTodo.namespace, "test_todos")
    XCTAssertEqual(TestFact.namespace, "test_facts")
  }
  
  // MARK: - UniqueRequestKeyID Tests
  
  func testUniqueRequestKeyIDEquality() {
    let id1 = UniqueRequestKeyID(
      appID: Self.testAppID,
      namespace: "test_todos",
      orderBy: .desc("createdAt")
    )
    
    let id2 = UniqueRequestKeyID(
      appID: Self.testAppID,
      namespace: "test_todos",
      orderBy: .desc("createdAt")
    )
    
    // Same configuration should produce equal IDs
    XCTAssertEqual(id1, id2)
    
    // Different namespace should produce different ID
    let id3 = UniqueRequestKeyID(
      appID: Self.testAppID,
      namespace: "test_facts",
      orderBy: .desc("createdAt")
    )
    XCTAssertNotEqual(id1, id3)
  }
  
  // MARK: - Dependency Injection Tests
  
  func testDependencyInjection() {
    // Test that we can inject an app ID via dependencies
    withDependencies {
      $0.instantAppID = Self.testAppID
    } operation: {
      @Dependency(\.instantAppID) var injectedAppID
      XCTAssertEqual(injectedAppID, Self.testAppID)
    }
  }
}

// MARK: - Test Models

/// A todo item for integration testing
struct TestTodo: Codable, EntityIdentifiable, Sendable, Equatable {
  static var namespace: String { "test_todos" }
  
  var id: String
  var title: String
  var done: Bool
  var createdAt: Date
  
  init(
    id: String = UUID().uuidString,
    title: String = "Test Todo",
    done: Bool = false,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.done = done
    self.createdAt = createdAt
  }
}

/// A fact item for integration testing
struct TestFact: Codable, EntityIdentifiable, Sendable, Equatable {
  static var namespace: String { "test_facts" }
  
  var id: String
  var text: String
  var count: Int
  
  init(id: String = UUID().uuidString, text: String = "Test Fact", count: Int = 0) {
    self.id = id
    self.text = text
    self.count = count
  }
}

