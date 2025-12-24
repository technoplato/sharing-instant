import Dependencies
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - Ephemeral CaseStudies Stress Tests

/// Runs higher-stress, round-trip integration tests against a fresh, server-created ephemeral app.
///
/// ## Why This Exists
/// The CaseStudies demos intentionally exercise behaviors that are easy to get wrong:
/// - optimistic updates that later reconcile with server state
/// - linked entities (`posts.with(\.author)`) that rely on schema link metadata
/// - rapid, repeated writes that trigger multiple `refresh-ok` updates
///
/// A fixed app ID is convenient for demos, but it is a poor environment for stress tests:
/// - parallel runs collide
/// - stale data and schema drift accumulate
/// - failures are hard to attribute to a single run
///
/// Ephemeral apps provide isolation and make failures actionable.
final class EphemeralCaseStudiesStressTests: XCTestCase {
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

    enum CodingKeys: String, CodingKey {
      case app
    }
  }

  private struct EphemeralApp {
    let id: String
    let adminToken: String
  }

  private var app: EphemeralApp!
  private var store: SharedTripleStore!
  private var reactor: Reactor!
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

    self.app = try await Self.createEphemeralCaseStudiesApp()
    self.store = SharedTripleStore()
    self.reactor = Reactor(store: self.store)

    await MainActor.run {
      InstantClientFactory.clearCache()
    }

    prepareDependencies {
      $0.context = .live
      $0.instantAppID = self.app.id
      $0.instantReactor = self.reactor
    }

    self.client = InstantClientFactory.makeClient(appID: self.app.id)
    self.client.connect()
    try await Self.waitUntilAuthenticated(client: self.client, timeout: 15)
  }

  @MainActor
  override func tearDown() async throws {
    client?.disconnect()
    client = nil
    reactor = nil
    store = nil
    app = nil
    try await super.tearDown()
  }

  // MARK: - Tests

  @MainActor
  func testTodoStressMultipleCreatesAndTogglesRoundTrip() async throws {
    @Shared(.instantSync(Schema.todos.orderBy(\.createdAt, .desc)))
    var todos: IdentifiedArrayOf<Todo> = []

    let now = Date().timeIntervalSince1970
    let todoCount = 25
    let createdIds = (0..<todoCount).map { _ in UUID().uuidString.lowercased() }

    let createdTodos = zip(createdIds, 0..<todoCount).map { id, offset in
      Todo(
        id: id,
        createdAt: now + Double(offset),
        done: false,
        title: "Stress todo \(offset)"
      )
    }

    _ = $todos.withLock { todos in
      for todo in createdTodos {
        todos.insert(todo, at: 0)
      }
    }

    try await Self.eventually(
      timeout: 30,
      pollInterval: 0.2,
      failureMessage: "Expected all created todos to round-trip to the query result."
    ) {
      let idsInState = Set(todos.map(\.id))
      return Set(createdIds).isSubset(of: idsInState)
    }

    let toggledIds = Set(createdIds.prefix(todoCount / 2))

    _ = $todos.withLock { todos in
      for id in toggledIds {
        guard var existing = todos[id: id] else { continue }
        existing.done.toggle()
        todos[id: id] = existing
      }
    }

    try await Self.eventually(
      timeout: 30,
      pollInterval: 0.2,
      failureMessage: "Expected toggled todos to remain updated after server refresh."
    ) {
      toggledIds.allSatisfy { todos[id: $0]?.done == true }
    }

    try await Self.eventually(
      timeout: 30,
      pollInterval: 0.2,
      failureMessage: "Expected normalized TripleStore decoding to round-trip todo changes."
    ) {
      toggledIds.allSatisfy { id in
        let decoded: Todo? = self.store.get(id: id)
        return decoded?.done == true
      }
    }
  }

  @MainActor
  func testMicroblogStressCreateManyPostsThenSwitchAuthor() async throws {
    @Shared(.instantSync(Schema.profiles))
    var profiles: IdentifiedArrayOf<Profile> = []

    @Shared(.instantSync(Schema.posts.with(\.author).orderBy(\.createdAt, .desc)))
    var posts: IdentifiedArrayOf<Post> = []

    let now = Date().timeIntervalSince1970
    let aliceId = UUID().uuidString.lowercased()
    let bobId = UUID().uuidString.lowercased()

    let alice = Profile(
      id: aliceId,
      displayName: "Alice",
      handle: "alice-\(String(aliceId.prefix(8)))",
      createdAt: now
    )

    let bob = Profile(
      id: bobId,
      displayName: "Bob",
      handle: "bob-\(String(bobId.prefix(8)))",
      createdAt: now + 1
    )

    _ = $profiles.withLock { profiles in
      profiles.append(alice)
      profiles.append(bob)
    }

    try await Self.eventually(
      timeout: 30,
      pollInterval: 0.2,
      failureMessage: "Expected both authors to be observable via @Shared after server sync."
    ) {
      profiles[id: aliceId] != nil && profiles[id: bobId] != nil
    }

    let postCount = 20
    let postIds = (0..<postCount).map { _ in UUID().uuidString.lowercased() }
    let postsToCreate = zip(postIds, 0..<postCount).map { id, offset in
      let author = (offset % 2 == 0) ? alice : bob
      return Post(
        id: id,
        content: "Stress post \(offset)",
        createdAt: now + Double(offset),
        likesCount: 0,
        author: author
      )
    }

    _ = $posts.withLock { posts in
      for post in postsToCreate.reversed() {
        posts.insert(post, at: 0)
      }
    }

    try await Self.eventually(
      timeout: 45,
      pollInterval: 0.2,
      failureMessage: "Expected all created posts to appear with hydrated authors."
    ) {
      let idsInState = Set(posts.map(\.id))
      guard Set(postIds).isSubset(of: idsInState) else { return false }
      return postIds.allSatisfy { id in
        guard let authorId = posts[id: id]?.author?.id else { return false }
        return authorId == aliceId || authorId == bobId
      }
    }

    try await Self.eventually(
      timeout: 45,
      pollInterval: 0.2,
      failureMessage: "Expected the TripleStore decode path to hydrate reverse author links for all posts."
    ) {
      postIds.allSatisfy { id in
        let decoded: Post? = self.store.get(id: id)
        let authorId = decoded?.author?.id
        return authorId == aliceId || authorId == bobId
      }
    }

    guard let postIdToSwitch = postIds.first,
          let currentAuthorId = posts[id: postIdToSwitch]?.author?.id else {
      XCTFail("Expected at least one post to exist with an author before switching.")
      return
    }

    let newAuthorId = (currentAuthorId == aliceId) ? bobId : aliceId

    try await reactor.transact(
      appID: app.id,
      chunks: [
        TransactionChunk(
          namespace: "posts",
          id: postIdToSwitch,
          ops: [
            ["unlink", "posts", postIdToSwitch, ["author": currentAuthorId]],
            ["link", "posts", postIdToSwitch, ["author": newAuthorId]],
          ]
        ),
      ]
    )

    try await Self.eventually(
      timeout: 30,
      pollInterval: 0.2,
      failureMessage: "Expected switching author to round-trip and update query results."
    ) {
      posts[id: postIdToSwitch]?.author?.id == newAuthorId
    }

    try await Self.eventually(
      timeout: 30,
      pollInterval: 0.2,
      failureMessage: "Expected switching author to be reflected when decoding from the TripleStore."
    ) {
      let decoded: Post? = self.store.get(id: postIdToSwitch)
      return decoded?.author?.id == newAuthorId
    }
  }

  // MARK: - Ephemeral App Creation

  private static func createEphemeralCaseStudiesApp() async throws -> EphemeralApp {
    let apiOrigin = ProcessInfo.processInfo.environment["INSTANT_TEST_API_ORIGIN"] ?? "https://api.instantdb.com"

    guard let url = URL(string: "\(apiOrigin)/dash/apps/ephemeral") else {
      throw XCTSkip("Invalid INSTANT_TEST_API_ORIGIN: \(apiOrigin)")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let schema = minimalCaseStudiesSchema()
    let rules: [String: Any] = [
      "todos": [
        "allow": [
          "view": "true",
          "create": "true",
          "update": "true",
          "delete": "true",
        ],
      ],
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

    let title = "sharing-instant-case-studies-\(UUID().uuidString.prefix(8))"
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

  private static func minimalCaseStudiesSchema() -> [String: Any] {
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
        "todos": entityDef(
          attrs: [
            "createdAt": dataAttr(valueType: "number", required: true, indexed: true),
            "done": dataAttr(valueType: "boolean", required: true),
            "title": dataAttr(valueType: "string", required: true),
          ],
          links: [:]
        ),
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
}
