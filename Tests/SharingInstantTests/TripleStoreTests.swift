import Testing
@testable import SharingInstant
import Foundation

struct TripleStoreTests {
    
    struct User: Codable, EntityIdentifiable, Equatable {
        static let namespace = "users"
        var id: String
        var name: String
    }
    
    @Test
    func testMergeAndGet() async {
        let store = TripleStore()
        let user = User(id: "u1", name: "Alice")
        
        await store.merge(values: [user])
        
        let retrieved: User? = await store.get(id: "u1")
        #expect(retrieved == user)
    }
    
    actor CallbackTracker {
        var called = false
        func setCalled() { called = true }
        func wasCalled() -> Bool { called }
    }

    @Test
    func testUpdateNotifiesObservers() async {
        let store = TripleStore()
        let user1 = User(id: "u1", name: "Alice")
        await store.merge(values: [user1])
        
        let tracker = CallbackTracker()
        
        let _ = await store.addObserver(id: "u1") {
            Task { await tracker.setCalled() }
        }
        
        let user2 = User(id: "u1", name: "Alice Updated")
        await store.merge(values: [user2])
        
        // Wait a bit for async notification?
        // Notification is fired in Task within actor.
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        let wasCalled = await tracker.wasCalled()
        #expect(wasCalled)
        
        let retrieved: User? = await store.get(id: "u1")
        #expect(retrieved?.name == "Alice Updated")
    }
    
    @Test
    func testNoUpdateIfSameData() async {
        let store = TripleStore()
        let user1 = User(id: "u1", name: "Alice")
        await store.merge(values: [user1])
        
        let tracker = CallbackTracker()
        
        let _ = await store.addObserver(id: "u1") {
            Task { await tracker.setCalled() }
        }
        
        // Merge same data
        await store.merge(values: [user1])
        
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        let wasCalled = await tracker.wasCalled()
        #expect(!wasCalled)
    }
    
    @Test
    func testProfileHandling() async {
        let store = TripleStore()
        let id = UUID().uuidString
        let profile = Profile(
            id: id,
            displayName: "Test Profile",
            handle: "test",
            bio: nil,
            avatarUrl: nil,
            createdAt: 12345
        )
        
        await store.merge(values: [profile])
        
        // Use full generic retrieval
        let retrieved: Profile? = await store.get(id: id)
        
        #expect(retrieved != nil)
        #expect(retrieved?.displayName == "Test Profile")
    }
}
