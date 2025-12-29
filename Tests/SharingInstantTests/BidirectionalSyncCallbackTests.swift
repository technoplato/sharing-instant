import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - BidirectionalSyncCallbackTests

/// Tests that verify the callback chain works correctly for bidirectional sync.
///
/// ## The Bug Being Tested
/// After a Swift client makes a local mutation, subsequent updates from the server
/// (e.g., from another client or the Admin SDK) are NOT triggering SwiftUI view updates.
final class BidirectionalSyncCallbackTests: XCTestCase {
  
  // MARK: - Test Model
  
  @MainActor
  private final class TodoModel: ObservableObject {
    @Shared var todos: IdentifiedArrayOf<Todo>
    
    init(key: EntityKey<Todo> = Schema.todos.orderBy(\Todo.createdAt, EntityKeyOrderDirection.desc)) {
      _todos = Shared(.instantSync(key))
    }
    
    func addTodo(title: String) -> Todo {
      let todo = Todo(
        createdAt: Date().timeIntervalSince1970 * 1_000,
        done: false,
        title: title
      )
      _ = $todos.withLock { $0.insert(todo, at: 0) }
      return todo
    }
  }
  
  // MARK: - Tests
  
  /// Test 1: Verify that BEFORE any local mutation, server updates ARE received
  @MainActor
  func testServerUpdatesReceivedBeforeLocalMutation() async throws {
    try Self.skipIfNotEnabled()
    
    print("TEST START: testServerUpdatesReceivedBeforeLocalMutation")
    
    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "bidir-sync-callback",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )
    
    let (model, _) = try await createModel(appId: app.id)
    
    // Create a todo via Admin SDK (NOT via Swift)
    // Use lowercased UUID since InstantDB normalizes to lowercase
    let todoId = UUID().uuidString.lowercased()
    try await Self.createTodoViaAdminSDK(appId: app.id, adminToken: app.adminToken, todoId: todoId, title: "Created by Admin", done: false)
    
    print("Waiting for Swift to receive Admin-created todo: \(todoId)")
    
    // Wait for Swift to receive the todo
    try await eventually(timeout: 15, pollInterval: 0.3, failureMessage: "Swift should receive todo created by Admin SDK") {
      model.todos.contains(where: { $0.id == todoId })
    }
    
    print("Swift received Admin-created todo, count: \(model.todos.count)")
    
    // Now update the todo via Admin SDK
    try await Self.runAdminMutation(appId: app.id, adminToken: app.adminToken, todoId: todoId, newDoneValue: true)
    
    print("Waiting for Swift to receive done=true update")
    
    // Wait for Swift to receive the update
    try await eventually(timeout: 15, pollInterval: 0.3, failureMessage: "Swift should receive done=true update from Admin SDK (BEFORE any local mutation)") {
      model.todos.first(where: { $0.id == todoId })?.done == true
    }
    
    print("TEST PASSED: testServerUpdatesReceivedBeforeLocalMutation")
  }
  
  /// Test 2: THE FAILING TEST - Verify that AFTER a local mutation, server updates are still received
  @MainActor
  func testServerUpdatesReceivedAfterLocalMutation() async throws {
    try Self.skipIfNotEnabled()
    
    print("TEST START: testServerUpdatesReceivedAfterLocalMutation")
    
    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "bidir-sync-callback",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )
    
    let (model, _) = try await createModel(appId: app.id)
    
    // Step 1: Create a todo via Admin SDK
    // Use lowercased UUID since InstantDB normalizes to lowercase
    let todoId = UUID().uuidString.lowercased()
    try await Self.createTodoViaAdminSDK(appId: app.id, adminToken: app.adminToken, todoId: todoId, title: "Created by Admin", done: false)
    
    // Wait for Swift to receive it
    try await eventually(timeout: 15, pollInterval: 0.3, failureMessage: "Swift should receive initial todo") {
      model.todos.contains(where: { $0.id == todoId })
    }
    
    print("Swift received initial todo: \(todoId), count: \(model.todos.count)")
    
    // Step 2: Make a LOCAL mutation from Swift (THIS IS THE KEY STEP)
    let localTodo = model.addTodo(title: "Created by Swift")
    
    print("Swift made local mutation: \(localTodo.id), count: \(model.todos.count)")
    
    // Give time for the local mutation to propagate
    try await Task.sleep(nanoseconds: 2_000_000_000)
    
    // Step 3: Now update the ORIGINAL todo via Admin SDK
    print("About to update via Admin SDK AFTER local mutation: \(todoId)")
    
    try await Self.runAdminMutation(appId: app.id, adminToken: app.adminToken, todoId: todoId, newDoneValue: true)
    
    print("Admin SDK mutation sent, waiting for Swift callback")
    
    // Step 4: THIS IS WHERE THE BUG MANIFESTS - Swift should receive the update but doesn't
    try await eventually(timeout: 20, pollInterval: 0.5, failureMessage: """
      Swift should receive done=true update from Admin SDK AFTER making a local mutation.
      
      This is the core bidirectional sync bug: after Swift makes a local mutation,
      subsequent server updates are not triggering the SharedSubscriber callback.
      """) {
      let todo = model.todos.first(where: { $0.id == todoId })
      let done = todo?.done ?? false
      print("Polling for update: todoId=\(todoId), currentDone=\(done)")
      return done == true
    }
    
    print("TEST PASSED: testServerUpdatesReceivedAfterLocalMutation")
  }
  
  /// Test 3: Verify callback is invoked for multiple sequential server updates after local mutation
  @MainActor
  func testMultipleServerUpdatesAfterLocalMutation() async throws {
    try Self.skipIfNotEnabled()
    
    print("TEST START: testMultipleServerUpdatesAfterLocalMutation")
    
    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "bidir-sync-callback",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )
    
    let (model, _) = try await createModel(appId: app.id)
    
    // Create todo via Admin (use lowercased UUID since InstantDB normalizes to lowercase)
    let todoId = UUID().uuidString.lowercased()
    try await Self.createTodoViaAdminSDK(appId: app.id, adminToken: app.adminToken, todoId: todoId, title: "Original Title", done: false)
    
    try await eventually(timeout: 15, pollInterval: 0.3, failureMessage: "Swift should receive initial todo") {
      model.todos.contains(where: { $0.id == todoId })
    }
    
    // Make local mutation
    _ = model.addTodo(title: "Local Todo")
    try await Task.sleep(nanoseconds: 1_000_000_000)
    
    print("Local mutation complete, starting sequential server updates")
    
    // Server update 1: Toggle done
    try await Self.runAdminMutation(appId: app.id, adminToken: app.adminToken, todoId: todoId, newDoneValue: true)
    
    try await eventually(timeout: 15, pollInterval: 0.3, failureMessage: "Swift should receive first server update (done=true)") {
      model.todos.first(where: { $0.id == todoId })?.done == true
    }
    
    print("First server update received")
    
    // Server update 2: Update title
    try await Self.runAdminTitleUpdate(appId: app.id, adminToken: app.adminToken, todoId: todoId, newTitle: "Updated Title")
    
    try await eventually(timeout: 15, pollInterval: 0.3, failureMessage: "Swift should receive second server update (title change)") {
      model.todos.first(where: { $0.id == todoId })?.title == "Updated Title"
    }
    
    print("TEST PASSED: testMultipleServerUpdatesAfterLocalMutation")
  }
  
  // MARK: - Helpers
  
  private static func skipIfNotEnabled() throws {
    if ProcessInfo.processInfo.environment["INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS"] != "1" {
      throw XCTSkip(
        """
        Bidirectional sync callback tests are disabled.
        
        Set `INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS=1` to run these tests.
        """
      )
    }
  }
  
  @MainActor
  private func createModel(appId: String) async throws -> (TodoModel, Reactor) {
    // Clear any cached state
    if let bundleID = Bundle.main.bundleIdentifier {
      UserDefaults.standard.removePersistentDomain(forName: bundleID)
    }
    
    InstantClientFactory.clearCache()
    
    let store = SharedTripleStore()
    let reactor = Reactor(store: store, clientInstanceID: "bidir-test-\(UUID().uuidString.prefix(8))")
    
    let model = withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = appId
      $0.instantEnableLocalPersistence = false
    } operation: {
      TodoModel()
    }
    
    // Warm the subscription
    _ = model.todos.count
    try await Task.sleep(nanoseconds: 1_000_000_000)
    
    return (model, reactor)
  }
  
  private static func repoScriptsDir() -> URL {
    // Navigate from test file to repo root/scripts
    let testFile = URL(fileURLWithPath: #filePath)
    return testFile
      .deletingLastPathComponent() // SharingInstantTests
      .deletingLastPathComponent() // Tests
      .deletingLastPathComponent() // sharing-instant
      .deletingLastPathComponent() // instantdb repo root
      .appendingPathComponent("scripts", isDirectory: true)
  }
  
  private static func createTodoViaAdminSDK(
    appId: String,
    adminToken: String,
    todoId: String,
    title: String,
    done: Bool
  ) async throws {
    let scriptContent = """
    import { init } from "@instantdb/admin";
    
    const db = init({
      appId: "\(appId)",
      adminToken: "\(adminToken)",
    });
    
    async function main() {
      await db.transact([
        db.tx.todos["\(todoId)"].update({
          createdAt: Date.now(),
          done: \(done),
          title: "\(title)",
        }),
      ]);
      console.log("Created todo:", "\(todoId)");
    }
    
    main().catch(console.error);
    """
    
    let tempDir = FileManager.default.temporaryDirectory
    let scriptPath = tempDir.appendingPathComponent("create-todo-\(UUID().uuidString).mjs")
    
    try scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: scriptPath) }
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["bun", "run", scriptPath.path]
    process.currentDirectoryURL = repoScriptsDir()
    
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    
    try process.run()
    process.waitUntilExit()
    
    guard process.terminationStatus == 0 else {
      let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      throw NSError(domain: "AdminSDK", code: Int(process.terminationStatus), userInfo: [
        NSLocalizedDescriptionKey: "Failed to create todo via Admin SDK: \(stderr)"
      ])
    }
  }
  
  private static func runAdminMutation(
    appId: String,
    adminToken: String,
    todoId: String,
    newDoneValue: Bool
  ) async throws {
    let scriptContent = """
    import { init } from "@instantdb/admin";
    
    const db = init({
      appId: "\(appId)",
      adminToken: "\(adminToken)",
    });
    
    async function main() {
      console.log("Admin SDK: Updating todo \(todoId) to done=\(newDoneValue)");
      
      await db.transact([
        db.tx.todos["\(todoId)"].update({
          done: \(newDoneValue),
        }),
      ]);
      
      console.log("Admin SDK: Update complete");
    }
    
    main().catch(console.error);
    """
    
    let tempDir = FileManager.default.temporaryDirectory
    let scriptPath = tempDir.appendingPathComponent("admin-mutation-\(UUID().uuidString).mjs")
    
    try scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: scriptPath) }
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["bun", "run", scriptPath.path]
    process.currentDirectoryURL = repoScriptsDir()
    
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    
    try process.run()
    process.waitUntilExit()
    
    guard process.terminationStatus == 0 else {
      let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      throw NSError(domain: "AdminSDK", code: Int(process.terminationStatus), userInfo: [
        NSLocalizedDescriptionKey: "Admin SDK script failed: \(stderr)"
      ])
    }
  }
  
  private static func runAdminTitleUpdate(
    appId: String,
    adminToken: String,
    todoId: String,
    newTitle: String
  ) async throws {
    let scriptContent = """
    import { init } from "@instantdb/admin";
    
    const db = init({
      appId: "\(appId)",
      adminToken: "\(adminToken)",
    });
    
    async function main() {
      console.log("Admin SDK: Updating todo \(todoId) title to '\(newTitle)'");
      
      await db.transact([
        db.tx.todos["\(todoId)"].update({
          title: "\(newTitle)",
        }),
      ]);
      
      console.log("Admin SDK: Update complete");
    }
    
    main().catch(console.error);
    """
    
    let tempDir = FileManager.default.temporaryDirectory
    let scriptPath = tempDir.appendingPathComponent("admin-title-\(UUID().uuidString).mjs")
    
    try scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: scriptPath) }
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["bun", "run", scriptPath.path]
    process.currentDirectoryURL = repoScriptsDir()
    
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    
    try process.run()
    process.waitUntilExit()
    
    guard process.terminationStatus == 0 else {
      let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      throw NSError(domain: "AdminSDK", code: Int(process.terminationStatus), userInfo: [
        NSLocalizedDescriptionKey: "Admin SDK script failed: \(stderr)"
      ])
    }
  }
  
  @MainActor
  private func eventually(
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
    throw NSError(domain: "TestTimeout", code: 1, userInfo: [NSLocalizedDescriptionKey: failureMessage])
  }
}
