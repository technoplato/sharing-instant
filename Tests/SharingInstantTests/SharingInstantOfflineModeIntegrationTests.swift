import Dependencies
import Foundation
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - SharingInstantOfflineModeIntegrationTests

/// Integration tests that validate SharingInstant's offline mode behavior end-to-end.
///
/// ## Why These Tests Exist
/// SharingInstant is a higher-level layer over the InstantDB iOS SDK:
/// - it powers UI updates via a normalized TripleStore
/// - it applies optimistic updates immediately (local-first UX)
/// - it relies on the SDK for durable persistence + queued mutations when offline
///
/// The JavaScript client stack treats online/offline as a first-class state derived from a
/// network listener (not from manual `disconnect()` calls). These tests enforce the same model
/// in Swift by injecting a `NetworkMonitorClient.mock(...)` and toggling connectivity during a
/// single test.
///
/// ## Server Truth
/// These tests intentionally use the InstantDB Admin HTTP API (`/admin/query`, `/admin/transact`)
/// as the source of truth for server state. This avoids:
/// - client-side query caching
/// - WebSocket reconnection races
/// - "did the query subscription refresh yet?" flakiness
final class SharingInstantOfflineModeIntegrationTests: XCTestCase {
  private static let timeout: TimeInterval = 30.0

  // MARK: - Merge + Conflict Semantics

  /// Verifies that non-conflicting field updates merge after an offline period.
  ///
  /// Scenario:
  /// - Client A (SharingInstant) goes offline and updates `title`.
  /// - Client B (Admin/transact) stays online and updates `done`.
  /// - When Client A reconnects, its queued `title` mutation flushes.
  ///
  /// Expected final server state:
  /// - `title` reflects Client A's offline write
  /// - `done` reflects Client B's online write
  ///
  /// This test fails if Client A flushes a full-entity snapshot (which could clobber
  /// `done` back to its stale offline value).
  @MainActor
  func testOfflineNonConflictingFieldUpdatesMergeAfterReconnect() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-offline-merge",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )

    InstantClientFactory.clearCache()

    let admin = InstantAdminAPI(appID: app.id, adminToken: app.adminToken)

    let store = SharedTripleStore()
    let clientInstanceID = "sharing-offline-merge-\(UUID().uuidString.prefix(8))"
    let reactor = Reactor(store: store, clientInstanceID: clientInstanceID)

    let (networkMonitor, setOnline) = NetworkMonitorClient.mock(initiallyOnline: true)

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = app.id
      $0.instantReactor = reactor
      $0.instantEnableLocalPersistence = true
      $0.instantNetworkMonitor = networkMonitor
    } operation: {
      @Shared(.instantSync(Schema.todos))
      var todos: IdentifiedArrayOf<Todo> = []

      @Dependency(\.instantReactor) var reactor

      let clientA = await MainActor.run {
        InstantClientFactory.makeClient(appID: app.id, instanceID: clientInstanceID)
      }
      try await InstantTestAuth.signInAsGuestAndReconnect(client: clientA, timeout: Self.timeout)
      try await waitForSchemaAttributes(clientA, timeout: Self.timeout)

      let todoId = UUID().uuidString.lowercased()
      let now = Date().timeIntervalSince1970
      let initialTitle = "initial-\(UUID().uuidString)"

      try await admin.transact(steps: [[
        "update", "todos", todoId, [
          "createdAt": now,
          "done": false,
          "title": initialTitle,
        ],
      ]])

      _ = try await waitForAdminTodo(
        admin,
        todoId: todoId,
        timeout: Self.timeout,
        expectationDescription: "initial create (title == initialTitle, done == false)",
        predicate: { todo in
          todo.title == initialTitle && todo.done == false
        }
      )

      try await waitForTodoInLocalResults(id: todoId, todos: { todos }, timeout: Self.timeout)

      setOnline(false)
      try await waitForDisconnected(clientA, timeout: Self.timeout)

      try await admin.transact(steps: [[
        "update", "todos", todoId, [
          "done": true,
        ],
      ]])

      _ = try await waitForAdminTodo(
        admin,
        todoId: todoId,
        timeout: Self.timeout,
        expectationDescription: "server updated done == true",
        predicate: { todo in
          todo.done == true
        }
      )

      let offlineTitle = "offline-\(UUID().uuidString)"
      try await reactor.transact(
        appID: app.id,
        chunks: [
          TransactionChunk(
            namespace: "todos",
            id: todoId,
            ops: [[
              "update", "todos", todoId, [
                "title": offlineTitle,
              ],
            ]]
          )
        ]
      )

      try await waitForTodoTitleInLocalResults(
        id: todoId,
        expectedTitle: offlineTitle,
        todos: { todos },
        timeout: Self.timeout
      )

      setOnline(true)
      try await InstantTestAuth.waitForAuthenticated(clientA, timeout: Self.timeout)

      let serverResult = try await waitForAdminTodo(
        admin,
        todoId: todoId,
        timeout: Self.timeout,
        expectationDescription: "post-reconnect merge (title == offlineTitle, done == true)",
        predicate: { todo in
          todo.title == offlineTitle && todo.done == true
        }
      )

      XCTAssertEqual(serverResult.title, offlineTitle)
      XCTAssertEqual(serverResult.done, true)

      // Cleanup
      try await admin.transact(steps: [["delete", "todos", todoId]])
    }
  }

  /// Verifies Last-Write-Wins (LWW) semantics for conflicting field updates.
  ///
  /// Scenario:
  /// - Client A (SharingInstant) goes offline and updates `title = offlineTitle`.
  /// - Client B (Admin/transact) stays online and later updates `title = serverTitle`.
  /// - Client A reconnects; its queued mutation flushes after the server mutation.
  ///
  /// Expected final server state:
  /// - `title == offlineTitle` (the last-applied write wins; the offline mutation is applied last).
  ///
  /// ## Why This Is The Expected Result
  /// InstantDB's LWW semantics are driven by server-assigned timestamps when a transaction is
  /// processed. An offline mutation does not "reserve" its timestamp at the time the user types;
  /// it receives a timestamp when it is later flushed and accepted by the server.
  ///
  /// This mirrors the JavaScript client behavior: queued offline mutations are replayed on
  /// reconnect and can overwrite server changes that happened while the client was offline.
  @MainActor
  func testOfflineConflictingFieldUpdatesUseLastWriteWinsAfterReconnect() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-offline-lww",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )

    InstantClientFactory.clearCache()

    let admin = InstantAdminAPI(appID: app.id, adminToken: app.adminToken)

    let store = SharedTripleStore()
    let clientInstanceID = "sharing-offline-lww-\(UUID().uuidString.prefix(8))"
    let reactor = Reactor(store: store, clientInstanceID: clientInstanceID)

    let (networkMonitor, setOnline) = NetworkMonitorClient.mock(initiallyOnline: true)

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = app.id
      $0.instantReactor = reactor
      $0.instantEnableLocalPersistence = true
      $0.instantNetworkMonitor = networkMonitor
    } operation: {
      @Shared(.instantSync(Schema.todos))
      var todos: IdentifiedArrayOf<Todo> = []

      @Dependency(\.instantReactor) var reactor

      let clientA = await MainActor.run {
        InstantClientFactory.makeClient(appID: app.id, instanceID: clientInstanceID)
      }
      try await InstantTestAuth.signInAsGuestAndReconnect(client: clientA, timeout: Self.timeout)
      try await waitForSchemaAttributes(clientA, timeout: Self.timeout)

      let todoId = UUID().uuidString.lowercased()
      let now = Date().timeIntervalSince1970
      let initialTitle = "initial-\(UUID().uuidString)"

      try await admin.transact(steps: [[
        "update", "todos", todoId, [
          "createdAt": now,
          "done": false,
          "title": initialTitle,
        ],
      ]])

      _ = try await waitForAdminTodo(
        admin,
        todoId: todoId,
        timeout: Self.timeout,
        expectationDescription: "initial create (title == initialTitle)",
        predicate: { todo in
          todo.title == initialTitle
        }
      )

      try await waitForTodoInLocalResults(id: todoId, todos: { todos }, timeout: Self.timeout)

      setOnline(false)
      try await waitForDisconnected(clientA, timeout: Self.timeout)

      let offlineTitle = "offline-\(UUID().uuidString)"
      try await reactor.transact(
        appID: app.id,
        chunks: [
          TransactionChunk(
            namespace: "todos",
            id: todoId,
            ops: [[
              "update", "todos", todoId, [
                "title": offlineTitle,
              ],
            ]]
          )
        ]
      )

      try await waitForTodoTitleInLocalResults(
        id: todoId,
        expectedTitle: offlineTitle,
        todos: { todos },
        timeout: Self.timeout
      )

      let serverTitle = "server-\(UUID().uuidString)"
      try await admin.transact(steps: [[
        "update", "todos", todoId, [
          "title": serverTitle,
        ],
      ]])

      _ = try await waitForAdminTodo(
        admin,
        todoId: todoId,
        timeout: Self.timeout,
        expectationDescription: "server updated title == serverTitle",
        predicate: { todo in
          todo.title == serverTitle
        }
      )

      setOnline(true)
      try await InstantTestAuth.waitForAuthenticated(clientA, timeout: Self.timeout)

      let serverResult = try await waitForAdminTodo(
        admin,
        todoId: todoId,
        timeout: Self.timeout,
        expectationDescription: "post-reconnect LWW (title == offlineTitle)",
        predicate: { todo in
          todo.title == offlineTitle
        }
      )

      XCTAssertEqual(serverResult.title, offlineTitle)

      // Cleanup
      try await admin.transact(steps: [["delete", "todos", todoId]])
    }
  }

  /// Verifies that multiple rapid updates performed while offline converge to the final value
  /// once connectivity returns.
  ///
  /// ## Why This Test Exists
  /// This models a common offline scenario:
  /// - a user types quickly in a text field while the device is offline
  /// - we perform multiple "patch" updates to the same entity field
  /// - when we reconnect, we replay pending mutations in order
  ///
  /// If replay order is broken, or if mutations are accidentally dropped, the server can end up
  /// with an intermediate value instead of the final one.
  @MainActor
  func testOfflineRapidRepeatedFieldUpdatesConvergeToLastValue() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-offline-rapid-updates",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )

    InstantClientFactory.clearCache()

    let admin = InstantAdminAPI(appID: app.id, adminToken: app.adminToken)

    let store = SharedTripleStore()
    let clientInstanceID = "sharing-offline-rapid-\(UUID().uuidString.prefix(8))"
    let reactor = Reactor(store: store, clientInstanceID: clientInstanceID)

    let (networkMonitor, setOnline) = NetworkMonitorClient.mock(initiallyOnline: true)

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = app.id
      $0.instantReactor = reactor
      $0.instantEnableLocalPersistence = true
      $0.instantNetworkMonitor = networkMonitor
    } operation: {
      @Shared(.instantSync(Schema.todos))
      var todos: IdentifiedArrayOf<Todo> = []

      let clientA = await MainActor.run {
        InstantClientFactory.makeClient(appID: app.id, instanceID: clientInstanceID)
      }
      try await InstantTestAuth.signInAsGuestAndReconnect(client: clientA, timeout: Self.timeout)
      try await waitForSchemaAttributes(clientA, timeout: Self.timeout)

      let todoId = UUID().uuidString.lowercased()
      let now = Date().timeIntervalSince1970
      let initialTitle = "initial-\(UUID().uuidString)"

      try await admin.transact(steps: [[
        "update", "todos", todoId, [
          "createdAt": now,
          "done": false,
          "title": initialTitle,
        ],
      ]])

      _ = try await waitForAdminTodo(
        admin,
        todoId: todoId,
        timeout: Self.timeout,
        expectationDescription: "initial create (title == initialTitle)",
        predicate: { todo in
          todo.title == initialTitle
        }
      )

      try await waitForTodoInLocalResults(id: todoId, todos: { todos }, timeout: Self.timeout)

      setOnline(false)
      try await waitForDisconnected(clientA, timeout: Self.timeout)

      // Simulates typing "Testing": T -> Te -> Tes -> Test -> Testing
      let updateTitles = ["T", "Te", "Tes", "Test", "Testing"]
      let finalTitle = updateTitles.last!

      for title in updateTitles {
        try await $todos.update(id: todoId) { todo in
          todo.title = title
        }
        try await Task.sleep(nanoseconds: 50_000_000)
      }

      try await waitForTodoTitleInLocalResults(
        id: todoId,
        expectedTitle: finalTitle,
        todos: { todos },
        timeout: Self.timeout
      )

      setOnline(true)
      try await InstantTestAuth.waitForAuthenticated(clientA, timeout: Self.timeout)

      let serverTodo = try await waitForAdminTodo(
        admin,
        todoId: todoId,
        timeout: Self.timeout,
        expectationDescription: "post-reconnect final title == \(finalTitle)",
        predicate: { todo in
          todo.title == finalTitle
        }
      )

      XCTAssertEqual(serverTodo.title, finalTitle)

      // Cleanup
      try await admin.transact(steps: [["delete", "todos", todoId]])
    }
  }

  /// Ensures a `link` mutation is not dropped when rapid upserts/patches are queued for the same entity.
  ///
  /// ## Why This Test Exists
  /// SpeechRecorderApp creates an entity (e.g. `TranscriptionRun` or `TranscriptionSegment`), then links it,
  /// and then immediately performs rapid updates while the create/link operations are still in-flight.
  ///
  /// If the mutation serializer only retains the "latest pending mutation", it can accidentally drop the
  /// `link` operation (because a later patch update overwrote the pending slot).
  ///
  /// This produces the exact user-visible symptom we saw in the app:
  /// - the entity exists on the server
  /// - but it is not linked, so nested queries show an empty relationship
  @MainActor
  func testOfflineLinkIsNotDroppedWhenCoalescingUpserts() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-offline-link-coalesce",
      schema: EphemeralAppFactory.minimalMicroblogSchema(),
      rules: EphemeralAppFactory.openRules(for: ["profiles", "posts"])
    )

    InstantClientFactory.clearCache()

    let admin = InstantAdminAPI(appID: app.id, adminToken: app.adminToken)

    let store = SharedTripleStore()
    let clientInstanceID = "sharing-offline-link-coalesce-\(UUID().uuidString.prefix(8))"
    let reactor = Reactor(store: store, clientInstanceID: clientInstanceID)

    let (networkMonitor, setOnline) = NetworkMonitorClient.mock(initiallyOnline: true)

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = app.id
      $0.instantReactor = reactor
      $0.instantEnableLocalPersistence = true
      $0.instantNetworkMonitor = networkMonitor
    } operation: {
      @Shared(.instantSync(Schema.profiles))
      var profiles: IdentifiedArrayOf<Profile> = []

      @Shared(.instantSync(Schema.posts.with(\.author)))
      var posts: IdentifiedArrayOf<Post> = []

      let clientA = await MainActor.run {
        InstantClientFactory.makeClient(appID: app.id, instanceID: clientInstanceID)
      }
      try await InstantTestAuth.signInAsGuestAndReconnect(client: clientA, timeout: Self.timeout)
      try await waitForSchemaAttributes(clientA, timeout: Self.timeout)

      let profileId = UUID().uuidString.lowercased()
      let now = Date().timeIntervalSince1970 * 1_000

      try await admin.transact(steps: [[
        "update", "profiles", profileId, [
          "createdAt": now,
          "displayName": "Maestro Author",
          "handle": "maestro_author_\(profileId.prefix(8))",
        ],
      ]])

      try await waitForProfileInLocalResults(id: profileId, profiles: { profiles }, timeout: Self.timeout)

      setOnline(false)
      try await waitForDisconnected(clientA, timeout: Self.timeout)

      let postId = UUID().uuidString.lowercased()
      let initialContent = "initial-\(UUID().uuidString.prefix(8))"

      // Fire create/link/patch updates in separate Tasks to mimic app-level "fire-and-forget" behavior.
      // The important property: these mutations overlap while the per-entity serializer is active.
      let createTask = Task { @MainActor in
        try await $posts.create(
          Post(
            id: postId,
            content: initialContent,
            createdAt: now
          )
        )
      }

      await Task.yield()

      let linkTask = Task { @MainActor in
        try await $posts.link(postId, "author", to: profileId, namespace: "profiles")
      }

      await Task.yield()

      let updateContents = ["one", "two", "three", "four", "five"]
      let finalContent = updateContents.last!

      // Use updateField() instead of update() with closure because:
      // 1. It doesn't need to read the entity first (no entityNotFound race)
      // 2. It matches the real-world pattern of rapid field updates (e.g., typing)
      // 3. The closure-based update() is for when you need to compute changes,
      //    but here we know exactly what field we're setting
      let updateTasks = updateContents.map { content in
        Task { @MainActor in
          try await $posts.updateField(id: postId, field: "content", value: content)
        }
      }

      try await createTask.value
      try await linkTask.value
      for task in updateTasks {
        try await task.value
      }

      try await waitForPostContentInLocalResults(
        id: postId,
        expectedContent: finalContent,
        posts: { posts },
        timeout: Self.timeout
      )

      setOnline(true)
      try await InstantTestAuth.waitForAuthenticated(clientA, timeout: Self.timeout)

      let (serverContent, serverAuthorId) = try await waitForAdminPostContentAndAuthor(
        admin,
        postId: postId,
        timeout: Self.timeout,
        expectationDescription: "post-reconnect author link + final content",
        predicate: { content, authorId in
          content == finalContent && authorId?.lowercased() == profileId.lowercased()
        }
      )

      XCTAssertEqual(serverContent, finalContent)
      XCTAssertEqual(serverAuthorId?.lowercased(), profileId.lowercased())

      // Cleanup
      try await admin.transact(steps: [["delete", "posts", postId]])
      try await admin.transact(steps: [["delete", "profiles", profileId]])
    }
  }

  /// Ensures "create both sides + link" works while offline, and that reverse links update locally.
  ///
  /// ## Why This Test Exists
  /// SpeechRecorderApp does this exact shape (just with different entity names):
  /// - Create `Media`
  /// - Create `TranscriptionRun`
  /// - Link `TranscriptionRun.media -> Media`
  /// - UI is driven by the reverse view (`Media.transcriptionRuns`)
  ///
  /// We previously observed a class of bugs where:
  /// - entities exist (eventually) on the server after reconnect
  /// - but the relationship is missing or the reverse link view does not update locally
  ///
  /// This test makes the scenario deterministic by:
  /// - forcing offline before create/link
  /// - asserting the reverse link view updates *while still offline*
  /// - then asserting server truth after reconnect via the Admin API
  @MainActor
  func testOfflineCreateThenLinkUpdatesReverseLinkLocallyAndPersistsToServer() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-offline-create-link-reverse",
      schema: EphemeralAppFactory.minimalMicroblogSchema(),
      rules: EphemeralAppFactory.openRules(for: ["profiles", "posts"])
    )

    InstantClientFactory.clearCache()

    let admin = InstantAdminAPI(appID: app.id, adminToken: app.adminToken)

    let store = SharedTripleStore()
    let clientInstanceID = "sharing-offline-create-link-\(UUID().uuidString.prefix(8))"
    let reactor = Reactor(store: store, clientInstanceID: clientInstanceID)

    let (networkMonitor, setOnline) = NetworkMonitorClient.mock(initiallyOnline: true)

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = app.id
      $0.instantReactor = reactor
      $0.instantEnableLocalPersistence = true
      $0.instantNetworkMonitor = networkMonitor
    } operation: {
      @Shared(.instantSync(Schema.profiles.with(\.posts)))
      var profiles: IdentifiedArrayOf<Profile> = []

      @Shared(.instantSync(Schema.posts.with(\.author)))
      var posts: IdentifiedArrayOf<Post> = []

      let clientA = await MainActor.run {
        InstantClientFactory.makeClient(appID: app.id, instanceID: clientInstanceID)
      }
      try await InstantTestAuth.signInAsGuestAndReconnect(client: clientA, timeout: Self.timeout)
      try await waitForSchemaAttributes(clientA, timeout: Self.timeout)

      setOnline(false)
      try await waitForDisconnected(clientA, timeout: Self.timeout)

      let profileId = UUID().uuidString.lowercased()
      let postId = UUID().uuidString.lowercased()
      let nowMs = Date().timeIntervalSince1970 * 1_000

      try await $profiles.create(
        Profile(
          id: profileId,
          createdAt: nowMs,
          displayName: "Offline Creator",
          handle: "offline_creator_\(profileId.prefix(8))"
        )
      )

      try await $posts.create(
        Post(
          id: postId,
          content: "offline linked post",
          createdAt: nowMs
        )
      )

      // Link while offline.
      try await $posts.link(postId, "author", to: profileId, namespace: "profiles")

      // Assert local (offline) reverse link updates.
      let deadline = Date().addingTimeInterval(Self.timeout)
      while Date() < deadline {
        let profilePosts = profiles[id: profileId]?.posts ?? []
        if profilePosts.contains(where: { $0.id.lowercased() == postId.lowercased() }) {
          break
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      }

      XCTAssertTrue(
        (profiles[id: profileId]?.posts ?? []).contains(where: { $0.id.lowercased() == postId.lowercased() }),
        "Reverse link view (Profile.posts) should include the linked Post while offline."
      )

      // Come back online and assert server truth via Admin API (no client caching).
      setOnline(true)
      try await InstantTestAuth.waitForAuthenticated(clientA, timeout: Self.timeout)

      let (_, serverAuthorId) = try await waitForAdminPostContentAndAuthor(
        admin,
        postId: postId,
        timeout: Self.timeout,
        expectationDescription: "post-reconnect author link present",
        predicate: { _, authorId in
          authorId?.lowercased() == profileId.lowercased()
        }
      )

      XCTAssertEqual(serverAuthorId?.lowercased(), profileId.lowercased())

      // Cleanup
      try await admin.transact(steps: [["delete", "posts", postId]])
      try await admin.transact(steps: [["delete", "profiles", profileId]])
    }
  }

  // MARK: - Helpers

  @MainActor
  private func waitForSchemaAttributes(_ client: InstantClient, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if !client.attributes.isEmpty { return }

      if case .error(let error) = client.connectionState {
        throw error
      }

      try await Task.sleep(nanoseconds: 100_000_000)
    }

    XCTFail("Timed out waiting for schema attributes.")
  }

  @MainActor
  private func waitForDisconnected(_ client: InstantClient, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if client.connectionState == .disconnected { return }

      if case .error(let error) = client.connectionState {
        throw error
      }

      try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTFail("Timed out waiting for client to transition to disconnected.")
  }

  @MainActor
  private func waitForTodoInLocalResults(
    id: String,
    todos: () -> IdentifiedArrayOf<Todo>,
    timeout: TimeInterval
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if todos()[id: id] != nil { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTFail("Timed out waiting for Todo to appear in SharingInstant local results.")
  }

  @MainActor
  private func waitForTodoTitleInLocalResults(
    id: String,
    expectedTitle: String,
    todos: () -> IdentifiedArrayOf<Todo>,
    timeout: TimeInterval
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if todos()[id: id]?.title == expectedTitle { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTFail("Timed out waiting for Todo title to update in SharingInstant local results.")
  }

  @MainActor
  private func waitForAdminTodo(
    _ admin: InstantAdminAPI,
    todoId: String,
    timeout: TimeInterval,
    expectationDescription: String? = nil,
    predicate: ((Todo) -> Bool)? = nil
  ) async throws -> Todo {
    let deadline = Date().addingTimeInterval(timeout)
    var lastSeenTodo: Todo?

    while Date() < deadline {
      let todos = try await admin.queryTodos(where: ["id": todoId])
      if let todo = todos.first(where: { $0.id.lowercased() == todoId.lowercased() }) {
        lastSeenTodo = todo
        if let predicate, !predicate(todo) {
          try await Task.sleep(nanoseconds: 200_000_000)
          continue
        }
        return todo
      }
      try await Task.sleep(nanoseconds: 200_000_000)
    }

    let expectationText = expectationDescription.map { " (\($0))" } ?? ""
    if let lastSeenTodo {
      XCTFail(
        """
        Timed out waiting for admin query Todo to satisfy expectation: \(todoId)\(expectationText)

        Last seen:
          title: \(lastSeenTodo.title)
          done: \(lastSeenTodo.done)
          createdAt: \(lastSeenTodo.createdAt)
        """
      )
    } else {
      XCTFail("Timed out waiting for admin query to contain Todo: \(todoId)\(expectationText)")
    }

    throw NSError(domain: "SharingInstantOfflineModeIntegrationTests", code: 1)
  }

  @MainActor
  private func waitForProfileInLocalResults(
    id: String,
    profiles: () -> IdentifiedArrayOf<Profile>,
    timeout: TimeInterval
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if profiles()[id: id] != nil { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTFail("Timed out waiting for Profile to appear in SharingInstant local results.")
  }

  @MainActor
  private func waitForPostContentInLocalResults(
    id: String,
    expectedContent: String,
    posts: () -> IdentifiedArrayOf<Post>,
    timeout: TimeInterval
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if posts()[id: id]?.content == expectedContent { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTFail("Timed out waiting for Post content to update in SharingInstant local results.")
  }

  @MainActor
  private func waitForAdminPostContentAndAuthor(
    _ admin: InstantAdminAPI,
    postId: String,
    timeout: TimeInterval,
    expectationDescription: String? = nil,
    predicate: ((_ content: String?, _ authorId: String?) -> Bool)? = nil
  ) async throws -> (content: String?, authorId: String?) {
    let deadline = Date().addingTimeInterval(timeout)
    var lastSeen: (content: String?, authorId: String?)?

    while Date() < deadline {
      let row = try await admin.queryPostRow(postId: postId)
      let content = row?["content"] as? String
      let authorId = admin.extractLinkId(from: row?["author"])

      lastSeen = (content: content, authorId: authorId)

      if let predicate, !predicate(content, authorId) {
        try await Task.sleep(nanoseconds: 200_000_000)
        continue
      }

      if row != nil {
        return (content: content, authorId: authorId)
      }

      try await Task.sleep(nanoseconds: 200_000_000)
    }

    let expectationText = expectationDescription.map { " (\($0))" } ?? ""
    if let lastSeen {
      XCTFail(
        """
        Timed out waiting for admin query Post to satisfy expectation: \(postId)\(expectationText)

        Last seen:
          content: \(lastSeen.content ?? "<nil>")
          authorId: \(lastSeen.authorId ?? "<nil>")
        """
      )
    } else {
      XCTFail("Timed out waiting for admin query to contain Post: \(postId)\(expectationText)")
    }

    throw NSError(domain: "SharingInstantOfflineModeIntegrationTests", code: 2)
  }
}

// MARK: - InstantAdminAPI (Test-Only)

/// Minimal Swift wrapper over the InstantDB Admin HTTP API.
///
/// ## Why This Exists
/// This test suite needs a server-side source of truth that is independent of:
/// - the Swift iOS SDK's WebSocket connection state
/// - client-side caching and subscriptions
///
/// The admin API provides deterministic reads/writes for integration verification.
private struct InstantAdminAPI {
  let appID: String
  let adminToken: String
  let apiOrigin: String

  init(appID: String, adminToken: String) {
    self.appID = appID
    self.adminToken = adminToken
    self.apiOrigin = ProcessInfo.processInfo.environment["INSTANT_TEST_API_ORIGIN"] ?? "https://api.instantdb.com"
  }

  func query(_ query: [String: Any]) async throws -> [String: Any] {
    guard let url = URL(string: "\(apiOrigin)/admin/query") else {
      throw NSError(domain: "InstantAdminAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid apiOrigin: \(apiOrigin)"])
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(appID, forHTTPHeaderField: "app-id")
    request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")

    let body: [String: Any] = [
      "query": query,
      "inference?": false,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(domain: "InstantAdminAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
      throw NSError(domain: "InstantAdminAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Admin query failed (\(httpResponse.statusCode)): \(raw)"])
    }

    let json = try JSONSerialization.jsonObject(with: data, options: [])
    return (json as? [String: Any]) ?? [:]
  }

  func transact(steps: [[Any]]) async throws {
    guard let url = URL(string: "\(apiOrigin)/admin/transact") else {
      throw NSError(domain: "InstantAdminAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid apiOrigin: \(apiOrigin)"])
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(appID, forHTTPHeaderField: "app-id")
    request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")

    let body: [String: Any] = [
      "steps": steps,
      "throw-on-missing-attrs?": false,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let (_, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(domain: "InstantAdminAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw NSError(domain: "InstantAdminAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Admin transact failed (\(httpResponse.statusCode))"])
    }
  }

  func queryTodos(where clause: [String: Any]) async throws -> [Todo] {
    let instaqlQuery: [String: Any] = [
      "todos": [
        "$": [
          "where": clause
        ]
      ]
    ]

    let response = try await query(instaqlQuery)
    guard let rawTodos = response["todos"] else { return [] }

    let list: [[String: Any]]
    if let arr = rawTodos as? [[String: Any]] {
      list = arr
    } else if let single = rawTodos as? [String: Any] {
      list = [single]
    } else {
      return []
    }

    let data = try JSONSerialization.data(withJSONObject: list, options: [])
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode([Todo].self, from: data)
  }

  func queryPostRow(postId: String) async throws -> [String: Any]? {
    let instaqlQuery: [String: Any] = [
      "posts": [
        "$": [
          "where": ["id": postId]
        ],
        // Include author so the response contains link data deterministically.
        "author": [:] as [String: Any],
      ]
    ]

    let response = try await query(instaqlQuery)
    guard let rawPosts = response["posts"] else { return nil }

    let rows: [[String: Any]]
    if let arr = rawPosts as? [[String: Any]] {
      rows = arr
    } else if let single = rawPosts as? [String: Any] {
      rows = [single]
    } else {
      return nil
    }

    return rows.first(where: { ($0["id"] as? String)?.lowercased() == postId.lowercased() })
  }

  func extractLinkId(from value: Any?) -> String? {
    if let id = value as? String {
      return id
    }

    if let dict = value as? [String: Any], let id = dict["id"] as? String {
      return id
    }

    // Some server responses represent one-to-one links as arrays.
    if let arr = value as? [[String: Any]], let first = arr.first, let id = first["id"] as? String {
      return id
    }

    return nil
  }
}
