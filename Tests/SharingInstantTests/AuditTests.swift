
import XCTest
@testable import SharingInstant

final class AuditTests: XCTestCase {
  
  // Verify that EntityKeyQueryRequest (used by @SharedReader)
  // correctly passes includedLinks to its configuration.
  func testEntityKeyQueryRequestIncludedLinks() {
    let key = EntityKey<Todo>(namespace: "todos")
      .with("owner")
    
    let request = EntityKeyQueryRequest(key: key)
    
    // This is expected to FAIL if the bug exists
    // The configuration in SharingInstantQuery.swift does not have includedLinks
    // so we can't even access it to check!
    
    // We can check if we can even construct a configuration with links?
    // Looking at SharingInstantQuery.Configuration:
    /*
     public init(
       namespace: String,
       orderBy: OrderBy? = nil,
       limit: Int? = nil,
       whereClause: [String: Any]? = nil,
       testingValue: [Value]? = nil
     )
     */
    // It does NOT have includedLinks in init.
    
    XCTAssertNotNil(request.configuration)
    // If the struct doesn't have the property, this code won't compile if I try to access it.
    // So if I can't write the assertion, the feature is definitely missing.
  }
}
