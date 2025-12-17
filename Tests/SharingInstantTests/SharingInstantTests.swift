import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - Test Models

struct Todo: Codable, EntityIdentifiable, Sendable, Equatable {
  static var namespace: String { "todos" }
  
  var id: String
  var title: String
  var done: Bool
  var createdAt: Date
  
  init(id: String = UUID().uuidString, title: String, done: Bool = false, createdAt: Date = Date()) {
    self.id = id
    self.title = title
    self.done = done
    self.createdAt = createdAt
  }
}

// MARK: - Configuration Tests

final class SharingInstantConfigurationTests: XCTestCase {
  
  func testCollectionConfigurationCreation() {
    let config = SharingInstantSync.CollectionConfiguration<Todo>(
      namespace: "todos",
      orderBy: .desc("createdAt")
    )
    
    XCTAssertEqual(config.namespace, "todos")
    XCTAssertEqual(config.orderBy?.field, "createdAt")
    XCTAssertEqual(config.orderBy?.isDescending, true)
  }
  
  func testQueryConfigurationCreation() {
    let config = SharingInstantQuery.Configuration<Todo>(
      namespace: "todos",
      orderBy: .asc("title"),
      limit: 10
    )
    
    XCTAssertEqual(config.namespace, "todos")
    XCTAssertEqual(config.orderBy?.field, "title")
    XCTAssertEqual(config.orderBy?.isDescending, false)
    XCTAssertEqual(config.limit, 10)
  }
  
  func testOrderByAsc() {
    let order = OrderBy.asc("title")
    XCTAssertEqual(order.field, "title")
    XCTAssertFalse(order.isDescending)
  }
  
  func testOrderByDesc() {
    let order = OrderBy.desc("createdAt")
    XCTAssertEqual(order.field, "createdAt")
    XCTAssertTrue(order.isDescending)
  }
}

// MARK: - Entity Protocol Tests

final class EntityIdentifiableTests: XCTestCase {
  
  func testTodoConformsToEntityIdentifiable() {
    let todo = Todo(id: "test-id", title: "Test Todo")
    XCTAssertEqual(todo.id, "test-id")
  }
  
  func testTodoEncodingDecoding() throws {
    let todo = Todo(id: "test-id", title: "Test Todo", done: true)
    
    let encoder = JSONEncoder()
    let data = try encoder.encode(todo)
    
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(Todo.self, from: data)
    
    XCTAssertEqual(todo, decoded)
  }
}

// MARK: - UniqueRequestKeyID Tests

final class UniqueRequestKeyIDTests: XCTestCase {
  
  @MainActor
  func testKeyIDEquality() {
    let client = InstantClient(appID: "test-app-id")
    
    let id1 = UniqueRequestKeyID(
      client: client,
      namespace: "todos",
      orderBy: .desc("createdAt")
    )
    
    let id2 = UniqueRequestKeyID(
      client: client,
      namespace: "todos",
      orderBy: .desc("createdAt")
    )
    
    XCTAssertEqual(id1, id2)
  }
  
  @MainActor
  func testKeyIDInequalityDifferentNamespace() {
    let client = InstantClient(appID: "test-app-id")
    
    let id1 = UniqueRequestKeyID(
      client: client,
      namespace: "todos",
      orderBy: .desc("createdAt")
    )
    
    let id2 = UniqueRequestKeyID(
      client: client,
      namespace: "goals",
      orderBy: .desc("createdAt")
    )
    
    XCTAssertNotEqual(id1, id2)
  }
  
  @MainActor
  func testKeyIDInequalityDifferentOrder() {
    let client = InstantClient(appID: "test-app-id")
    
    let id1 = UniqueRequestKeyID(
      client: client,
      namespace: "todos",
      orderBy: .desc("createdAt")
    )
    
    let id2 = UniqueRequestKeyID(
      client: client,
      namespace: "todos",
      orderBy: .asc("createdAt")
    )
    
    XCTAssertNotEqual(id1, id2)
  }
}

// MARK: - Testing Value Tests

final class TestingValueTests: XCTestCase {
  
  func testCollectionConfigurationWithTestingValue() {
    let testTodos = [
      Todo(id: "1", title: "Test 1"),
      Todo(id: "2", title: "Test 2")
    ]
    
    let config = SharingInstantSync.CollectionConfiguration<Todo>(
      namespace: "todos",
      testingValue: testTodos
    )
    
    XCTAssertEqual(config.testingValue?.count, 2)
    XCTAssertEqual(config.testingValue?.first?.title, "Test 1")
  }
  
  func testQueryConfigurationWithTestingValue() {
    let testTodos = [
      Todo(id: "1", title: "Test 1")
    ]
    
    let config = SharingInstantQuery.Configuration<Todo>(
      namespace: "todos",
      testingValue: testTodos
    )
    
    XCTAssertEqual(config.testingValue?.count, 1)
  }
}

