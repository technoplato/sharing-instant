
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest
@testable import SharingInstant

@MainActor
final class RecursiveLoaderIntegrationTests: XCTestCase {
  
  static let testAppID = "f8047978-7507-4402-a0c3-f09eb2995393" // Using a dummy ID or existing shared ID
  
  func testRecursiveLoading() async throws {
    // 1. Prepare Data
    let profileId = UUID().uuidString
    let postId = UUID().uuidString
    let commentId = UUID().uuidString
    
    // Create ops manually to ensure structure matches expectation
    let now = Date().timeIntervalSince1970
    
    let profileOps: [[Any]] = [
        ["update", "profiles", profileId, ["displayName": "Recursive User", "handle": "@recursive", "createdAt": now]]
    ]
    let postOps: [[Any]] = [
        ["update", "posts", postId, ["content": "Deep Post", "likesCount": 5, "createdAt": now]]
    ]
    let commentOps: [[Any]] = [
        ["update", "comments", commentId, ["text": "Deep Reply", "createdAt": now]]
    ]
    
    // Links
    let linkOps: [[Any]] = [
        ["link", "profiles", profileId, "posts", postId],
        ["link", "posts", postId, "comments", commentId]
    ]
    
    let chunk = TransactionChunk(
        namespace: "profiles",
        id: profileId,
        ops: profileOps + postOps + commentOps + linkOps
    )
    
    // 2. Write Data
    try await Reactor.shared.transact(appID: Self.testAppID, chunks: [chunk])
    
    // 3. Subscribe using Reactor with deep query
    // Schema.profiles.limit(10).with(\.posts) { $0.limit(5).with(\.comments) }
    
    let commentsNode = EntityQueryNode.link(
        name: "comments",
        limit: nil,
        orderBy: nil,
        orderDirection: nil,
        whereClauses: [:],
        children: []
    )
    
    let postsNode = EntityQueryNode.link(
        name: "posts",
        limit: 5,
        orderBy: nil,
        orderDirection: nil,
        whereClauses: [:],
        children: [commentsNode]
    )
    
    let config = SharingInstantSync.CollectionConfiguration<Profile>(
        namespace: "profiles",
        whereClause: ["id": profileId], // Filter to our test user
        linkTree: [postsNode]
    )
    
    let stream: AsyncStream<[Profile]> = await Reactor.shared.subscribe(appID: Self.testAppID, configuration: config)
    
    // 4. Verify
    var matched = false
    for await profiles in stream {
        if let profile = profiles.first {
            if let posts = profile.posts, let post = posts.first {
                if post.content == "Deep Post" {
                    if let replies = post.comments, let reply = replies.first {
                        if reply.text == "Deep Reply" {
                            matched = true
                            break
                        }
                    }
                }
            }
        }
    }
    
    XCTAssertTrue(matched, "Failed to load recursive data")
    
    // Cleanup
    let deleteChunk = TransactionChunk(namespace: "profiles", id: profileId, ops: [["delete", "profiles", profileId]])
    try await Reactor.shared.transact(appID: Self.testAppID, chunks: [deleteChunk])
  }
}
