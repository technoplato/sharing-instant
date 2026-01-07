import InstantDB
import XCTest

@testable import SharingInstant

final class TripleStoreReverseLinkResolutionTests: XCTestCase {
  func testDecodingReverseLinkAuthorFromProfilePosts() async throws {
    let attrsStore = AttrsStore()

    func makeAttribute(
      id: String,
      forwardIdentity: [String],
      reverseIdentity: [String]? = nil,
      valueType: String,
      cardinality: String,
      unique: Bool? = nil,
      indexed: Bool? = nil
    ) throws -> Attribute {
      var dict: [String: Any] = [
        "id": id,
        "forward-identity": forwardIdentity,
        "value-type": valueType,
        "cardinality": cardinality,
      ]

      if let reverseIdentity {
        dict["reverse-identity"] = reverseIdentity
      }

      if let unique {
        dict["unique"] = unique
      }

      if let indexed {
        dict["indexed"] = indexed
      }

      let data = try JSONSerialization.data(withJSONObject: dict)
      return try JSONDecoder().decode(Attribute.self, from: data)
    }

    let profileDisplayName = try makeAttribute(
      id: "attr-profiles-displayName",
      forwardIdentity: ["ident-profiles-displayName", "profiles", "displayName"],
      valueType: "string",
      cardinality: "one"
    )

    let profileHandle = try makeAttribute(
      id: "attr-profiles-handle",
      forwardIdentity: ["ident-profiles-handle", "profiles", "handle"],
      valueType: "string",
      cardinality: "one"
    )

    let profileCreatedAt = try makeAttribute(
      id: "attr-profiles-createdAt",
      forwardIdentity: ["ident-profiles-createdAt", "profiles", "createdAt"],
      valueType: "number",
      cardinality: "one"
    )

    let postContent = try makeAttribute(
      id: "attr-posts-content",
      forwardIdentity: ["ident-posts-content", "posts", "content"],
      valueType: "string",
      cardinality: "one"
    )

    let postCreatedAt = try makeAttribute(
      id: "attr-posts-createdAt",
      forwardIdentity: ["ident-posts-createdAt", "posts", "createdAt"],
      valueType: "number",
      cardinality: "one"
    )

    let profilePosts = try makeAttribute(
      id: "attr-profiles-posts",
      forwardIdentity: ["ident-profiles-posts", "profiles", "posts"],
      reverseIdentity: ["ident-posts-author", "posts", "author"],
      valueType: "ref",
      cardinality: "many"
    )

    attrsStore.addAttr(profileDisplayName)
    attrsStore.addAttr(profileHandle)
    attrsStore.addAttr(profileCreatedAt)
    attrsStore.addAttr(postContent)
    attrsStore.addAttr(postCreatedAt)
    attrsStore.addAttr(profilePosts)

    let store = InstantDB.TripleStore()
    let timestamp: Int64 = 0
    let profileId = "profile-alice"
    let postId = "post-1"

    store.addTriple(
      Triple(
        entityId: profileId,
        attributeId: profileDisplayName.id,
        value: .string("Alice"),
        createdAt: timestamp
      ),
      hasCardinalityOne: true
    )

    store.addTriple(
      Triple(
        entityId: profileId,
        attributeId: profileHandle.id,
        value: .string("alice"),
        createdAt: timestamp
      ),
      hasCardinalityOne: true
    )

    store.addTriple(
      Triple(
        entityId: profileId,
        attributeId: profileCreatedAt.id,
        value: .double(123),
        createdAt: timestamp
      ),
      hasCardinalityOne: true
    )

    store.addTriple(
      Triple(
        entityId: postId,
        attributeId: postContent.id,
        value: .string("Hello"),
        createdAt: timestamp
      ),
      hasCardinalityOne: true
    )

    store.addTriple(
      Triple(
        entityId: postId,
        attributeId: postCreatedAt.id,
        value: .double(456),
        createdAt: timestamp
      ),
      hasCardinalityOne: true
    )

    store.addTriple(
      Triple(
        entityId: profileId,
        attributeId: profilePosts.id,
        value: .ref(postId),
        createdAt: timestamp
      ),
      hasCardinalityOne: false,
      isRef: true
    )

    let decodedPost: Post? = store.get(id: postId, attrsStore: attrsStore)

    XCTAssertNotNil(decodedPost, "Post should decode successfully from TripleStore")
    XCTAssertEqual(decodedPost?.id, postId)

    XCTAssertNotNil(decodedPost?.author, "Post.author should resolve from reverse link (profiles.posts ↔ posts.author)")
    XCTAssertEqual(decodedPost?.author?.id, profileId)
    XCTAssertEqual(decodedPost?.author?.handle, "alice")
  }
}
