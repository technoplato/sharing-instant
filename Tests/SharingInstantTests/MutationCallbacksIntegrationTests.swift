// MutationCallbacksIntegrationTests.swift
// SharingInstantTests
//
// Integration tests for the Generated Mutations API with real InstantDB backend.
//
// These tests verify that:
// 1. MutationCallbacks type works correctly
// 2. The generated mutation methods (createTodo, updateTitle, etc.) work
// 3. Callbacks fire correctly
// 4. Link mutations work and queries reflect linked entity updates

import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - Thread-safe callback tracker

/// Thread-safe tracker for callback invocations in tests.
private final class CallbackTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var _order: [String] = []
  
  var order: [String] {
    lock.lock()
    defer { lock.unlock() }
    return _order
  }
  
  func append(_ value: String) {
    lock.lock()
    defer { lock.unlock() }
    _order.append(value)
  }
}

// MARK: - Integration Tests

final class MutationCallbacksIntegrationTests: XCTestCase {
  
  // MARK: - Generated Mutations Tests
  
  @MainActor
  func testGeneratedCreateTodoWithCallbacks() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()
    
    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "GeneratedMutationsTest",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )
    
    // Clear any cached state
    InstantClientFactory.clearCache()
    
    // Create a reactor for this test
    let store = SharedTripleStore()
    let reactor = Reactor(store: store, clientInstanceID: "mutations-test-create")
    
    // Track callback invocations
    let tracker = CallbackTracker()
    let expectation = XCTestExpectation(description: "All callbacks fire")
    
    try await withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = app.id
      $0.instantEnableLocalPersistence = false
    } operation: {
      @Shared(.instantSync(Schema.todos))
      var todos: IdentifiedArrayOf<Todo> = []
      
      // Wait for initial sync
      try await Task.sleep(nanoseconds: 1_000_000_000)
      
      // Use the generated createTodo method with callbacks
      $todos.createTodo(
        createdAt: Date().timeIntervalSince1970 * 1_000,
        done: false,
        title: "Test Todo from Generated API",
        callbacks: MutationCallbacks(
          onMutate: {
            tracker.append("onMutate")
          },
          onSuccess: { createdTodo in
            tracker.append("onSuccess")
            XCTAssertEqual(createdTodo.title, "Test Todo from Generated API")
          },
          onError: { error in
            tracker.append("onError")
            XCTFail("Should not error: \(error)")
          },
          onSettled: {
            tracker.append("onSettled")
            expectation.fulfill()
          }
        )
      )
      
      // Wait for callbacks
      await fulfillment(of: [expectation], timeout: 10.0)
      
      // Verify callback order
      XCTAssertEqual(tracker.order, ["onMutate", "onSuccess", "onSettled"])
      
      // Wait for sync
      try await Task.sleep(nanoseconds: 1_000_000_000)
      
      // Verify entity was created
      XCTAssertEqual(todos.count, 1)
      XCTAssertEqual(todos.first?.title, "Test Todo from Generated API")
    }
  }
  
  @MainActor
  func testGeneratedToggleDone() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()
    
    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "GeneratedToggleTest",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )
    
    InstantClientFactory.clearCache()
    
    let store = SharedTripleStore()
    let reactor = Reactor(store: store, clientInstanceID: "mutations-test-toggle")
    
    let tracker = CallbackTracker()
    let expectation = XCTestExpectation(description: "Toggle callbacks fire")
    
    try await withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = app.id
      $0.instantEnableLocalPersistence = false
    } operation: {
      @Shared(.instantSync(Schema.todos))
      var todos: IdentifiedArrayOf<Todo> = []
      
      // Wait for initial sync
      try await Task.sleep(nanoseconds: 1_000_000_000)
      
      // Create a todo first using the generated method (without callbacks for simplicity)
      let todoId = UUID().uuidString.lowercased()
      let createExpectation = XCTestExpectation(description: "Create completes")
      $todos.createTodo(
        id: todoId,
        createdAt: Date().timeIntervalSince1970 * 1_000,
        done: false,
        title: "Toggle Test",
        callbacks: MutationCallbacks(onSettled: { createExpectation.fulfill() })
      )
      
      await fulfillment(of: [createExpectation], timeout: 10.0)
      try await Task.sleep(nanoseconds: 500_000_000)
      XCTAssertEqual(todos[id: todoId]?.done, false)
      
      // Now use the generated toggleDone method
      $todos.toggleDone(
        todoId,
        callbacks: MutationCallbacks(
          onMutate: {
            tracker.append("onMutate")
          },
          onSuccess: { updatedTodo in
            tracker.append("onSuccess")
            XCTAssertTrue(updatedTodo.done)
          },
          onError: { error in
            tracker.append("onError")
            XCTFail("Should not error: \(error)")
          },
          onSettled: {
            tracker.append("onSettled")
            expectation.fulfill()
          }
        )
      )
      
      await fulfillment(of: [expectation], timeout: 10.0)
      
      // Verify callback order
      XCTAssertEqual(tracker.order, ["onMutate", "onSuccess", "onSettled"])
      
      // Verify toggle persisted
      XCTAssertEqual(todos[id: todoId]?.done, true)
    }
  }
  
  @MainActor
  func testGeneratedUpdateTitle() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()
    
    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "GeneratedUpdateTest",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )
    
    InstantClientFactory.clearCache()
    
    let store = SharedTripleStore()
    let reactor = Reactor(store: store, clientInstanceID: "mutations-test-update")
    
    let tracker = CallbackTracker()
    let expectation = XCTestExpectation(description: "Update callbacks fire")
    
    try await withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = app.id
      $0.instantEnableLocalPersistence = false
    } operation: {
      @Shared(.instantSync(Schema.todos))
      var todos: IdentifiedArrayOf<Todo> = []
      
      // Wait for initial sync
      try await Task.sleep(nanoseconds: 1_000_000_000)
      
      // Create a todo first
      let todoId = UUID().uuidString.lowercased()
      let createExpectation = XCTestExpectation(description: "Create completes")
      $todos.createTodo(
        id: todoId,
        createdAt: Date().timeIntervalSince1970 * 1_000,
        done: false,
        title: "Original Title",
        callbacks: MutationCallbacks(onSettled: { createExpectation.fulfill() })
      )
      
      await fulfillment(of: [createExpectation], timeout: 10.0)
      try await Task.sleep(nanoseconds: 500_000_000)
      XCTAssertEqual(todos[id: todoId]?.title, "Original Title")
      
      // Now use the generated updateTitle method
      $todos.updateTitle(
        todoId,
        to: "Updated Title",
        callbacks: MutationCallbacks(
          onMutate: {
            tracker.append("onMutate")
          },
          onSuccess: { updatedTodo in
            tracker.append("onSuccess")
            XCTAssertEqual(updatedTodo.title, "Updated Title")
          },
          onError: { error in
            tracker.append("onError")
            XCTFail("Should not error: \(error)")
          },
          onSettled: {
            tracker.append("onSettled")
            expectation.fulfill()
          }
        )
      )
      
      await fulfillment(of: [expectation], timeout: 10.0)
      
      // Verify callback order
      XCTAssertEqual(tracker.order, ["onMutate", "onSuccess", "onSettled"])
      
      // Verify update persisted
      XCTAssertEqual(todos[id: todoId]?.title, "Updated Title")
    }
  }
  
  @MainActor
  func testGeneratedDeleteTodo() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()
    
    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "GeneratedDeleteTest",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )
    
    InstantClientFactory.clearCache()
    
    let store = SharedTripleStore()
    let reactor = Reactor(store: store, clientInstanceID: "mutations-test-delete")
    
    let tracker = CallbackTracker()
    let expectation = XCTestExpectation(description: "Delete callbacks fire")
    
    try await withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = app.id
      $0.instantEnableLocalPersistence = false
    } operation: {
      @Shared(.instantSync(Schema.todos))
      var todos: IdentifiedArrayOf<Todo> = []
      
      // Wait for initial sync
      try await Task.sleep(nanoseconds: 1_000_000_000)
      
      // Create a todo first
      let todoId = UUID().uuidString.lowercased()
      let createExpectation = XCTestExpectation(description: "Create completes")
      $todos.createTodo(
        id: todoId,
        createdAt: Date().timeIntervalSince1970 * 1_000,
        done: false,
        title: "To Be Deleted",
        callbacks: MutationCallbacks(onSettled: { createExpectation.fulfill() })
      )
      
      await fulfillment(of: [createExpectation], timeout: 10.0)
      try await Task.sleep(nanoseconds: 500_000_000)
      XCTAssertEqual(todos.count, 1)
      
      // Now use the generated deleteTodo method
      $todos.deleteTodo(
        todoId,
        callbacks: MutationCallbacks(
          onMutate: {
            tracker.append("onMutate")
          },
          onSuccess: { _ in
            tracker.append("onSuccess")
          },
          onError: { error in
            tracker.append("onError")
            XCTFail("Should not error: \(error)")
          },
          onSettled: {
            tracker.append("onSettled")
            expectation.fulfill()
          }
        )
      )
      
      await fulfillment(of: [expectation], timeout: 10.0)
      
      // Verify callback order
      XCTAssertEqual(tracker.order, ["onMutate", "onSuccess", "onSettled"])
      
      // Verify deletion
      XCTAssertEqual(todos.count, 0)
    }
  }
  
  @MainActor
  func testGeneratedMarkAndUnmarkDone() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()
    
    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "GeneratedMarkTest",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )
    
    InstantClientFactory.clearCache()
    
    let store = SharedTripleStore()
    let reactor = Reactor(store: store, clientInstanceID: "mutations-test-mark")
    
    try await withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = app.id
      $0.instantEnableLocalPersistence = false
    } operation: {
      @Shared(.instantSync(Schema.todos))
      var todos: IdentifiedArrayOf<Todo> = []
      
      // Wait for initial sync
      try await Task.sleep(nanoseconds: 1_000_000_000)
      
      // Create a todo first
      let todoId = UUID().uuidString.lowercased()
      let createExpectation = XCTestExpectation(description: "Create completes")
      $todos.createTodo(
        id: todoId,
        createdAt: Date().timeIntervalSince1970 * 1_000,
        done: false,
        title: "Mark Test",
        callbacks: MutationCallbacks(onSettled: { createExpectation.fulfill() })
      )
      
      await fulfillment(of: [createExpectation], timeout: 10.0)
      try await Task.sleep(nanoseconds: 500_000_000)
      XCTAssertEqual(todos[id: todoId]?.done, false)
      
      // Use markDone
      let markExpectation = XCTestExpectation(description: "markDone completes")
      $todos.markDone(
        todoId,
        callbacks: MutationCallbacks(
          onSettled: { markExpectation.fulfill() }
        )
      )
      
      await fulfillment(of: [markExpectation], timeout: 10.0)
      try await Task.sleep(nanoseconds: 500_000_000)
      XCTAssertEqual(todos[id: todoId]?.done, true)
      
      // Use unmarkDone
      let unmarkExpectation = XCTestExpectation(description: "unmarkDone completes")
      $todos.unmarkDone(
        todoId,
        callbacks: MutationCallbacks(
          onSettled: { unmarkExpectation.fulfill() }
        )
      )
      
      await fulfillment(of: [unmarkExpectation], timeout: 10.0)
      try await Task.sleep(nanoseconds: 500_000_000)
      XCTAssertEqual(todos[id: todoId]?.done, false)
    }
  }
  
  // MARK: - MutationCallbacks Type Tests
  
  @MainActor
  func testMutationCallbacksWithOptionalCallbacks() async throws {
    // Test that nil callbacks don't crash
    let callbacks = MutationCallbacks<String>()
    
    // These should all be no-ops
    callbacks.onMutate?()
    callbacks.onSuccess?("test")
    callbacks.onError?(NSError(domain: "test", code: 0))
    callbacks.onSettled?()
    
    // If we get here without crashing, the test passes
    XCTAssertTrue(true)
  }
  
  @MainActor
  func testMutationCallbacksDefaultInit() async throws {
    // Test the default initializer
    let callbacks = MutationCallbacks<Int>.init()
    
    XCTAssertNil(callbacks.onMutate)
    XCTAssertNil(callbacks.onSuccess)
    XCTAssertNil(callbacks.onError)
    XCTAssertNil(callbacks.onSettled)
  }
  
  // MARK: - Link Mutation Tests
  
  /// Test that linking a Post to a Profile works and the `.with(\.author)` query
  /// correctly reflects the linked entity.
  @MainActor
  func testLinkPostToAuthorAndQueryWithAuthor() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()
    
    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "LinkMutationsTest",
      schema: EphemeralAppFactory.minimalMicroblogSchema(),
      rules: EphemeralAppFactory.openRules(for: ["profiles", "posts"])
    )
    
    InstantClientFactory.clearCache()
    
    let store = SharedTripleStore()
    let reactor = Reactor(store: store, clientInstanceID: "mutations-test-link")
    
    let tracker = CallbackTracker()
    
    try await withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = app.id
      $0.instantEnableLocalPersistence = false
    } operation: {
      // Subscribe to profiles (flat)
      @Shared(.instantSync(Schema.profiles))
      var profiles: IdentifiedArrayOf<Profile> = []
      
      // Subscribe to posts with author link populated
      @Shared(.instantSync(Schema.posts.with(\.author)))
      var posts: IdentifiedArrayOf<Post> = []
      
      // Wait for initial sync
      try await Task.sleep(nanoseconds: 1_000_000_000)
      
      // 1. Create a Profile
      let profileId = UUID().uuidString.lowercased()
      let createProfileExpectation = XCTestExpectation(description: "Profile created")
      $profiles.createProfile(
        id: profileId,
        displayName: "Alice",
        handle: "alice_\(profileId.prefix(8))",
        createdAt: Date().timeIntervalSince1970 * 1_000,
        callbacks: MutationCallbacks(
          onSettled: { createProfileExpectation.fulfill() }
        )
      )
      
      await fulfillment(of: [createProfileExpectation], timeout: 10.0)
      try await Task.sleep(nanoseconds: 500_000_000)
      
      XCTAssertEqual(profiles.count, 1)
      XCTAssertEqual(profiles[id: profileId]?.displayName, "Alice")
      
      // 2. Create a Post (without author link initially)
      let postId = UUID().uuidString.lowercased()
      let createPostExpectation = XCTestExpectation(description: "Post created")
      $posts.createPost(
        id: postId,
        content: "Hello from Alice!",
        createdAt: Date().timeIntervalSince1970 * 1_000,
        likesCount: 0,
        callbacks: MutationCallbacks(
          onSettled: { createPostExpectation.fulfill() }
        )
      )
      
      await fulfillment(of: [createPostExpectation], timeout: 10.0)
      try await Task.sleep(nanoseconds: 500_000_000)
      
      XCTAssertEqual(posts.count, 1)
      // Author should be nil since we haven't linked yet
      XCTAssertNil(posts[id: postId]?.author)
      
      // 3. Link the Post to the Profile using the generated linkAuthor method
      let linkExpectation = XCTestExpectation(description: "Link completed")
      let profile = profiles[id: profileId]!
      $posts.linkAuthor(
        postId,
        to: profile,
        callbacks: MutationCallbacks(
          onMutate: { tracker.append("onMutate") },
          onSuccess: { _ in tracker.append("onSuccess") },
          onError: { error in
            tracker.append("onError")
            XCTFail("Link should not error: \(error)")
          },
          onSettled: {
            tracker.append("onSettled")
            linkExpectation.fulfill()
          }
        )
      )
      
      await fulfillment(of: [linkExpectation], timeout: 10.0)
      
      // Verify callback order
      XCTAssertEqual(tracker.order, ["onMutate", "onSuccess", "onSettled"])
      
      // Wait for sync to propagate
      try await Task.sleep(nanoseconds: 1_000_000_000)
      
      // 4. Verify the author link is now populated in the query
      let linkedPost = posts[id: postId]
      XCTAssertNotNil(linkedPost?.author, "Author should be populated after linking")
      XCTAssertEqual(linkedPost?.author?.id, profileId)
      XCTAssertEqual(linkedPost?.author?.displayName, "Alice")
    }
  }
  
  /// Test that updating a linked entity's fields is reflected in queries that include that link.
  @MainActor
  func testUpdateLinkedAuthorReflectsInPostQuery() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()
    
    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "LinkedUpdateTest",
      schema: EphemeralAppFactory.minimalMicroblogSchema(),
      rules: EphemeralAppFactory.openRules(for: ["profiles", "posts"])
    )
    
    InstantClientFactory.clearCache()
    
    let store = SharedTripleStore()
    let reactor = Reactor(store: store, clientInstanceID: "mutations-test-linked-update")
    
    try await withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = app.id
      $0.instantEnableLocalPersistence = false
    } operation: {
      @Shared(.instantSync(Schema.profiles))
      var profiles: IdentifiedArrayOf<Profile> = []
      
      @Shared(.instantSync(Schema.posts.with(\.author)))
      var posts: IdentifiedArrayOf<Post> = []
      
      try await Task.sleep(nanoseconds: 1_000_000_000)
      
      // 1. Create Profile and Post, then link them
      let profileId = UUID().uuidString.lowercased()
      let postId = UUID().uuidString.lowercased()
      
      // Create profile
      let profileExp = XCTestExpectation(description: "Profile created")
      $profiles.createProfile(
        id: profileId,
        displayName: "Bob",
        handle: "bob_\(profileId.prefix(8))",
        createdAt: Date().timeIntervalSince1970 * 1_000,
        callbacks: MutationCallbacks(onSettled: { profileExp.fulfill() })
      )
      await fulfillment(of: [profileExp], timeout: 10.0)
      try await Task.sleep(nanoseconds: 500_000_000)
      
      // Create post
      let postExp = XCTestExpectation(description: "Post created")
      $posts.createPost(
        id: postId,
        content: "Bob's first post",
        createdAt: Date().timeIntervalSince1970 * 1_000,
        likesCount: 0,
        callbacks: MutationCallbacks(onSettled: { postExp.fulfill() })
      )
      await fulfillment(of: [postExp], timeout: 10.0)
      try await Task.sleep(nanoseconds: 500_000_000)
      
      // Link post to profile
      let linkExp = XCTestExpectation(description: "Link completed")
      $posts.linkAuthor(
        postId,
        to: profiles[id: profileId]!,
        callbacks: MutationCallbacks(onSettled: { linkExp.fulfill() })
      )
      await fulfillment(of: [linkExp], timeout: 10.0)
      try await Task.sleep(nanoseconds: 1_000_000_000)
      
      // Verify initial state
      XCTAssertEqual(posts[id: postId]?.author?.displayName, "Bob")
      
      // 2. Update the Profile's displayName
      let updateExp = XCTestExpectation(description: "Update completed")
      $profiles.updateDisplayName(
        profileId,
        to: "Robert",
        callbacks: MutationCallbacks(
          onSuccess: { updated in
            XCTAssertEqual(updated.displayName, "Robert")
          },
          onSettled: { updateExp.fulfill() }
        )
      )
      await fulfillment(of: [updateExp], timeout: 10.0)
      
      // Wait for sync to propagate
      try await Task.sleep(nanoseconds: 1_500_000_000)
      
      // 3. Verify the posts query reflects the updated author name
      let updatedPost = posts[id: postId]
      XCTAssertNotNil(updatedPost?.author, "Author should still be linked")
      XCTAssertEqual(
        updatedPost?.author?.displayName,
        "Robert",
        "The author's displayName should be updated to 'Robert' in the posts query"
      )
      
      // Also verify the profiles collection was updated
      XCTAssertEqual(profiles[id: profileId]?.displayName, "Robert")
    }
  }
  
  /// Test unlinking a Post from its author.
  @MainActor
  func testUnlinkAuthorFromPost() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()
    
    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "UnlinkTest",
      schema: EphemeralAppFactory.minimalMicroblogSchema(),
      rules: EphemeralAppFactory.openRules(for: ["profiles", "posts"])
    )
    
    InstantClientFactory.clearCache()
    
    let store = SharedTripleStore()
    let reactor = Reactor(store: store, clientInstanceID: "mutations-test-unlink")
    
    let tracker = CallbackTracker()
    
    try await withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = app.id
      $0.instantEnableLocalPersistence = false
    } operation: {
      @Shared(.instantSync(Schema.profiles))
      var profiles: IdentifiedArrayOf<Profile> = []
      
      @Shared(.instantSync(Schema.posts.with(\.author)))
      var posts: IdentifiedArrayOf<Post> = []
      
      try await Task.sleep(nanoseconds: 1_000_000_000)
      
      // Setup: Create profile, post, and link them
      let profileId = UUID().uuidString.lowercased()
      let postId = UUID().uuidString.lowercased()
      
      let profileExp = XCTestExpectation(description: "Profile created")
      $profiles.createProfile(
        id: profileId,
        displayName: "Carol",
        handle: "carol_\(profileId.prefix(8))",
        createdAt: Date().timeIntervalSince1970 * 1_000,
        callbacks: MutationCallbacks(onSettled: { profileExp.fulfill() })
      )
      await fulfillment(of: [profileExp], timeout: 10.0)
      try await Task.sleep(nanoseconds: 500_000_000)
      
      let postExp = XCTestExpectation(description: "Post created")
      $posts.createPost(
        id: postId,
        content: "Carol's post",
        createdAt: Date().timeIntervalSince1970 * 1_000,
        likesCount: 0,
        callbacks: MutationCallbacks(onSettled: { postExp.fulfill() })
      )
      await fulfillment(of: [postExp], timeout: 10.0)
      try await Task.sleep(nanoseconds: 500_000_000)
      
      let linkExp = XCTestExpectation(description: "Link completed")
      $posts.linkAuthor(
        postId,
        to: profiles[id: profileId]!,
        callbacks: MutationCallbacks(onSettled: { linkExp.fulfill() })
      )
      await fulfillment(of: [linkExp], timeout: 10.0)
      try await Task.sleep(nanoseconds: 1_000_000_000)
      
      // Verify link exists
      XCTAssertNotNil(posts[id: postId]?.author)
      XCTAssertEqual(posts[id: postId]?.author?.displayName, "Carol")
      
      // Now unlink the author
      let unlinkExp = XCTestExpectation(description: "Unlink completed")
      let profile = profiles[id: profileId]!
      $posts.unlinkAuthor(
        postId,
        from: profile,
        callbacks: MutationCallbacks(
          onMutate: { tracker.append("onMutate") },
          onSuccess: { _ in tracker.append("onSuccess") },
          onError: { error in
            tracker.append("onError")
            XCTFail("Unlink should not error: \(error)")
          },
          onSettled: {
            tracker.append("onSettled")
            unlinkExp.fulfill()
          }
        )
      )
      
      await fulfillment(of: [unlinkExp], timeout: 10.0)
      
      // Verify callback order
      XCTAssertEqual(tracker.order, ["onMutate", "onSuccess", "onSettled"])
      
      // Wait for sync
      try await Task.sleep(nanoseconds: 1_000_000_000)
      
      // Verify the author link is now nil
      XCTAssertNil(
        posts[id: postId]?.author,
        "Author should be nil after unlinking"
      )
    }
  }
}
