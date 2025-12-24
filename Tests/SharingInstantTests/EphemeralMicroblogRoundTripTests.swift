import Dependencies
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - Ephemeral Microblog Round-Trip Tests

/// Integration tests that run against a fresh, server-created ephemeral InstantDB app.
///
/// ## Why This Exists
/// Historically, the Microblog demo could show the author optimistically, but then
/// revert to "Unknown Author" after a server refresh. This happened when SharingInstant
/// re-emitted values by decoding from the normalized `TripleStore` and the decode path
/// did not hydrate reverse links (e.g. `posts.author` via the stored `profiles.posts` ref).
///
/// A fixed app ID is convenient, but it makes it hard to trust failures because:
/// - stale data can leak between runs
/// - schema changes can accumulate
/// - parallel runs can collide on deterministic IDs
///
/// This suite creates a brand-new ephemeral app per run and pushes a minimal schema
/// needed to reproduce the Microblog "post has author" relationship. This gives us a
/// repeatable, isolated environment that validates round-trips against the real backend.
final class EphemeralMicroblogRoundTripTests: XCTestCase {
  private struct TestHarnessError: Error {
    let message: String
  }

  private struct EphemeralAppResponse: Decodable {
    struct App: Decodable {
      let id: String
      let adminToken: String

      enum CodingKeys: String, CodingKey {
        case id
        case adminToken = "admin-token"
      }
    }

    let app: App
    let expiresMs: Int64

    enum CodingKeys: String, CodingKey {
      case app
      case expiresMs = "expires_ms"
    }
  }

  private struct EphemeralApp {
    let id: String
    let adminToken: String
  }

  private var app: EphemeralApp!
  private var store: SharedTripleStore!
  private var client: InstantClient!

  // MARK: - Setup / Teardown

  @MainActor
  override func setUp() async throws {
    try await super.setUp()

    if ProcessInfo.processInfo.environment["INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS"] != "1" {
      throw XCTSkip(
        """
        Ephemeral backend integration tests are disabled.

        Set `INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS=1` to run tests that create a fresh \
        InstantDB app on each run via `/dash/apps/ephemeral`.
        """
      )
    }

    self.app = try await Self.createEphemeralMicroblogApp()
    self.store = SharedTripleStore()

    await MainActor.run {
      InstantClientFactory.clearCache()
    }

    prepareDependencies {
      $0.context = .live
      $0.instantAppID = self.app.id
      $0.instantReactor = Reactor(store: self.store)
    }

    self.client = InstantClientFactory.makeClient(appID: self.app.id)
    self.client.connect()
    try await Self.waitUntilAuthenticated(client: self.client, timeout: 15)
  }

  @MainActor
  override func tearDown() async throws {
    client?.disconnect()
    client = nil
    store = nil
    app = nil
    try await super.tearDown()
  }

  // MARK: - Tests

  /// Reproduces the exact failure mode reported in the demo:
  /// 1. The author exists in the optimistic/UI result.
  /// 2. A later server refresh triggers a store-based re-emit (decode from triples).
  /// 3. The author must still resolve (no "Unknown Author" flip).
  @MainActor
  func testAuthorLinkSurvivesServerRefreshAndTripleStoreRoundTrip() async throws {
    @Shared(.instantSync(Schema.profiles))
    var profiles: IdentifiedArrayOf<Profile> = []

    @Shared(.instantSync(Schema.posts.with(\.author).orderBy(\.createdAt, .desc)))
    var posts: IdentifiedArrayOf<Post> = []

    let profileId = UUID().uuidString.lowercased()
    let postId = UUID().uuidString.lowercased()

    let postContentAttr = try await Self.eventuallyValue(
      timeout: 10,
      pollInterval: 0.2,
      failureMessage: "Expected schema to include the posts.content attribute."
    ) {
      self.store.attrsStore.getAttrByForwardIdent(entityType: "posts", label: "content")
    }

    let alice = Profile(
      id: profileId,
      displayName: "Alice",
      handle: "alice-\(String(profileId.prefix(8)))",
      createdAt: Date().timeIntervalSince1970
    )

    _ = $profiles.withLock { $0.append(alice) }

    try await Self.eventually(
      timeout: 15,
      pollInterval: 0.2,
      failureMessage: "Expected profile to be observable via @Shared after server sync."
    ) {
      profiles[id: profileId] != nil
    }

    let post = Post(
      id: postId,
      content: "Hello from ephemeral integration test",
      createdAt: Date().timeIntervalSince1970,
      likesCount: 0,
      author: alice
    )

    _ = $posts.withLock { $0.insert(post, at: 0) }

    try await Self.eventually(
      timeout: 20,
      pollInterval: 0.2,
      failureMessage: "Expected post.author to be non-nil in the query result."
    ) {
      posts[id: postId]?.author?.id == profileId
    }

    try await Self.eventually(
      timeout: 20,
      pollInterval: 0.2,
      failureMessage: "Expected the TripleStore to contain the post.content triple after server sync."
    ) {
      !self.store.inner.getTriples(entity: postId, attribute: postContentAttr.id).isEmpty
    }

    try await Self.eventually(
      timeout: 20,
      pollInterval: 0.2,
      failureMessage: "Expected the normalized TripleStore to contain the post and hydrate its reverse author link."
    ) {
      let decoded: Post? = self.store.get(id: postId)
      return decoded?.author?.id == profileId
    }

    let profilePostsAttr = try await Self.eventuallyValue(
      timeout: 10,
      pollInterval: 0.2,
      failureMessage: "Expected schema to include the profiles.posts link attribute."
    ) {
      self.store.attrsStore.getAttrByForwardIdent(entityType: "profiles", label: "posts")
    }

    try await Self.eventually(
      timeout: 10,
      pollInterval: 0.2,
      failureMessage: "Expected the TripleStore reverse-ref index (VAE) to include profiles.posts -> postId."
    ) {
      self.store.inner.getReverseRefs(entityId: postId, attributeId: profilePostsAttr.id)
        .contains(where: { $0.entityId == profileId })
    }

    $posts.withLock { posts in
      guard var existing = posts[id: postId] else { return }
      existing.likesCount = 1
      posts[id: postId] = existing
    }

    try await Self.eventually(
      timeout: 20,
      pollInterval: 0.2,
      failureMessage: "Expected post update to round-trip and remain queryable."
    ) {
      posts[id: postId]?.likesCount == 1
    }

    try await Self.eventually(
      timeout: 20,
      pollInterval: 0.2,
      failureMessage: "Expected author link to remain after a subsequent refresh."
    ) {
      posts[id: postId]?.author?.id == profileId
    }

    try await Self.eventually(
      timeout: 20,
      pollInterval: 0.2,
      failureMessage: "Expected author link to remain resolvable when decoding from the TripleStore after refresh."
    ) {
      let decoded: Post? = self.store.get(id: postId)
      return decoded?.author?.id == profileId
    }
  }

  // MARK: - Ephemeral App Creation

  private static func createEphemeralMicroblogApp() async throws -> EphemeralApp {
    let apiOrigin = ProcessInfo.processInfo.environment["INSTANT_TEST_API_ORIGIN"] ?? "https://api.instantdb.com"

    guard let url = URL(string: "\(apiOrigin)/dash/apps/ephemeral") else {
      throw XCTSkip("Invalid INSTANT_TEST_API_ORIGIN: \(apiOrigin)")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let schema = minimalMicroblogSchema()
    let rules: [String: Any] = [
      "profiles": [
        "allow": [
          "view": "true",
          "create": "true",
          "update": "true",
          "delete": "true",
        ],
      ],
      "posts": [
        "allow": [
          "view": "true",
          "create": "true",
          "update": "true",
          "delete": "true",
        ],
      ],
    ]

    let title = "sharing-instant-swift-ephemeral-\(UUID().uuidString.prefix(8))"
    let body: [String: Any] = [
      "title": title,
      "schema": schema,
      "rules": ["code": rules],
    ]

    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw TestHarnessError(message: "Ephemeral app creation returned a non-HTTP response.")
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
      throw TestHarnessError(
        message:
        """
        Failed to create ephemeral app.

        Status: \(httpResponse.statusCode)
        Body: \(raw)
        """
      )
    }

    let decoded = try JSONDecoder().decode(EphemeralAppResponse.self, from: data)
    return EphemeralApp(id: decoded.app.id, adminToken: decoded.app.adminToken)
  }

  private static func minimalMicroblogSchema() -> [String: Any] {
    func dataAttr(
      valueType: String,
      required: Bool,
      indexed: Bool = false,
      unique: Bool = false
    ) -> [String: Any] {
      [
        "valueType": valueType,
        "required": required,
        "isIndexed": indexed,
        "config": [
          "indexed": indexed,
          "unique": unique,
        ],
        "metadata": [:] as [String: Any],
      ]
    }

    func entityDef(
      attrs: [String: Any],
      links: [String: Any]
    ) -> [String: Any] {
      [
        "attrs": attrs,
        "links": links,
      ]
    }

    return [
      "entities": [
        "profiles": entityDef(
          attrs: [
            "displayName": dataAttr(valueType: "string", required: true),
            "handle": dataAttr(valueType: "string", required: true, indexed: true, unique: true),
            "createdAt": dataAttr(valueType: "number", required: true, indexed: true),
          ],
          links: [
            "posts": [
              "entityName": "posts",
              "cardinality": "many",
            ],
          ]
        ),
        "posts": entityDef(
          attrs: [
            "content": dataAttr(valueType: "string", required: true),
            "createdAt": dataAttr(valueType: "number", required: true, indexed: true),
            "likesCount": dataAttr(valueType: "number", required: true),
          ],
          links: [
            "author": [
              "entityName": "profiles",
              "cardinality": "one",
            ],
          ]
        ),
      ],
      "links": [
        "profilePosts": [
          "forward": [
            "on": "profiles",
            "has": "many",
            "label": "posts",
          ],
          "reverse": [
            "on": "posts",
            "has": "one",
            "label": "author",
            "onDelete": "cascade",
          ],
        ],
      ],
      "rooms": [:] as [String: Any],
    ]
  }

  // MARK: - Helpers

  @MainActor
  private static func waitUntilAuthenticated(client: InstantClient, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if client.connectionState == .authenticated {
        return
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw TestHarnessError(
      message:
        """
        Timed out waiting for InstantClient to authenticate.

        App ID: \(client.appID)
        Connection state: \(client.connectionState)
        """
    )
  }

  @MainActor
  private static func eventually(
    timeout: TimeInterval,
    pollInterval: TimeInterval,
    failureMessage: String,
    _ predicate: @escaping () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate() {
        return
      }
      try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
    XCTFail(failureMessage)
    throw TestHarnessError(message: failureMessage)
  }

  @MainActor
  private static func eventuallyValue<T>(
    timeout: TimeInterval,
    pollInterval: TimeInterval,
    failureMessage: String,
    _ producer: @escaping () -> T?
  ) async throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let value = producer() {
        return value
      }
      try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
    XCTFail(failureMessage)
    throw TestHarnessError(message: failureMessage)
  }
}
