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
  
  func testKeyIDEquality() {
    let id1 = UniqueRequestKeyID(
      appID: "test-app-id",
      namespace: "todos",
      orderBy: .desc("createdAt")
    )
    
    let id2 = UniqueRequestKeyID(
      appID: "test-app-id",
      namespace: "todos",
      orderBy: .desc("createdAt")
    )
    
    XCTAssertEqual(id1, id2)
  }
  
  func testKeyIDInequalityDifferentNamespace() {
    let id1 = UniqueRequestKeyID(
      appID: "test-app-id",
      namespace: "todos",
      orderBy: .desc("createdAt")
    )
    
    let id2 = UniqueRequestKeyID(
      appID: "test-app-id",
      namespace: "goals",
      orderBy: .desc("createdAt")
    )
    
    XCTAssertNotEqual(id1, id2)
  }
  
  func testKeyIDInequalityDifferentOrder() {
    let id1 = UniqueRequestKeyID(
      appID: "test-app-id",
      namespace: "todos",
      orderBy: .desc("createdAt")
    )
    
    let id2 = UniqueRequestKeyID(
      appID: "test-app-id",
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

// MARK: - EntityKey Tests

final class EntityKeyTests: XCTestCase {
  
  func testEntityKeyCreation() {
    let key = EntityKey<Todo>(namespace: "todos")
    XCTAssertEqual(key.namespace, "todos")
    XCTAssertNil(key.orderByField)
    XCTAssertNil(key.orderDirection)
    XCTAssertNil(key.limitCount)
    XCTAssertTrue(key.whereClauses.isEmpty)
  }
  
  func testEntityKeyOrderByKeyPath() {
    let key = EntityKey<Todo>(namespace: "todos")
      .orderBy(\.createdAt, .desc)
    
    XCTAssertEqual(key.namespace, "todos")
    XCTAssertEqual(key.orderByField, "createdAt")
    XCTAssertEqual(key.orderDirection, .desc)
  }
  
  func testEntityKeyOrderByString() {
    let key = EntityKey<Todo>(namespace: "todos")
      .orderBy("title", .asc)
    
    XCTAssertEqual(key.orderByField, "title")
    XCTAssertEqual(key.orderDirection, .asc)
  }
  
  func testEntityKeyLimit() {
    let key = EntityKey<Todo>(namespace: "todos")
      .limit(10)
    
    XCTAssertEqual(key.limitCount, 10)
  }
  
  func testEntityKeyChainedModifiers() {
    let key = EntityKey<Todo>(namespace: "todos")
      .orderBy(\.createdAt, .desc)
      .limit(20)
    
    XCTAssertEqual(key.orderByField, "createdAt")
    XCTAssertEqual(key.orderDirection, .desc)
    XCTAssertEqual(key.limitCount, 20)
  }
  
  func testEntityKeyWhereClause() {
    let key = EntityKey<Todo>(namespace: "todos")
      .where(\.done, .eq(false))
    
    XCTAssertEqual(key.whereClauses.count, 1)
    XCTAssertNotNil(key.whereClauses["done"])
  }
  
  func testEntityKeyMultipleWhereClauses() {
    let key = EntityKey<Todo>(namespace: "todos")
      .where(\.done, .eq(false))
      .where("title", .neq(""))
    
    XCTAssertEqual(key.whereClauses.count, 2)
    XCTAssertNotNil(key.whereClauses["done"])
    XCTAssertNotNil(key.whereClauses["title"])
  }
  
  func testEntityKeyImmutability() {
    let key1 = EntityKey<Todo>(namespace: "todos")
    let key2 = key1.orderBy(\.createdAt, .desc)
    let key3 = key1.limit(10)
    
    // Original should be unchanged
    XCTAssertNil(key1.orderByField)
    XCTAssertNil(key1.limitCount)
    
    // Modified copies should have changes
    XCTAssertEqual(key2.orderByField, "createdAt")
    XCTAssertNil(key2.limitCount)
    
    XCTAssertNil(key3.orderByField)
    XCTAssertEqual(key3.limitCount, 10)
  }
  
  func testEntityKeyWithLinkInclusion() {
    let key = EntityKey<Todo>(namespace: "todos")
      .with("owner")
    
    XCTAssertEqual(key.includedLinks.count, 1)
    XCTAssertTrue(key.includedLinks.contains("owner"))
  }
  
  func testEntityKeyMultipleLinkInclusions() {
    let key = EntityKey<Todo>(namespace: "todos")
      .with("owner")
      .with("tags")
      .with("category")
    
    XCTAssertEqual(key.includedLinks.count, 3)
    XCTAssertTrue(key.includedLinks.contains("owner"))
    XCTAssertTrue(key.includedLinks.contains("tags"))
    XCTAssertTrue(key.includedLinks.contains("category"))
  }
  
  func testEntityKeyFullQueryBuilder() {
    let key = EntityKey<Todo>(namespace: "todos")
      .where(\.done, .eq(false))
      .orderBy(\.createdAt, .desc)
      .limit(10)
      .with("owner")
    
    XCTAssertEqual(key.namespace, "todos")
    XCTAssertEqual(key.whereClauses.count, 1)
    XCTAssertEqual(key.orderByField, "createdAt")
    XCTAssertEqual(key.orderDirection, .desc)
    XCTAssertEqual(key.limitCount, 10)
    XCTAssertTrue(key.includedLinks.contains("owner"))
  }
}

// MARK: - EntityKeyPredicate Tests

final class EntityKeyPredicateTests: XCTestCase {
  
  func testPredicateEquals() {
    let predicate = EntityKeyPredicate.eq(false)
    if case .equals(let value) = predicate {
      XCTAssertEqual(value.base as? Bool, false)
    } else {
      XCTFail("Expected .equals predicate")
    }
  }
  
  func testPredicateNotEquals() {
    let predicate = EntityKeyPredicate.neq("test")
    if case .notEquals(let value) = predicate {
      XCTAssertEqual(value.base as? String, "test")
    } else {
      XCTFail("Expected .notEquals predicate")
    }
  }
  
  func testPredicateGreaterThan() {
    let predicate = EntityKeyPredicate.gt(5)
    if case .greaterThan(let value) = predicate {
      XCTAssertEqual(value.base as? Int, 5)
    } else {
      XCTFail("Expected .greaterThan predicate")
    }
  }
  
  func testPredicateLessThan() {
    let predicate = EntityKeyPredicate.lt(10.5)
    if case .lessThan(let value) = predicate {
      XCTAssertEqual(value.base as? Double, 10.5)
    } else {
      XCTFail("Expected .lessThan predicate")
    }
  }
  
  func testPredicateIn() {
    let predicate = EntityKeyPredicate.in(["a", "b", "c"])
    if case .isIn(let values) = predicate {
      XCTAssertEqual(values.count, 3)
    } else {
      XCTFail("Expected .isIn predicate")
    }
  }
  
  func testPredicateToWhereValue() {
    // Equals should return the value directly
    let eqPredicate = EntityKeyPredicate.eq("test")
    let eqValue = eqPredicate.toWhereValue()
    XCTAssertEqual(eqValue as? String, "test")
    
    // Other operators should return a dictionary
    let gtPredicate = EntityKeyPredicate.gt(5)
    let gtValue = gtPredicate.toWhereValue()
    if let dict = gtValue as? [String: Any] {
      XCTAssertNotNil(dict["$gt"])
    } else {
      XCTFail("Expected dictionary for gt predicate")
    }
  }
  
  // MARK: - String Search Predicate Tests
  
  func testPredicateLike() {
    let predicate: EntityKeyPredicate = .like("%hello%")
    if case .like(let pattern) = predicate {
      XCTAssertEqual(pattern, "%hello%")
    } else {
      XCTFail("Expected .like predicate")
    }
  }
  
  func testPredicateIlike() {
    let predicate: EntityKeyPredicate = .ilike("%HELLO%")
    if case .ilike(let pattern) = predicate {
      XCTAssertEqual(pattern, "%HELLO%")
    } else {
      XCTFail("Expected .ilike predicate")
    }
  }
  
  func testPredicateContains() {
    let predicate = EntityKeyPredicate.contains("search")
    // Contains should create an ilike with %...%
    if case .ilike(let pattern) = predicate {
      XCTAssertEqual(pattern, "%search%")
    } else {
      XCTFail("Expected .ilike predicate from contains")
    }
  }
  
  func testPredicateStartsWith() {
    let predicate = EntityKeyPredicate.startsWith("prefix")
    // StartsWith should create an ilike with ...%
    if case .ilike(let pattern) = predicate {
      XCTAssertEqual(pattern, "prefix%")
    } else {
      XCTFail("Expected .ilike predicate from startsWith")
    }
  }
  
  func testPredicateEndsWith() {
    let predicate = EntityKeyPredicate.endsWith("suffix")
    // EndsWith should create an ilike with %...
    if case .ilike(let pattern) = predicate {
      XCTAssertEqual(pattern, "%suffix")
    } else {
      XCTFail("Expected .ilike predicate from endsWith")
    }
  }
  
  func testPredicateLikeToWhereValue() {
    let predicate: EntityKeyPredicate = .like("%test%")
    let value = predicate.toWhereValue()
    if let dict = value as? [String: Any] {
      XCTAssertEqual(dict["$like"] as? String, "%test%")
    } else {
      XCTFail("Expected dictionary with $like key")
    }
  }
  
  func testPredicateIlikeToWhereValue() {
    let predicate: EntityKeyPredicate = .ilike("%TEST%")
    let value = predicate.toWhereValue()
    if let dict = value as? [String: Any] {
      XCTAssertEqual(dict["$ilike"] as? String, "%TEST%")
    } else {
      XCTFail("Expected dictionary with $ilike key")
    }
  }
  
  func testEntityKeyWithStringSearch() {
    let key = EntityKey<Todo>(namespace: "todos")
      .where(\.title, .contains("groceries"))
    
    XCTAssertEqual(key.whereClauses.count, 1)
    if let predicate = key.whereClauses["title"],
       case .ilike(let pattern) = predicate {
      XCTAssertEqual(pattern, "%groceries%")
    } else {
      XCTFail("Expected ilike predicate for title")
    }
  }
  
  func testEntityKeyWithMultiplePredicatesIncludingSearch() {
    let key = EntityKey<Todo>(namespace: "todos")
      .where(\.done, .eq(false))
      .where(\.title, .startsWith("Buy"))
      .orderBy(\.createdAt, .desc)
      .limit(10)
    
    XCTAssertEqual(key.whereClauses.count, 2)
    XCTAssertEqual(key.orderByField, "createdAt")
    XCTAssertEqual(key.orderDirection, .desc)
    XCTAssertEqual(key.limitCount, 10)
    
    // Check the done predicate
    if let donePredicate = key.whereClauses["done"],
       case .equals(let value) = donePredicate {
      XCTAssertEqual(value.base as? Bool, false)
    } else {
      XCTFail("Expected equals predicate for done")
    }
    
    // Check the title predicate
    if let titlePredicate = key.whereClauses["title"],
       case .ilike(let pattern) = titlePredicate {
      XCTAssertEqual(pattern, "Buy%")
    } else {
      XCTFail("Expected ilike predicate for title")
    }
  }
}

