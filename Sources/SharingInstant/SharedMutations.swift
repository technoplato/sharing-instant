/// ═══════════════════════════════════════════════════════════════════════════════
/// SharedMutations.swift
/// Explicit mutation methods for @Shared InstantDB collections
/// ═══════════════════════════════════════════════════════════════════════════════
///
/// This file provides explicit mutation methods (create, delete, update, link, unlink)
/// that bypass the diff-based save() mechanism. These methods generate specific
/// transaction chunks and send them directly to the server.
///
/// ## Why This Exists
///
/// The default `$collection.withLock { }` approach triggers `save()` which computes
/// diffs between local and server state. This causes issues:
/// - Race conditions when multiple subscriptions exist for the same namespace
/// - Ghost deletions on app start
/// - Re-sync of deleted items when creating new items
///
/// ## How It Works
///
/// Instead of computing diffs, these methods:
/// 1. Apply the change optimistically to local state
/// 2. Generate a specific transaction chunk for the operation
/// 3. Send the chunk directly to the server via `directTransact()`
///
/// ## Usage
///
/// ```swift
/// @Shared(.instantSync(Schema.goals)) var goals: [Goal]
///
/// // Create - explicit operation, no diff
/// try await $goals.create(Goal(id: id, title: "New Goal"))
///
/// // Delete - explicit operation, no diff
/// try await $goals.delete(id: goalId)
///
/// // Update - explicit operation, no diff
/// try await $goals.update(id: goalId) { $0.title = "Updated" }
///
/// // Link - explicit operation
/// try await $goals.link(goalId, "creator", to: profileId, namespace: "profiles")
/// ```
///
/// ═══════════════════════════════════════════════════════════════════════════════

import Dependencies
import Foundation
import IdentifiedCollections
import InstantDB
import Sharing

// MARK: - Mutation Callbacks

/// TanStack Query-style callbacks for mutation operations.
///
/// These callbacks provide hooks into the mutation lifecycle, allowing you to
/// respond to different stages of a mutation operation.
///
/// ## Why This Exists
///
/// TanStack Query popularized this callback pattern for mutations because it provides:
/// - **Optimistic UI updates** via `onMutate` (before the server responds)
/// - **Success handling** via `onSuccess` (update UI, show toast, navigate)
/// - **Error handling** via `onError` (show error, revert optimistic update)
/// - **Cleanup** via `onSettled` (always runs, like `finally`)
///
/// ## Example
///
/// ```swift
/// $posts.createPost(
///   content: "Hello world",
///   callbacks: MutationCallbacks(
///     onMutate: {
///       print("Creating post...")
///     },
///     onSuccess: { post in
///       print("Created post: \(post.id)")
///     },
///     onError: { error in
///       print("Failed: \(error)")
///     },
///     onSettled: {
///       print("Done (success or failure)")
///     }
///   )
/// )
/// ```
public struct MutationCallbacks<T: Sendable>: Sendable {
  /// Called immediately before the mutation is executed.
  /// Use this for optimistic updates or loading states.
  public var onMutate: (@Sendable () -> Void)?
  
  /// Called when the mutation succeeds.
  /// Receives the result of the mutation (e.g., the created/updated entity).
  public var onSuccess: (@Sendable (T) -> Void)?
  
  /// Called when the mutation fails.
  /// Receives the error that occurred.
  public var onError: (@Sendable (Error) -> Void)?
  
  /// Called after the mutation completes, regardless of success or failure.
  /// Use this for cleanup, like dismissing loading states.
  public var onSettled: (@Sendable () -> Void)?
  
  public init(
    onMutate: (@Sendable () -> Void)? = nil,
    onSuccess: (@Sendable (T) -> Void)? = nil,
    onError: (@Sendable (Error) -> Void)? = nil,
    onSettled: (@Sendable () -> Void)? = nil
  ) {
    self.onMutate = onMutate
    self.onSuccess = onSuccess
    self.onError = onError
    self.onSettled = onSettled
  }
}

// MARK: - MutationCallbacks Convenience Methods

extension MutationCallbacks {
  /// Create callbacks with only an error handler.
  ///
  /// This is the most common use case for fire-and-forget mutations where
  /// you only care about logging errors.
  ///
  /// ## Example
  /// ```swift
  /// $posts.updateTitle(id, to: "New Title", callbacks: .onError { error in
  ///     print("Failed: \(error)")
  /// })
  /// ```
  public static func onError(_ handler: @escaping @Sendable (Error) -> Void) -> MutationCallbacks {
    MutationCallbacks(onError: handler)
  }

  /// Create callbacks with only a success handler.
  ///
  /// ## Example
  /// ```swift
  /// $posts.createPost(title: "Hello", callbacks: .onSuccess { post in
  ///     print("Created: \(post.id)")
  /// })
  /// ```
  public static func onSuccess(_ handler: @escaping @Sendable (T) -> Void) -> MutationCallbacks {
    MutationCallbacks(onSuccess: handler)
  }

  /// Create callbacks with only a settled handler.
  ///
  /// ## Example
  /// ```swift
  /// $posts.deletePost(id, callbacks: .onSettled {
  ///     isLoading = false
  /// })
  /// ```
  public static func onSettled(_ handler: @escaping @Sendable () -> Void) -> MutationCallbacks {
    MutationCallbacks(onSettled: handler)
  }
}

// MARK: - Explicit Mutation Methods for Shared Collections

extension Shared {
  
  // MARK: - Create
  
  /// Create a new entity and sync to InstantDB.
  ///
  /// This method follows the TypeScript InstantDB SDK pattern:
  /// 1. Sends transaction to Reactor which applies optimistic update
  /// 2. Reactor notifies subscriptions to update @Shared value
  /// 3. Server transaction is sent
  ///
  /// Unlike `withLock { $0.append(entity) }`, this does NOT compute diffs.
  /// It sends exactly one transaction for the new entity.
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(.instantSync(Schema.goals)) var goals: [Goal]
  ///
  /// let newGoal = Goal(id: UUID().uuidString, title: "Learn Swift")
  /// try await $goals.create(newGoal)
  /// ```
  ///
  /// - Parameter entity: The entity to create
  /// - Throws: If the transaction fails
  @MainActor
  public func create<Element: EntityIdentifiable & Encodable & Sendable>(
    _ entity: Element
  ) async throws where Value: RangeReplaceableCollection, Value.Element == Element {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    // Generate explicit transaction chunk
    let namespace = Element.namespace
    let attrs = try encodeEntityAttributes(entity)
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: entity.id,
      ops: [["update", namespace, entity.id, attrs]]
    )
    
    // Send to Reactor which handles optimistic update + server transaction
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  // MARK: - Delete
  
  /// Delete an entity by ID and sync to InstantDB.
  ///
  /// This method follows the TypeScript InstantDB SDK pattern:
  /// 1. Sends transaction to Reactor which applies optimistic update
  /// 2. Reactor notifies subscriptions to update @Shared value
  /// 3. Server transaction is sent
  ///
  /// Unlike `withLock { $0.remove(id:) }`, this does NOT compute diffs.
  /// It sends exactly one delete transaction.
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(.instantSync(Schema.goals)) var goals: [Goal]
  ///
  /// try await $goals.delete(id: goal.id)
  /// ```
  ///
  /// - Parameter id: The ID of the entity to delete
  /// - Throws: If the transaction fails
  @MainActor
  public func delete<Element: EntityIdentifiable & Sendable>(
    id: String
  ) async throws where Value: RangeReplaceableCollection, Value.Element == Element {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    // Generate explicit delete chunk
    let namespace = Element.namespace
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["delete", namespace, id]]
    )
    
    // Send to Reactor which handles optimistic update + server transaction
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  // MARK: - Update
  
  /// Update an entity's fields and sync to InstantDB.
  ///
  /// This method follows the TypeScript InstantDB SDK pattern:
  /// 1. Reads current entity, applies modification
  /// 2. Sends transaction to Reactor which applies optimistic update
  /// 3. Reactor notifies subscriptions to update @Shared value
  /// 4. Server transaction is sent
  ///
  /// **Important**: This method sends only the CHANGED fields, not the entire entity.
  /// This prevents concurrent updates from clobbering each other (e.g., updating
  /// `text` and `words` simultaneously on a transcription segment).
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(.instantSync(Schema.goals)) var goals: [Goal]
  ///
  /// try await $goals.update(id: goal.id) { goal in
  ///   goal.title = "Updated Title"
  ///   goal.completed = true
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - id: The ID of the entity to update
  ///   - modify: A closure that modifies the entity
  /// - Throws: If the entity is not found or the transaction fails
  ///
  /// ## Why We Read From TripleStore
  /// See the IdentifiedArrayOf version for detailed explanation. In short:
  /// we read from TripleStore to get optimistic updates that may not have
  /// propagated to wrappedValue yet due to AsyncStream timing.
  @MainActor
  public func update<Element: EntityIdentifiable & Encodable & Sendable>(
    id: String,
    _ modify: (inout Element) -> Void
  ) async throws where Value: RangeReplaceableCollection, Value.Element == Element {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID

    // Read from TripleStore directly to get optimistic updates that may not have
    // propagated to wrappedValue yet. Fall back to wrappedValue for backward compat.
    var entity: Element
    if let storeEntity: Element = await reactor.getEntity(id: id) {
      entity = storeEntity
    } else if let wrappedEntity = wrappedValue.first(where: { $0.id == id }) {
      entity = wrappedEntity
    } else {
      throw InstantMutationError.entityNotFound(id: id, namespace: Element.namespace)
    }

    // Encode BEFORE modification to compare
    let beforeAttrs = try encodeEntityAttributes(entity)

    // Apply modification locally
    modify(&entity)

    // Encode AFTER modification
    let afterAttrs = try encodeEntityAttributes(entity)

    // Compute only the changed fields (field-level update)
    // This prevents concurrent updates from clobbering each other
    let changedAttrs = computeChangedFields(before: beforeAttrs, after: afterAttrs)

    guard !changedAttrs.isEmpty else {
      // No actual changes - nothing to do
      return
    }

    // Generate explicit update chunk with ONLY changed fields
    let namespace = Element.namespace

    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["update", namespace, id, changedAttrs]]
    )

    // Send to Reactor which handles optimistic update + server transaction
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  // MARK: - Link
  
  /// Link an entity to another entity.
  ///
  /// This method sends an explicit "link" transaction to the server.
  /// It does NOT modify local state (the link will be reflected when
  /// the subscription receives the updated data).
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(.instantSync(Schema.posts.with(\.author))) var posts: [Post]
  ///
  /// // Link a post to its author
  /// try await $posts.link(post.id, "author", to: profile.id, namespace: "profiles")
  /// ```
  ///
  /// - Parameters:
  ///   - id: The ID of the entity to link from
  ///   - label: The link label (e.g., "author", "creator")
  ///   - targetId: The ID of the entity to link to
  ///   - namespace: The namespace of the target entity
  /// - Throws: If the transaction fails
  @MainActor
  public func link<Element: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    to targetId: String,
    namespace targetNamespace: String
  ) async throws where Value: RangeReplaceableCollection, Value.Element == Element {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    let namespace = Element.namespace
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["link", namespace, id, [label: ["id": targetId, "namespace": targetNamespace]] as [String: Any]]]
    )
    
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  /// Link an entity to another entity using the target entity directly.
  ///
  /// This is a convenience method that extracts the ID and namespace from the target entity.
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(.instantSync(Schema.posts.with(\.author))) var posts: [Post]
  ///
  /// // Link a post to its author
  /// try await $posts.link(post.id, "author", to: profile)
  /// ```
  ///
  /// - Parameters:
  ///   - id: The ID of the entity to link from
  ///   - label: The link label (e.g., "author", "creator")
  ///   - target: The entity to link to
  /// - Throws: If the transaction fails
  @MainActor
  public func link<Element: EntityIdentifiable & Sendable, Target: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    to target: Target
  ) async throws where Value: RangeReplaceableCollection, Value.Element == Element {
    try await link(id, label, to: target.id, namespace: Target.namespace)
  }
  
  // MARK: - Unlink
  
  /// Unlink an entity from another entity.
  ///
  /// This method sends an explicit "unlink" transaction to the server.
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(.instantSync(Schema.posts.with(\.author))) var posts: [Post]
  ///
  /// // Unlink a post from its author
  /// try await $posts.unlink(post.id, "author", from: profile.id, namespace: "profiles")
  /// ```
  ///
  /// - Parameters:
  ///   - id: The ID of the entity to unlink from
  ///   - label: The link label (e.g., "author", "creator")
  ///   - targetId: The ID of the entity to unlink from
  ///   - namespace: The namespace of the target entity
  /// - Throws: If the transaction fails
  @MainActor
  public func unlink<Element: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    from targetId: String,
    namespace targetNamespace: String
  ) async throws where Value: RangeReplaceableCollection, Value.Element == Element {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    let namespace = Element.namespace
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["unlink", namespace, id, [label: ["id": targetId, "namespace": targetNamespace]] as [String: Any]]]
    )
    
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  /// Unlink an entity from another entity using the target entity directly.
  ///
  /// This is a convenience method that extracts the ID and namespace from the target entity.
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(.instantSync(Schema.posts.with(\.author))) var posts: [Post]
  ///
  /// // Unlink a post from its author
  /// try await $posts.unlink(post.id, "author", from: profile)
  /// ```
  ///
  /// - Parameters:
  ///   - id: The ID of the entity to unlink from
  ///   - label: The link label (e.g., "author", "creator")
  ///   - target: The entity to unlink from
  /// - Throws: If the transaction fails
  @MainActor
  public func unlink<Element: EntityIdentifiable & Sendable, Target: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    from target: Target
  ) async throws where Value: RangeReplaceableCollection, Value.Element == Element {
    try await unlink(id, label, from: target.id, namespace: Target.namespace)
  }
}

// MARK: - IdentifiedArray Support

extension Shared {
  
  /// Create a new entity and sync to InstantDB (IdentifiedArray version).
  ///
  /// ## How This Works (TypeScript SDK Pattern)
  ///
  /// Following the TypeScript InstantDB SDK architecture:
  /// 1. Generate a transaction chunk with the entity data
  /// 2. Send to Reactor.transact() which:
  ///    - Applies optimistic update to triple store
  ///    - Notifies subscriptions via handleOptimisticUpsert()
  ///    - Sends transaction to server
  /// 3. The subscription's AsyncStream yields the new value
  /// 4. InstantSyncKey.subscribe() updates the @Shared value
  ///
  /// We do NOT use withLock here because:
  /// - withLock triggers save() which computes diffs
  /// - Diff computation can race with other mutations and generate incorrect deletes
  /// - The TypeScript SDK never uses diff-based saves for explicit mutations
  @MainActor
  public func create<Element: EntityIdentifiable & Encodable & Sendable>(
    _ entity: Element
  ) async throws where Value == IdentifiedArrayOf<Element> {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID

    // 1. Generate explicit transaction chunk
    let namespace = Element.namespace
    let attrs = try encodeEntityAttributes(entity)

    let chunk = TransactionChunk(
      namespace: namespace,
      id: entity.id,
      ops: [["update", namespace, entity.id, attrs]]
    )

    // 2. Send to Reactor which handles:
    //    - Optimistic update to triple store
    //    - Subscription notification (updates @Shared value)
    //    - Server transaction
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  /// Delete an entity by ID and sync to InstantDB (IdentifiedArray version).
  ///
  /// Following TypeScript SDK pattern - no withLock to avoid triggering diff-based save.
  @MainActor
  public func delete<Element: EntityIdentifiable & Sendable>(
    id: String
  ) async throws where Value == IdentifiedArrayOf<Element> {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    // Generate explicit delete chunk
    let namespace = Element.namespace
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["delete", namespace, id]]
    )
    
    // Send to Reactor which handles optimistic update + server transaction
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  /// Update an entity's fields and sync to InstantDB (IdentifiedArray version).
  ///
  /// Following TypeScript SDK pattern - we need to read the current entity to apply
  /// the modification, but we don't use withLock to avoid triggering diff-based save.
  ///
  /// **Important**: This method sends only the CHANGED fields, not the entire entity.
  /// This prevents concurrent updates from clobbering each other (e.g., updating
  /// `text` and `words` simultaneously on a transcription segment).
  ///
  /// ## Why We Read From TripleStore
  /// The `wrappedValue` is updated asynchronously via AsyncStream. When `create()`
  /// and `update()` are called in rapid succession:
  /// 1. `create()` applies optimistic update to TripleStore (synchronous)
  /// 2. `create()` yields to AsyncStream (asynchronous delivery)
  /// 3. `update()` reads `wrappedValue` → entity not found (stream not consumed yet)
  ///
  /// By reading from the TripleStore directly, we get the latest state including
  /// optimistic updates that haven't yet flowed through to `wrappedValue`.
  @MainActor
  public func update<Element: EntityIdentifiable & Encodable & Sendable>(
    id: String,
    _ modify: (inout Element) -> Void
  ) async throws where Value == IdentifiedArrayOf<Element> {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID

    // Read from TripleStore directly to get optimistic updates that may not have
    // propagated to wrappedValue yet. Fall back to wrappedValue for backward compat.
    var entity: Element
    if let storeEntity: Element = await reactor.getEntity(id: id) {
      entity = storeEntity
    } else if let wrappedEntity = wrappedValue[id: id] {
      entity = wrappedEntity
    } else {
      throw InstantMutationError.entityNotFound(id: id, namespace: Element.namespace)
    }

    // Encode BEFORE modification to compare
    let beforeAttrs = try encodeEntityAttributes(entity)

    // Apply modification locally
    modify(&entity)

    // Encode AFTER modification
    let afterAttrs = try encodeEntityAttributes(entity)

    // Compute only the changed fields (field-level update)
    // This prevents concurrent updates from clobbering each other
    let changedAttrs = computeChangedFields(before: beforeAttrs, after: afterAttrs)

    guard !changedAttrs.isEmpty else {
      // No actual changes - nothing to do
      return
    }

    // Generate explicit update chunk with ONLY changed fields
    let namespace = Element.namespace

    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["update", namespace, id, changedAttrs]]
    )

    // Send to Reactor which handles optimistic update + server transaction
    try await reactor.transact(appID: appID, chunks: [chunk])
  }

  /// Update a single field of an entity without reading the full entity first.
  ///
  /// This is the safest method for concurrent updates because it:
  /// 1. Does NOT read the current entity (avoids stale snapshots)
  /// 2. Sends ONLY the specified field to the server
  /// 3. Cannot clobber other fields being updated concurrently
  ///
  /// ## Example
  ///
  /// ```swift
  /// // Update just the text field - safe even if words is being updated concurrently
  /// try await $segments.updateField(id: segmentId, field: "text", value: "New text")
  /// ```
  ///
  /// - Parameters:
  ///   - id: The ID of the entity to update
  ///   - field: The field name to update
  ///   - value: The new value for the field
  /// - Throws: If the transaction fails
  @MainActor
  public func updateField<Element: EntityIdentifiable & Sendable>(
    id: String,
    field: String,
    value: Any
  ) async throws where Value == IdentifiedArrayOf<Element> {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID

    let namespace = Element.namespace

    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["update", namespace, id, [field: value]]]
    )

    try await reactor.transact(appID: appID, chunks: [chunk])
  }

  /// Update multiple fields of an entity without reading the full entity first.
  ///
  /// This method sends ONLY the specified fields, preventing concurrent updates
  /// from clobbering each other.
  ///
  /// ## Example
  ///
  /// ```swift
  /// try await $segments.updateFields(id: segmentId, fields: [
  ///   "text": "New text",
  ///   "endTime": 1.5
  /// ])
  /// ```
  @MainActor
  public func updateFields<Element: EntityIdentifiable & Sendable>(
    id: String,
    fields: [String: Any]
  ) async throws where Value == IdentifiedArrayOf<Element> {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID

    guard !fields.isEmpty else { return }

    let namespace = Element.namespace

    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["update", namespace, id, fields]]
    )

    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  /// Link an entity to another entity (IdentifiedArray version).
  @MainActor
  public func link<Element: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    to targetId: String,
    namespace targetNamespace: String
  ) async throws where Value == IdentifiedArrayOf<Element> {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    let namespace = Element.namespace

    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["link", namespace, id, [label: ["id": targetId, "namespace": targetNamespace]] as [String: Any]]]
    )
    
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  /// Link an entity to another entity using the target entity directly (IdentifiedArray version).
  @MainActor
  public func link<Element: EntityIdentifiable & Sendable, Target: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    to target: Target
  ) async throws where Value == IdentifiedArrayOf<Element> {
    try await link(id, label, to: target.id, namespace: Target.namespace)
  }
  
  /// Unlink an entity from another entity (IdentifiedArray version).
  @MainActor
  public func unlink<Element: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    from targetId: String,
    namespace targetNamespace: String
  ) async throws where Value == IdentifiedArrayOf<Element> {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    let namespace = Element.namespace
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["unlink", namespace, id, [label: ["id": targetId, "namespace": targetNamespace]] as [String: Any]]]
    )
    
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  /// Unlink an entity from another entity using the target entity directly (IdentifiedArray version).
  @MainActor
  public func unlink<Element: EntityIdentifiable & Sendable, Target: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    from target: Target
  ) async throws where Value == IdentifiedArrayOf<Element> {
    try await unlink(id, label, from: target.id, namespace: Target.namespace)
  }
}

// MARK: - Errors

/// Errors that can occur during explicit mutations.
public enum InstantMutationError: Error, LocalizedError {
  case entityNotFound(id: String, namespace: String)
  case encodingFailed(Error)
  
  public var errorDescription: String? {
    switch self {
    case .entityNotFound(let id, let namespace):
      return "Entity not found: \(namespace)/\(id)"
    case .encodingFailed(let error):
      return "Failed to encode entity: \(error.localizedDescription)"
    }
  }
}

// MARK: - Helpers

/// Compute only the fields that changed between two encoded attribute dictionaries.
///
/// This is critical for preventing concurrent update clobbering. When two updates
/// run simultaneously:
/// - Update A reads entity, modifies `text`, encodes all attrs including stale `words`
/// - Update B reads entity, modifies `words`, encodes all attrs including stale `text`
///
/// Without field-level diffing, whichever update arrives at the server last
/// clobbers the other's changes.
///
/// With field-level diffing:
/// - Update A sends only `{text: "new text"}`
/// - Update B sends only `{words: [...]}`
/// - Both updates succeed without clobbering
private func computeChangedFields(
  before: [String: Any],
  after: [String: Any]
) -> [String: Any] {
  var changed: [String: Any] = [:]

  for (key, afterValue) in after {
    if let beforeValue = before[key] {
      // Field existed before - check if it changed
      if !valuesAreEqual(beforeValue, afterValue) {
        changed[key] = afterValue
      }
    } else {
      // New field
      changed[key] = afterValue
    }
  }

  // Also check for removed fields (set to nil)
  for key in before.keys {
    if after[key] == nil {
      changed[key] = NSNull()
    }
  }

  return changed
}

/// Compare two values for equality.
///
/// This handles the various types that can appear in encoded entity attributes.
private func valuesAreEqual(_ lhs: Any, _ rhs: Any) -> Bool {
  // Handle NSNull
  if lhs is NSNull && rhs is NSNull {
    return true
  }

  // Handle primitives
  if let l = lhs as? String, let r = rhs as? String {
    return l == r
  }
  if let l = lhs as? Double, let r = rhs as? Double {
    return l == r
  }
  if let l = lhs as? Int, let r = rhs as? Int {
    return l == r
  }
  if let l = lhs as? Bool, let r = rhs as? Bool {
    return l == r
  }

  // Handle arrays (JSON fields like `words`)
  if let l = lhs as? [Any], let r = rhs as? [Any] {
    guard l.count == r.count else { return false }
    for (i, lVal) in l.enumerated() {
      if !valuesAreEqual(lVal, r[i]) {
        return false
      }
    }
    return true
  }

  // Handle dictionaries (nested objects)
  if let l = lhs as? [String: Any], let r = rhs as? [String: Any] {
    guard l.count == r.count else { return false }
    for (key, lVal) in l {
      guard let rVal = r[key], valuesAreEqual(lVal, rVal) else {
        return false
      }
    }
    return true
  }

  // Different types = not equal
  return false
}

/// Encode an entity's attributes to a dictionary for the transaction.
///
/// This extracts all properties except `id` and link properties (which are
/// handled separately via link operations).
///
/// ## Why We Use a Custom Encoder
///
/// The naive approach of `JSONEncoder` + `JSONSerialization.jsonObject()` has a critical bug:
/// `JSONSerialization` uses `NSNumber` for both numbers and booleans, and Swift's bridging
/// can interpret `0`/`1` as `false`/`true`. This causes InstantDB server errors like:
/// "Invalid value type for tiles.x. Value must be a number but the provided value type is boolean."
///
/// Instead, we use a custom `DictionaryEncoder` that preserves type information.
private func encodeEntityAttributes<E: Encodable>(_ entity: E) throws -> [String: Any] {
  let encoder = DictionaryEncoder()
  let dict = try encoder.encode(entity)

  // Filter out id (handled separately)
  // Note: We NO LONGER filter out arrays/objects - they can be JSON fields!
  // The TypeScript SDK sends JSON arrays (like `words: [{text, startTime, endTime}]`)
  // as regular attributes, not as links.
  var attrs: [String: Any] = [:]
  for (key, value) in dict {
    // Skip id - it's handled separately
    if key == "id" { continue }

    // Skip nil values
    if case Optional<Any>.none = value { continue }
    if value is NSNull { continue }

    attrs[key] = value
  }

  return attrs
}

// MARK: - Dictionary Encoder

/// A custom encoder that encodes `Encodable` values directly to `[String: Any]` dictionaries.
///
/// Unlike `JSONEncoder` + `JSONSerialization`, this preserves type information correctly:
/// - `Double` values stay as `Double` (not converted to `NSNumber` which might be interpreted as `Bool`)
/// - `Bool` values stay as `Bool`
/// - `Int` values stay as `Int`
///
/// This is critical for InstantDB which strictly validates types.
private class DictionaryEncoder {
  func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
    let encoder = _DictionaryEncoder()
    try value.encode(to: encoder)
    guard let dict = encoder.result as? [String: Any] else {
      throw InstantMutationError.encodingFailed(
        NSError(domain: "SharingInstant", code: -1, userInfo: [
          NSLocalizedDescriptionKey: "Failed to encode entity to dictionary"
        ])
      )
    }
    return dict
  }
}

private class _DictionaryEncoder: Encoder {
  var codingPath: [CodingKey] = []
  var userInfo: [CodingUserInfoKey: Any] = [:]
  var result: Any?
  
  func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    let container = _KeyedEncodingContainer<Key>(encoder: self, codingPath: codingPath)
    return KeyedEncodingContainer(container)
  }
  
  func unkeyedContainer() -> UnkeyedEncodingContainer {
    return _UnkeyedEncodingContainer(encoder: self, codingPath: codingPath)
  }
  
  func singleValueContainer() -> SingleValueEncodingContainer {
    return _SingleValueEncodingContainer(encoder: self, codingPath: codingPath)
  }
}

private class _KeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
  private let encoder: _DictionaryEncoder
  var codingPath: [CodingKey]
  private var storage: [String: Any] = [:]
  
  init(encoder: _DictionaryEncoder, codingPath: [CodingKey]) {
    self.encoder = encoder
    self.codingPath = codingPath
  }
  
  deinit {
    encoder.result = storage
  }
  
  func encodeNil(forKey key: Key) throws {
    storage[key.stringValue] = NSNull()
  }
  
  func encode(_ value: Bool, forKey key: Key) throws {
    storage[key.stringValue] = value
  }
  
  func encode(_ value: String, forKey key: Key) throws {
    storage[key.stringValue] = value
  }
  
  func encode(_ value: Double, forKey key: Key) throws {
    storage[key.stringValue] = value
  }
  
  func encode(_ value: Float, forKey key: Key) throws {
    storage[key.stringValue] = Double(value)
  }
  
  func encode(_ value: Int, forKey key: Key) throws {
    storage[key.stringValue] = value
  }
  
  func encode(_ value: Int8, forKey key: Key) throws {
    storage[key.stringValue] = Int(value)
  }
  
  func encode(_ value: Int16, forKey key: Key) throws {
    storage[key.stringValue] = Int(value)
  }
  
  func encode(_ value: Int32, forKey key: Key) throws {
    storage[key.stringValue] = Int(value)
  }
  
  func encode(_ value: Int64, forKey key: Key) throws {
    storage[key.stringValue] = Int(value)
  }
  
  func encode(_ value: UInt, forKey key: Key) throws {
    storage[key.stringValue] = Int(value)
  }
  
  func encode(_ value: UInt8, forKey key: Key) throws {
    storage[key.stringValue] = Int(value)
  }
  
  func encode(_ value: UInt16, forKey key: Key) throws {
    storage[key.stringValue] = Int(value)
  }
  
  func encode(_ value: UInt32, forKey key: Key) throws {
    storage[key.stringValue] = Int(value)
  }
  
  func encode(_ value: UInt64, forKey key: Key) throws {
    storage[key.stringValue] = Int(value)
  }
  
  func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
    let nestedEncoder = _DictionaryEncoder()
    nestedEncoder.codingPath = codingPath + [key]
    try value.encode(to: nestedEncoder)
    storage[key.stringValue] = nestedEncoder.result
  }
  
  func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
    let container = _KeyedEncodingContainer<NestedKey>(encoder: encoder, codingPath: codingPath + [key])
    return KeyedEncodingContainer(container)
  }
  
  func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
    return _UnkeyedEncodingContainer(encoder: encoder, codingPath: codingPath + [key])
  }
  
  func superEncoder() -> Encoder {
    return encoder
  }
  
  func superEncoder(forKey key: Key) -> Encoder {
    return encoder
  }
}

private class _UnkeyedEncodingContainer: UnkeyedEncodingContainer {
  private let encoder: _DictionaryEncoder
  var codingPath: [CodingKey]
  var count: Int = 0
  private var storage: [Any] = []
  
  init(encoder: _DictionaryEncoder, codingPath: [CodingKey]) {
    self.encoder = encoder
    self.codingPath = codingPath
  }
  
  deinit {
    encoder.result = storage
  }
  
  func encodeNil() throws {
    storage.append(NSNull())
    count += 1
  }
  
  func encode(_ value: Bool) throws {
    storage.append(value)
    count += 1
  }
  
  func encode(_ value: String) throws {
    storage.append(value)
    count += 1
  }
  
  func encode(_ value: Double) throws {
    storage.append(value)
    count += 1
  }
  
  func encode(_ value: Float) throws {
    storage.append(Double(value))
    count += 1
  }
  
  func encode(_ value: Int) throws {
    storage.append(value)
    count += 1
  }
  
  func encode(_ value: Int8) throws {
    storage.append(Int(value))
    count += 1
  }
  
  func encode(_ value: Int16) throws {
    storage.append(Int(value))
    count += 1
  }
  
  func encode(_ value: Int32) throws {
    storage.append(Int(value))
    count += 1
  }
  
  func encode(_ value: Int64) throws {
    storage.append(Int(value))
    count += 1
  }
  
  func encode(_ value: UInt) throws {
    storage.append(Int(value))
    count += 1
  }
  
  func encode(_ value: UInt8) throws {
    storage.append(Int(value))
    count += 1
  }
  
  func encode(_ value: UInt16) throws {
    storage.append(Int(value))
    count += 1
  }
  
  func encode(_ value: UInt32) throws {
    storage.append(Int(value))
    count += 1
  }
  
  func encode(_ value: UInt64) throws {
    storage.append(Int(value))
    count += 1
  }
  
  func encode<T: Encodable>(_ value: T) throws {
    let nestedEncoder = _DictionaryEncoder()
    try value.encode(to: nestedEncoder)
    // Unwrap the optional to avoid storing Optional wrapper in the array
    if let result = nestedEncoder.result {
      storage.append(result)
    } else {
      storage.append(NSNull())
    }
    count += 1
  }
  
  func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
    let container = _KeyedEncodingContainer<NestedKey>(encoder: encoder, codingPath: codingPath)
    return KeyedEncodingContainer(container)
  }
  
  func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
    return _UnkeyedEncodingContainer(encoder: encoder, codingPath: codingPath)
  }
  
  func superEncoder() -> Encoder {
    return encoder
  }
}

private class _SingleValueEncodingContainer: SingleValueEncodingContainer {
  private let encoder: _DictionaryEncoder
  var codingPath: [CodingKey]
  
  init(encoder: _DictionaryEncoder, codingPath: [CodingKey]) {
    self.encoder = encoder
    self.codingPath = codingPath
  }
  
  func encodeNil() throws {
    encoder.result = NSNull()
  }
  
  func encode(_ value: Bool) throws {
    encoder.result = value
  }
  
  func encode(_ value: String) throws {
    encoder.result = value
  }
  
  func encode(_ value: Double) throws {
    encoder.result = value
  }
  
  func encode(_ value: Float) throws {
    encoder.result = Double(value)
  }
  
  func encode(_ value: Int) throws {
    encoder.result = value
  }
  
  func encode(_ value: Int8) throws {
    encoder.result = Int(value)
  }
  
  func encode(_ value: Int16) throws {
    encoder.result = Int(value)
  }
  
  func encode(_ value: Int32) throws {
    encoder.result = Int(value)
  }
  
  func encode(_ value: Int64) throws {
    encoder.result = Int(value)
  }
  
  func encode(_ value: UInt) throws {
    encoder.result = Int(value)
  }
  
  func encode(_ value: UInt8) throws {
    encoder.result = Int(value)
  }
  
  func encode(_ value: UInt16) throws {
    encoder.result = Int(value)
  }
  
  func encode(_ value: UInt32) throws {
    encoder.result = Int(value)
  }
  
  func encode(_ value: UInt64) throws {
    encoder.result = Int(value)
  }
  
  func encode<T: Encodable>(_ value: T) throws {
    let nestedEncoder = _DictionaryEncoder()
    try value.encode(to: nestedEncoder)
    encoder.result = nestedEncoder.result
  }
}
