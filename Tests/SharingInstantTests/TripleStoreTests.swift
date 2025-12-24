
import XCTest
@testable import SharingInstant
import InstantDB

final class TripleStoreTests: XCTestCase {
    
    // MARK: - Batch 1: Basic Add/Update/Delete
    
    func testSimpleAdd() async {
        let store = InstantDB.TripleStore()
        let id = UUID().uuidString
        let timestamp: Int64 = 100
        
        // Action: Add Triple
        let triple = Triple(entityId: id, attributeId: "handle", value: .string("bobby"), createdAt: timestamp)
        store.addTriple(triple, hasCardinalityOne: true)
        
        // Assert: Verify EAV structure
        // We use .first because we expect only one value for cardinality one
        let triples = store.getTriples(entity: id, attribute: "handle")
        XCTAssertEqual(triples.count, 1)
        XCTAssertEqual(triples.first?.value, .string("bobby"))
    }
    
    func testCardinalityOneAdd() async {
        let store = InstantDB.TripleStore()
        let id = UUID().uuidString
        
        // timestamp 100: Set to bobby
        let t1 = Triple(entityId: id, attributeId: "handle", value: .string("bobby"), createdAt: 100)
        store.addTriple(t1, hasCardinalityOne: true)
        
        // timestamp 200: Set to bob
        // hasCardinalityOne: true should overwrite
        let t2 = Triple(entityId: id, attributeId: "handle", value: .string("bob"), createdAt: 200)
        store.addTriple(t2, hasCardinalityOne: true)
        
        let triples = store.getTriples(entity: id, attribute: "handle")
        XCTAssertEqual(triples.count, 1)
        XCTAssertEqual(triples.first?.value, .string("bob"))
    }
    
    func testDeleteEntity() async {
        let store = InstantDB.TripleStore()
        // We need an AttrsStore for deleteEntity to work (to specific cascade/ref logic)
        // But basic delete might work?
        // Method signature: deleteEntity(_ entityId: String, attrsStore: AttrsStore)
        // We need to mock AttrsStore?
        
        // For now, let's skip delete checking in this batch or mock AttrsStore.
        // Or check retractTriple which doesn't need attrsStore?
        // retractTriple(_ triple: Triple, isRef: Bool)
        
        let id = UUID().uuidString
        let triple = Triple(entityId: id, attributeId: "handle", value: .string("bobby"), createdAt: 100)
        store.addTriple(triple, hasCardinalityOne: true)
        
        store.retractTriple(triple)
        
        let triples = store.getTriples(entity: id, attribute: "handle")
        XCTAssertTrue(triples.isEmpty)
    }

    func testLWWBehavior() async {
        let store = InstantDB.TripleStore()
        let id = UUID().uuidString
        
        // 1. Add newer value (200)
        let t1 = Triple(entityId: id, attributeId: "score", value: .int(10), createdAt: 200)
        store.addTriple(t1, hasCardinalityOne: true)
        
        // 2. Try to add older value (100)
        // Should be ignored
        let t2 = Triple(entityId: id, attributeId: "score", value: .int(5), createdAt: 100)
        store.addTriple(t2, hasCardinalityOne: true)
        
        let triples = store.getTriples(entity: id, attribute: "score")
        XCTAssertEqual(triples.count, 1)
        XCTAssertEqual(triples.first?.value, .int(10))
        XCTAssertEqual(triples.first?.createdAt, 200)
        
        // 3. Add even newer value (300)
        // Should overwrite
        let t3 = Triple(entityId: id, attributeId: "score", value: .int(15), createdAt: 300)
        store.addTriple(t3, hasCardinalityOne: true)
        
        let finalTriples = store.getTriples(entity: id, attribute: "score")
        XCTAssertEqual(finalTriples.count, 1)
        XCTAssertEqual(finalTriples.first?.value, .int(15))
        XCTAssertEqual(finalTriples.first?.createdAt, 300)
    }

    
}
