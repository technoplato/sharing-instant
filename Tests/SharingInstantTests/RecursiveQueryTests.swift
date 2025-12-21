
import XCTest
import SharingInstant
@testable import SharingInstant

// Note: These tests rely on the Generated/ folder in SharingInstantTests.
// If missing, run the generation command mentioned in SharingInstantTests.swift

final class RecursiveQueryTests: XCTestCase {

  func testNestedLinkStructure() {
    // Expected API: .with(\.posts) { $0.with(\.comments) }
    // This should fail to compile initially because the overload doesn't exist yet.
    
    let key = Schema.profiles
      .with(\.posts) { posts in
          posts.with(\.comments)
      }
    
    // We can't easily assert the internal structure without exposing it, 
    // but compiling validly is the first step.
    // Ideally we inspect 'includedLinks' or the new internal storage.
    
    XCTAssertNotNil(key)
    XCTAssertEqual(key.namespace, "profiles")
  }

  func testMultipleNestedLinks() {
    // Branching: posts -> [comments, likes]
    let key = Schema.profiles
      .with(\.posts) { posts in
        posts
          .with(\.comments)
          .with(\.likes)
      }
      
    XCTAssertNotNil(key)
  }

  func testNestedQueryModifiers() {
    // Nested limits and sorting
    let key = Schema.profiles
      .with(\.posts) { posts in
        posts
          .limit(5)
          .orderBy(\.createdAt, .desc)
      }
    
    XCTAssertNotNil(key)
  }

  func testDeepNesting() {
    // depth > 2
    // profiles -> posts -> comments -> author
    let key = Schema.profiles
      .with(\.posts) { posts in
        posts.with(\.comments) { comments in
            comments.with(\.author)
        }
      }
      
    XCTAssertNotNil(key)
  }
}
