import Foundation
import InstantDB
import Dependencies
import Sharing
@preconcurrency import Combine

/// Adapted from: instant-client/src/client_db.ts (Reactor logic)
///
/// The central coordinator for InstantDB data.
///
/// The Reactor manages:
/// 1. Connections to InstantDB (via InstantClient).
/// 2. Subscriptions to queries.
/// 3. The Shared TripleStore.

// #region agent log
/// Debug logging helper for Cursor debug mode - sends via HTTP to Mac
/// Logs are queued and persisted to disk, then sent when network is available.
///
/// To use:
/// 1. Run: python3 Scripts/debug-log-server.py 7248
/// 2. Update the IP below to your Mac's local IP
private let debugLogServerURL = "http://192.168.68.111:7248/ingest/debug"

/// Actor to manage thread-safe debug log queue with persistence
private actor DebugLogQueue {
    static let shared = DebugLogQueue()

    private let fileURL: URL
    private var isFlushing = false

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.fileURL = docs.appendingPathComponent("debug-logs-queue.jsonl")
    }

    func enqueue(_ jsonData: Data) {
        // Append to file (JSONL format - one JSON object per line)
        if let line = String(data: jsonData, encoding: .utf8) {
            let lineWithNewline = line + "\n"
            if let lineData = lineWithNewline.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: fileURL) {
                        handle.seekToEndOfFile()
                        handle.write(lineData)
                        try? handle.close()
                    }
                } else {
                    try? lineData.write(to: fileURL)
                }
            }
        }

        // Try to flush immediately
        Task {
            await flush()
        }
    }

    func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }

        guard let ingestURL = URL(string: debugLogServerURL) else { return }

        var successCount = 0

        for line in lines {
            guard let jsonData = line.data(using: .utf8) else {
                successCount += 1 // Skip malformed
                continue
            }

            var request = URLRequest(url: ingestURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData
            request.timeoutInterval = 5

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    successCount += 1
                } else {
                    break // Server error, stop
                }
            } catch {
                // Network error - stop trying, will retry later
                break
            }
        }

        // Remove successfully sent logs by rewriting file with remaining lines
        if successCount > 0 {
            let remainingLines = Array(lines.dropFirst(successCount))
            if remainingLines.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                let remainingContent = remainingLines.joined(separator: "\n") + "\n"
                try? remainingContent.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }
}

private func reactorDebugLog(_ message: String, data: [String: Any] = [:], hypothesisId: String = "RESTORE", file: String = #file, line: Int = #line) {
    #if DEBUG
    let fileName = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
    let location = "\(fileName):\(line)"

    // Print to Xcode console for local debugging
    let dataStr = data.isEmpty ? "" : " | \(data.map { "\($0.key): \($0.value)" }.joined(separator: ", "))"
    print("[RESTORE] [\(location)] \(message)\(dataStr)")

    // Queue for HTTP delivery (persisted to disk, sent when online)
    // Convert to JSON Data immediately to make it Sendable
    let payload: [String: Any] = [
        "location": location,
        "message": message,
        "data": data,
        "timestamp": Date().timeIntervalSince1970 * 1000,
        "sessionId": "debug-session",
        "hypothesisId": hypothesisId
    ]

    if let jsonData = try? JSONSerialization.data(withJSONObject: payload) {
        Task {
            await DebugLogQueue.shared.enqueue(jsonData)
        }
    }
    #endif
}

/// Call this when the app comes back online to flush queued logs
public func flushDebugLogs() {
    #if DEBUG
    Task {
        await DebugLogQueue.shared.flush()
    }
    #endif
}
// #endregion

public actor Reactor {
  // public static let shared = Reactor() // Removed for DI


  private let store: SharedTripleStore
  private let clientInstanceID: String
  private var activeSubscriptions: [UUID: SubscriptionHandle] = [:]

  /// Tracks whether we've restored pending mutations from SQLite.
  ///
  /// ## Why This Exists
  /// When the app restarts, pending mutations (optimistic updates that haven't been
  /// confirmed by the server) are persisted in SQLite but not in the in-memory
  /// SharedTripleStore. Without restoring them, the UI would show stale data until
  /// the server confirms the mutations (which requires network connectivity).
  ///
  /// This flag ensures we only restore once per app launch to avoid duplicate
  /// application of the same mutations.
  private var hasRestoredPendingMutations: Bool = false

  public init(store: SharedTripleStore, clientInstanceID: String = "default") {
    self.store = store
    self.clientInstanceID = clientInstanceID
  }

  // MARK: - Pending Mutation Restoration

  /// Restores pending mutations from SQLite to the in-memory SharedTripleStore.
  ///
  /// ## Why This Exists
  /// When the app restarts, pending mutations are persisted in SQLite but not in
  /// the in-memory SharedTripleStore. This method re-applies those mutations so
  /// users see their changes immediately, even before the server confirms them.
  ///
  /// This matches the TypeScript SDK behavior where `pendingMutations` are merged
  /// into query results via `_applyOptimisticUpdates()`.
  ///
  /// - Parameter client: The InstantClient to load pending mutations from
  private func restorePendingMutationsIfNeeded(client: InstantClient, appID: String) async {
    guard !hasRestoredPendingMutations else {
      reactorDebugLog("restorePendingMutations: SKIPPED - already restored")
      return
    }
    hasRestoredPendingMutations = true

    reactorDebugLog("restorePendingMutations: START", data: [
      "activeSubscriptionCount": activeSubscriptions.count,
      "subscriptionNamespaces": activeSubscriptions.values.map { $0.namespace }
    ])

    let pending = await client.getUnconfirmedPendingMutations()
    guard !pending.isEmpty else {
      reactorDebugLog("restorePendingMutations: no pending mutations to restore")
      return
    }

    reactorDebugLog("restorePendingMutations: found \(pending.count) pending mutations", data: [
      "mutationEventIds": pending.map { $0.eventId }
    ])

    // Get current attributes for cardinality information
    let attrs = await MainActor.run { client.attributes }
    reactorDebugLog("restorePendingMutations: got attributes", data: [
      "attrCount": attrs.count
    ])
    if !attrs.isEmpty {
      store.updateAttributes(attrs)
    }

    // Track all entity IDs we're restoring so we can notify subscriptions properly
    var restoredEntityIds: [(namespace: String, id: String)] = []

    // Apply each pending mutation to the local store
    for mutation in pending {
      let entityIds = applyPendingMutationToStore(mutation)
      restoredEntityIds.append(contentsOf: entityIds)
    }

    reactorDebugLog("restorePendingMutations: applied to store", data: [
      "restoredEntityCount": restoredEntityIds.count,
      "restoredEntityIds": restoredEntityIds.map { "\($0.namespace):\($0.id)" }
    ])

    // CRITICAL: We must notify with specific entity IDs, not just notifyAll()
    // because notifyAll() uses "__notifyAll__" sentinel which doesn't add to currentIDs.
    // If currentIDs is empty (no server data yet), the subscription yields nothing.
    for (namespace, id) in restoredEntityIds {
      await notifyOptimisticUpsert(namespace: namespace, id: id)
    }

    reactorDebugLog("restorePendingMutations: notified subscriptions", data: [
      "notifiedCount": restoredEntityIds.count
    ])

    // Also do a full notifyAll to ensure any complex queries recompute
    await notifyAll()

    reactorDebugLog("restorePendingMutations: COMPLETE", data: [
      "restoredCount": pending.count,
      "entityIds": restoredEntityIds.map { $0.id }
    ])
  }

  /// Applies a single pending mutation's tx-steps to the local TripleStore.
  ///
  /// This parses the raw tx-steps format and applies creates/updates/deletes
  /// to the SharedTripleStore, making the data immediately visible to subscriptions.
  ///
  /// - Returns: Array of (namespace, entityId) tuples for entities that were modified
  private func applyPendingMutationToStore(_ mutation: PendingMutation) -> [(namespace: String, id: String)] {
    let timestamp = ConflictResolution.optimisticTimestamp()
    var modifiedEntities: [(namespace: String, id: String)] = []

    for step in mutation.txSteps {
      // CRITICAL FIX: step is [AnyCodableValue], not [Any].
      // We must access .value on each element to get the underlying value.
      guard step.count >= 1,
            let action = step[0].value as? String else {
        continue
      }

      switch action {
      case "add-triple":
        // Format: ["add-triple", entityId, attrId, value, ...]
        guard step.count >= 4,
              let entityId = step[1].value as? String,
              let attrId = step[2].value as? String else {
          continue
        }
        let rawValue = step[3].value
        let value = convertToTripleValue(rawValue)

        let triple = Triple(
          entityId: entityId,
          attributeId: attrId,
          value: value,
          createdAt: timestamp
        )
        let attr = store.attrsStore.getAttr(attrId)
        let hasCardinalityOne = attr?.cardinality == .one
        let isRef = attr?.valueType == .ref
        store.addTriple(triple, hasCardinalityOne: hasCardinalityOne, isRef: isRef)

        // Extract namespace from attrId (format: "namespace/field")
        let namespace = attrId.components(separatedBy: "/").first ?? "unknown"
        if !modifiedEntities.contains(where: { $0.id == entityId }) {
          modifiedEntities.append((namespace: namespace, id: entityId))
        }

      case "retract-triple":
        // Format: ["retract-triple", entityId, attrId, value, ...]
        guard step.count >= 4,
              let entityId = step[1].value as? String,
              let attrId = step[2].value as? String else {
          continue
        }
        let rawValue = step[3].value
        let value = convertToTripleValue(rawValue)

        let triple = Triple(
          entityId: entityId,
          attributeId: attrId,
          value: value,
          createdAt: timestamp
        )
        let attr = store.attrsStore.getAttr(attrId)
        let isRef = attr?.valueType == .ref
        store.retractTriple(triple, isRef: isRef)

        let namespace = attrId.components(separatedBy: "/").first ?? "unknown"
        if !modifiedEntities.contains(where: { $0.id == entityId }) {
          modifiedEntities.append((namespace: namespace, id: entityId))
        }

      case "delete-entity":
        // Format: ["delete-entity", namespace, entityId]
        guard step.count >= 3,
              let namespace = step[1].value as? String,
              let entityId = step[2].value as? String else {
          continue
        }
        store.deleteEntity(id: entityId)
        // Don't add to modifiedEntities since it's deleted

      default:
        // Skip add-attr, update-attr, etc. - they're handled by the server
        break
      }
    }

    reactorDebugLog("applyPendingMutationToStore: processed mutation", data: [
      "eventId": mutation.eventId,
      "stepCount": mutation.txSteps.count,
      "modifiedEntities": modifiedEntities.map { "\($0.namespace):\($0.id)" }
    ])

    return modifiedEntities
  }

  /// Converts a raw value from tx-steps to a TripleValue.
  private func convertToTripleValue(_ rawValue: Any) -> TripleValue {
    switch rawValue {
    case let s as String:
      return .string(s)
    case let i as Int:
      return .double(Double(i))
    case let i as Int64:
      return .double(Double(i))
    case let d as Double:
      return .double(d)
    case let b as Bool:
      return .bool(b)
    case is NSNull:
      return .null
    default:
      // For complex types, try to represent as string
      return .string(String(describing: rawValue))
    }
  }

  // MARK: - Schema Readiness
  
  private enum SubscriptionFilter: Sendable, Equatable {
    case matchAll
    case idEquals(String)
    case unsupported
  }
  
  private struct SubscriptionHandle: Sendable {
    let namespace: String
    let filter: SubscriptionFilter
    let upsert: @Sendable (String) async -> Void
    let delete: @Sendable (String) async -> Void
  }

  private func waitForAttributes(
    client: InstantClient,
    timeoutSeconds: TimeInterval,
    logContext: [String: Any]
  ) async -> [Attribute] {
    let deadline = Date().addingTimeInterval(timeoutSeconds)

    while Date() < deadline {
      let attrs = await MainActor.run { client.attributes }
      if !attrs.isEmpty { return attrs }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }

    let attrs = await MainActor.run { client.attributes }
    if attrs.isEmpty {
      let contextDescription = logContext
        .map { "\($0.key): \(String(describing: $0.value))" }
        .sorted()
        .joined(separator: ", ")

      await MainActor.run {
        InstantLogger.warning(
          """
          Reactor timed out waiting for schema attributes.

          WHAT HAPPENED:
            The client reported an authenticated WebSocket connection, but the schema
            attributes were not available yet. Without attributes, we cannot normalize
            InstaQL trees into triples reliably.

          WHY THIS MATTERS:
            Without schema, the triple store drops unknown fields, which can lead to
            missing required fields when decoding entities from the store.

          HOW TO FIX:
            • Ensure the server's `init-ok` includes `attrs`.
            • If this is a race, increase the wait window or refactor to await the
              SDK's init processing before subscribing/transacting.

          CONTEXT:
            \(contextDescription)
          """,
          json: nil
        )
      }
    }

    return attrs
  }

  private func subscriptionFilter(whereClause: [String: Any]?) -> SubscriptionFilter {
    guard let whereClause else { return .matchAll }
    
    if let id = whereClause["id"] as? String {
      return .idEquals(id)
    }
    
    if let dict = whereClause["id"] as? [String: Any],
       let eq = dict["$eq"] as? String {
      return .idEquals(eq)
    }
    
    return .unsupported
  }
  
  /// Notifies ALL active subscriptions to recompute their data from the store.
  ///
  /// ## Why This Exists (TypeScript Parity)
  /// The TypeScript SDK's `notifyAll()` (Reactor.js lines 1303-1310) recomputes ALL
  /// subscriptions after any mutation. This ensures:
  /// - Cross-namespace consistency (e.g., a link mutation affects both sides)
  /// - Correct filtering (subscriptions with complex WHERE clauses recompute)
  /// - No missed updates (even if we can't predict which subscriptions are affected)
  ///
  /// ## Performance Note
  /// This is intentionally aggressive. The TypeScript SDK does the same because
  /// correctness trumps optimization. Each subscription reads from the normalized
  /// store which is fast, and deduplication happens at the UI layer.
  private func notifyAll() async {
    for (_, handle) in activeSubscriptions {
      // Trigger a recompute by calling upsert with a sentinel ID.
      // The SubscriptionState will re-read from the store and yield new values.
      await handle.upsert("__notifyAll__")
    }
  }

  private func notifyOptimisticUpsert(namespace: String, id: String) async {
    let matchingHandles = activeSubscriptions.values.filter { $0.namespace == namespace }
    reactorDebugLog("notifyOptimisticUpsert", data: [
      "namespace": namespace,
      "id": id,
      "totalSubscriptions": activeSubscriptions.count,
      "matchingSubscriptions": matchingHandles.count,
      "allNamespaces": activeSubscriptions.values.map { $0.namespace }
    ])

    for (_, handle) in activeSubscriptions where handle.namespace == namespace {
      switch handle.filter {
      case .matchAll:
        reactorDebugLog("notifyOptimisticUpsert: calling upsert (matchAll)", data: [
          "namespace": namespace,
          "id": id
        ])
        await handle.upsert(id)
      case .idEquals(let expectedId):
        guard expectedId == id else { continue }
        reactorDebugLog("notifyOptimisticUpsert: calling upsert (idEquals)", data: [
          "namespace": namespace,
          "id": id
        ])
        await handle.upsert(id)
      case .unsupported:
        continue
      }
    }
  }

  private func notifyOptimisticDelete(namespace: String, id: String) async {
    for handle in activeSubscriptions.values where handle.namespace == namespace {
      switch handle.filter {
      case .matchAll:
        await handle.delete(id)
      case .idEquals(let expectedId):
        guard expectedId == id else { continue }
        await handle.delete(id)
      case .unsupported:
        continue
      }
    }
  }
  
  public func subscribe<Value: EntityIdentifiable & Codable & Sendable>(
    appID: String,
    configuration: SharingInstantSync.CollectionConfiguration<Value>
  ) -> AsyncStream<[Value]> {
    AsyncStream { continuation in
      let task = Task {
        // Start subscription immediately so cached results can be delivered
        // even when offline (JS core semantics).
        await self.startSubscription(
          appID: appID,
          namespace: configuration.namespace,
          orderBy: configuration.orderBy,
          limit: nil,
          whereClause: configuration.whereClause,
          linkTree: configuration.linkTree,
          includedLinks: configuration.includedLinks,
          continuation: continuation
        )
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  /// Subscribes to a query and returns a stream of results (Read-only version).
  public func subscribe<Value: EntityIdentifiable & Codable & Sendable>(
    appID: String,
    configuration: SharingInstantQuery.Configuration<Value>
  ) -> AsyncStream<[Value]> {
    AsyncStream { continuation in
      let task = Task {
          await self.startSubscription(
            appID: appID,
            namespace: configuration.namespace,
            orderBy: configuration.orderBy,
            limit: configuration.limit,
            whereClause: configuration.whereClause,
            linkTree: configuration.linkTree,
            includedLinks: configuration.includedLinks,
            continuation: continuation
          )
      }
      
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  /// Performs a transaction (write) to InstantDB.
  ///
  /// ## Local-first Semantics
  /// - Applies an optimistic update to the local triple store immediately so subscribers can see
  ///   their own writes without waiting for a server round trip.
  /// - Persists the mutation via the Instant iOS SDK and enqueues it when offline.
  /// - Automatically flushes queued mutations once the WebSocket session reconnects.
  ///
  /// - Parameters:
  ///   - appID: The App ID.
  ///   - chunks: The transaction chunks to execute.
  /// Reads an entity directly from the local TripleStore.
  ///
  /// ## Why This Exists
  /// The `update()` mutation method needs to read the current entity state before
  /// applying modifications. However, `wrappedValue` is updated asynchronously via
  /// AsyncStream, which creates a race condition:
  ///
  /// 1. `create()` applies optimistic update to TripleStore
  /// 2. `create()` yields to AsyncStream
  /// 3. **AsyncStream consumer hasn't run yet**
  /// 4. `update()` reads `wrappedValue[id: id]` → entity not found!
  ///
  /// By reading directly from the TripleStore (which IS updated synchronously in
  /// step 1), we avoid this race condition.
  ///
  /// - Parameters:
  ///   - id: The entity ID to read
  /// - Returns: The entity if found and decodable, nil otherwise
  public func getEntity<T: Decodable>(id: String) -> T? {
    store.get(id: id)
  }

  public func transact(
    appID: String,
    chunks: [TransactionChunk]
  ) async throws {
    // #region agent log - H10: Trace transact timing
    let transactStart = Date()
    let chunkIds = chunks.map { $0.id }
    reactorDebugLog("transact START", data: ["chunkIds": chunkIds])
    // #endregion
    
    let client = await MainActor.run { InstantClientFactory.makeClient(appID: appID, instanceID: self.clientInstanceID) }
    // #region agent log
    reactorDebugLog("transact: got client", data: ["elapsed_ms": Date().timeIntervalSince(transactStart) * 1000])
    // #endregion

    // Ensure connected
    let isDisconnected = await MainActor.run { client.connectionState == .disconnected }
    if isDisconnected {
      await MainActor.run { client.connect() }
    }
    // #region agent log
    reactorDebugLog("transact: checked connection", data: ["elapsed_ms": Date().timeIntervalSince(transactStart) * 1000, "wasDisconnected": isDisconnected])
    // #endregion

    let initialAttrs = await MainActor.run { client.attributes }
    if !initialAttrs.isEmpty {
      store.updateAttributes(initialAttrs)
    }
    // #region agent log
    reactorDebugLog("transact: got attrs", data: ["elapsed_ms": Date().timeIntervalSince(transactStart) * 1000, "attrCount": initialAttrs.count])
    // #endregion

    // Optimistic Update
    // We apply the changes to the triple store immediately so callers can read their
    // writes locally while the server transaction is in-flight.
    await applyOptimisticUpdate(chunks: chunks)
    // #region agent log
    reactorDebugLog("transact: applied optimistic", data: ["elapsed_ms": Date().timeIntervalSince(transactStart) * 1000])
    // #endregion

    // Persist + enqueue mutations while offline, and flush automatically on reconnect.
    _ = try await client.transactLocalFirst(chunks)
    // #region agent log
    reactorDebugLog("transact END", data: ["elapsed_ms": Date().timeIntervalSince(transactStart) * 1000, "chunkIds": chunkIds])
    // #endregion
  }

  /// Explicitly sign in as a guest.
  /// Useful for testing or anonymous usage.
  public func signInAsGuest(appID: String) async throws {
      let client = await MainActor.run { InstantClientFactory.makeClient(appID: appID, instanceID: self.clientInstanceID) }
      
      // Perform sign in on MainActor
      // Perform sign in (AuthManager is @MainActor, so this hops automatically)
      let authManager = await client.authManager
      _ = try await authManager.signInAsGuest()
      
      // Loop until authenticated (or error)
      var authenticated = false
      let deadline = Date().addingTimeInterval(10)
      while !authenticated && Date() < deadline {
          let isAuthenticated = await MainActor.run { client.connectionState == .authenticated }
          if isAuthenticated {
              authenticated = true
          } else {
             let isError = await MainActor.run { 
                 if case .error = client.connectionState { return true }
                 return false
             }
             if isError {
                  throw InstantError.connectionFailed(NSError(domain: "Reactor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection failed"]))
             }
          }
          if !authenticated { try? await Task.sleep(nanoseconds: 100_000_000) }
      }
      guard authenticated else { throw InstantError.notAuthenticated }
  }

  private func applyOptimisticUpdate(chunks: [TransactionChunk]) async {
    let timestamp = ConflictResolution.optimisticTimestamp()

    // Track affected entities for targeted notifications
    var affectedNamespaces: Set<String> = []
    var upsertedIds: [(namespace: String, id: String)] = []
    var deletedIds: [(namespace: String, id: String)] = []

    for chunk in chunks {
      for op in chunk.ops {
        guard let action = op.first as? String else { continue }

        let namespace = (op.count > 1 ? op[1] as? String : nil) ?? chunk.namespace
        let id = (op.count > 2 ? op[2] as? String : nil) ?? chunk.id
        affectedNamespaces.insert(namespace)

        switch action {
        case "create", "update":
          guard op.count > 3, let payload = op[3] as? [String: Any] else { continue }
          var entity = payload
          entity["id"] = id

          let triples = Normalization.normalize(
            data: entity,
            namespace: namespace,
            attrsStore: store.attrsStore,
            createdAt: timestamp
          )
          store.addTriples(triples)
          upsertedIds.append((namespace: namespace, id: id))

        case "link":
          guard op.count > 3, let payload = op[3] as? [String: Any] else { continue }
          var entity: [String: Any] = ["id": id]
          for (key, value) in payload {
            entity[key] = value
          }

          let triples = Normalization.normalize(
            data: entity,
            namespace: namespace,
            attrsStore: store.attrsStore,
            createdAt: timestamp
          )
          store.addTriples(triples)
          upsertedIds.append((namespace: namespace, id: id))

        case "unlink":
          guard op.count > 3, let payload = op[3] as? [String: Any] else { continue }
          applyOptimisticUnlink(
            namespace: namespace,
            entityId: id,
            payload: payload,
            timestamp: timestamp
          )
          upsertedIds.append((namespace: namespace, id: id))

        case "delete":
          store.deleteEntity(id: id)
          deletedIds.append((namespace: namespace, id: id))

        default:
          continue
        }
      }
    }

    // Notify subscriptions of the specific changes
    // This ensures currentIDs gets updated with the new entity IDs
    for (namespace, id) in upsertedIds {
      await notifyOptimisticUpsert(namespace: namespace, id: id)
    }
    for (namespace, id) in deletedIds {
      await notifyOptimisticDelete(namespace: namespace, id: id)
    }

    // Also notify all subscriptions to ensure cross-namespace consistency
    // (e.g., a link mutation affects both sides of the relationship)
    // See Reactor.js pushOps() line 1367: this.notifyAll()
    await notifyAll()
  }

  private func applyOptimisticUnlink(
    namespace: String,
    entityId: String,
    payload: [String: Any],
    timestamp: Int64
  ) {
    for (label, rawValue) in payload {
      if let attr = store.attrsStore.getAttrByForwardIdent(entityType: namespace, label: label) {
        guard attr.valueType == .ref else { continue }

        for targetId in referencedEntityIDs(from: rawValue) {
          let triple = Triple(entityId: entityId, attributeId: attr.id, value: .ref(targetId), createdAt: timestamp)
          store.retractTriple(triple, isRef: true)
        }
        continue
      }

      if let attr = store.attrsStore.getAttrByReverseIdent(entityType: namespace, label: label) {
        guard attr.valueType == .ref else { continue }

        for sourceId in referencedEntityIDs(from: rawValue) {
          let triple = Triple(entityId: sourceId, attributeId: attr.id, value: .ref(entityId), createdAt: timestamp)
          store.retractTriple(triple, isRef: true)
        }
      }
    }
  }

  private func referencedEntityIDs(from rawValue: Any) -> [String] {
    if let id = rawValue as? String {
      return [id]
    }

    if let dict = rawValue as? [String: Any], let id = dict["id"] as? String {
      return [id]
    }

    if let array = rawValue as? [Any] {
      return array.flatMap { referencedEntityIDs(from: $0) }
    }

    return []
  }
  
  // Helper to pass non-Sendable data to MainActor
  private struct QueryOptions: @unchecked Sendable {
      let orderBy: OrderBy?
      let limit: Int?
      let whereClause: [String: Any]?
      let linkTree: [EntityQueryNode]
      let includedLinks: Set<String>
  }
  
  private func startSubscription<Value: EntityIdentifiable & Codable & Sendable>(
    appID: String,
    namespace: String,
    orderBy: OrderBy?,
    limit: Int?,
    whereClause: [String: Any]?,
    linkTree: [EntityQueryNode],
    includedLinks: Set<String>,
    continuation: AsyncStream<[Value]>.Continuation
  ) async {
    let client = await MainActor.run { InstantClientFactory.makeClient(appID: appID, instanceID: self.clientInstanceID) }

    // Connect if needed
    let isDisconnected = await MainActor.run { client.connectionState == .disconnected }
    if isDisconnected {
      await MainActor.run { client.connect() }
    }

    // NOTE: Pending mutation restoration is done AFTER subscription registration
    // so that the subscription can be notified of restored entities.
    // See the call to restorePendingMutationsIfNeeded below.

    let attrs = await waitForAttributes(
      client: client,
      timeoutSeconds: 5,
      logContext: [
        "appID": appID,
        "namespace": namespace,
        "orderBy": orderBy?.field as Any,
        "limit": limit as Any,
        "whereClause": whereClause as Any,
        "includedLinks": includedLinks.sorted(),
        "linkTreeCount": linkTree.count,
      ]
    )
    if !attrs.isEmpty {
      store.updateAttributes(attrs)
    }
    
    // Manage state with a dedicated actor to handle concurrency between DB callbacks and Store callbacks
    // TypeScript SDK Pattern: Pass appID/clientInstanceID so handleStoreUpdate() can fetch
    // pending mutations at query time (see Reactor.js dataForQuery -> _applyOptimisticUpdates)
    let subscriptionState = SubscriptionState<Value>(
      continuation: continuation,
      store: store,
      namespace: namespace,
      orderByIsDescending: orderBy?.isDescending ?? false,
      includedLinks: includedLinks,
      appID: appID,
      clientInstanceID: self.clientInstanceID
    )

    let handleId = UUID()
    activeSubscriptions[handleId] = SubscriptionHandle(
      namespace: namespace,
      filter: subscriptionFilter(whereClause: whereClause),
      upsert: { id in
        await subscriptionState.handleOptimisticUpsert(id: id)
      },
      delete: { id in
        await subscriptionState.handleOptimisticDelete(id: id)
      }
    )

    // TypeScript SDK Pattern: Pending mutations are now applied at query time in handleStoreUpdate().
    // We still call restorePendingMutationsIfNeeded to populate the TripleStore for linked entity
    // resolution and ensure data is available for store.get() calls.
    await restorePendingMutationsIfNeeded(client: client, appID: appID)

    // Trigger initial yield to show any pending mutation data immediately
    // (TypeScript SDK does this via initial dataForQuery call)
    await subscriptionState.handleStoreUpdate()

    // Subscribe to InstantDB
    // Use QueryOptions to pass non-Sendable data to MainActor

    
    let options = QueryOptions(
        orderBy: orderBy,
        limit: limit,
        whereClause: whereClause,
        linkTree: linkTree,
        includedLinks: includedLinks
    )
    
    let sharedStore = store


    let token = await MainActor.run {
        // Build Query
        var q = client.query(Value.self)
        
        if let orderBy = options.orderBy {
          q = q.order(by: orderBy.field, orderBy.isDescending ? .desc : .asc)
        }
        if let whereClause = options.whereClause {
            q = q.where(whereClause)
        }
        if let limit = options.limit {
            q = q.limit(limit)
        }
        
        // Include links
        if !options.linkTree.isEmpty {
           let includeDict = convertLinkTreeToInstaQL(options.linkTree)
           q = q.including(includeDict)
        } else if !options.includedLinks.isEmpty {
           q = q.including(options.includedLinks)
        }
        
        // #region agent log
        // HYPOTHESIS C: Log the query being sent to InstantDB
        // NOTE: Disabled by default - enable with INSTANT_DEBUG_LOG=1
        #if DEBUG
        if ProcessInfo.processInfo.environment["INSTANT_DEBUG_LOG"] == "1" {
          let whereClauseStr = options.whereClause.map { dict -> String in
            let pairs = dict.map { "\($0.key): \(String(describing: $0.value))" }
            return "[\(pairs.joined(separator: ", "))]"
          } ?? "nil"

          let whereClauseJson: String
          if let wc = options.whereClause,
             let jsonData = try? JSONSerialization.data(withJSONObject: wc, options: [.sortedKeys]),
             let str = String(data: jsonData, encoding: .utf8) {
            whereClauseJson = str
          } else {
            whereClauseJson = "nil or failed to serialize"
          }

          let payload: [String: Any] = [
            "location": "Reactor.swift:startSubscription",
            "message": "HYPOTHESIS_C: Query being sent to InstantDB",
            "data": [
              "namespace": namespace,
              "whereClause": whereClauseStr,
              "whereClauseJson": whereClauseJson,
              "hasDotNotation": (options.whereClause?.keys.contains(where: { $0.contains(".") }) ?? false),
              "includedLinks": Array(options.includedLinks),
              "linkTreeCount": options.linkTree.count
            ],
            "timestamp": Date().timeIntervalSince1970 * 1000,
            "sessionId": "debug-session",
            "hypothesisId": "C"
          ]
          if let jsonData = try? JSONSerialization.data(withJSONObject: payload) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:7243/ingest/b61a72ba-9985-415b-9c60-d4184ed05385")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData
            let task = URLSession.shared.dataTask(with: request) { _, _, _ in }
            task.resume()
          }
        }
        #endif
        // #endregion
        
	        return try? client.subscribe(q) { [weak subscriptionState] result in
              if result.isLoading {
                return
              }

	            if let error = result.error {
                  // #region agent log
                  // HYPOTHESIS C: Log subscription errors
                  // NOTE: Disabled by default - enable with INSTANT_DEBUG_LOG=1
                  #if DEBUG
                  if ProcessInfo.processInfo.environment["INSTANT_DEBUG_LOG"] == "1" {
                    let payload: [String: Any] = [
                      "location": "Reactor.swift:subscribe",
                      "message": "HYPOTHESIS_C: Subscription error",
                      "data": [
                        "namespace": namespace,
                        "error": "\(error)",
                        "whereClause": String(describing: options.whereClause)
                      ],
                      "timestamp": Date().timeIntervalSince1970 * 1000,
                      "sessionId": "debug-session",
                      "hypothesisId": "C"
                    ]
                    if let jsonData = try? JSONSerialization.data(withJSONObject: payload) {
                      var request = URLRequest(url: URL(string: "http://127.0.0.1:7243/ingest/b61a72ba-9985-415b-9c60-d4184ed05385")!)
                      request.httpMethod = "POST"
                      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                      request.httpBody = jsonData
                      let task = URLSession.shared.dataTask(with: request) { _, _, _ in }
                      task.resume()
                    }
                  }
                  #endif
                  // #endregion
	                Task { @MainActor in
	                  InstantLogger.error("Reactor subscription callback error.", error: error)
	                }
	                return
	            }
            
            sharedStore.updateAttributes(client.attributes)

            let data = result.data
            
            // #region agent log
            // HYPOTHESIS C: Log subscription results
            // NOTE: Disabled by default - enable with INSTANT_DEBUG_LOG=1
            #if DEBUG
            if ProcessInfo.processInfo.environment["INSTANT_DEBUG_LOG"] == "1" {
              let dataPayload: [String: Any] = [
                "location": "Reactor.swift:subscribe",
                "message": "HYPOTHESIS_C: Subscription result received",
                "data": [
                  "namespace": namespace,
                  "resultCount": data.count,
                  "resultIds": data.map { $0.id },
                  "whereClause": String(describing: options.whereClause),
                  "hasDotNotation": (options.whereClause?.keys.contains(where: { $0.contains(".") }) ?? false)
                ],
                "timestamp": Date().timeIntervalSince1970 * 1000,
                "sessionId": "debug-session",
                "hypothesisId": "C"
              ]
              if let jsonData = try? JSONSerialization.data(withJSONObject: dataPayload) {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:7243/ingest/b61a72ba-9985-415b-9c60-d4184ed05385")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = jsonData
                let task = URLSession.shared.dataTask(with: request) { _, _, _ in }
                task.resume()
              }
            }
            #endif
            // #endregion
            
            Task {
                // 1. Merge to Store and Update Subscription State
                // `subscriptionState` is an actor, so we can call its methods.
                await subscriptionState?.handleDBUpdate(data: data)
            }
        }
    }
    
    // Keep alive until cancelled
    // Note: When the subscription is cancelled, we need to exit cleanly without
    // throwing CancellationError because XCTest/Swift Testing intercepts thrown errors
    // even if they're caught in a do-catch block.
    //
    // Solution: Use withCheckedContinuation which never throws, and manually resume
    // when cancellation is detected via onCancel handler.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        // Store continuation so onCancel handler can resume it
        let continuationBox = UnsafeMutablePointer<CheckedContinuation<Void, Never>?>.allocate(capacity: 1)
        continuationBox.initialize(to: continuation)

        // Store connection state subscription for cleanup
        let connectionCancellableBox = UnsafeMutablePointer<AnyCancellable?>.allocate(capacity: 1)
        connectionCancellableBox.initialize(to: nil)

        // Set up cancellation handler that resumes the continuation
        Task { [handleId] in
            // Subscribe to connection state changes to handle reconnection
            // TypeScript SDK Pattern: When connection is restored, subscriptions are automatically
            // re-queried by the SDK. We mirror this by triggering handleStoreUpdate() on reconnection.
            // See Reactor.js: _startSocket() -> handleInitOk() -> flushPendingMessages()
            let connectionSubscription = await MainActor.run {
                var previousState: ConnectionState = client.connectionState
                return client.$connectionState
                    .receive(on: DispatchQueue.main)
                    .sink { [weak subscriptionState] newState in
                        let wasDisconnected = (previousState == .disconnected || previousState == .connecting)
                        let isNowAuthenticated = (newState == .authenticated)

                        reactorDebugLog("Connection state changed", data: [
                            "namespace": namespace,
                            "previousState": "\(previousState)",
                            "newState": "\(newState)",
                            "wasDisconnected": wasDisconnected,
                            "isNowAuthenticated": isNowAuthenticated
                        ])

                        // Trigger re-query when reconnecting
                        if wasDisconnected && isNowAuthenticated {
                            reactorDebugLog("Connection restored - triggering handleStoreUpdate", data: [
                                "namespace": namespace
                            ])
                            Task {
                                await subscriptionState?.handleStoreUpdate()
                            }
                        }

                        previousState = newState
                    }
            }
            connectionCancellableBox.pointee = connectionSubscription

            // Wait for cancellation by checking periodically
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms poll
            }

            // When cancelled, resume continuation and cleanup
            connectionCancellableBox.pointee?.cancel()
            connectionCancellableBox.pointee = nil
            connectionCancellableBox.deallocate()

            if let cont = continuationBox.pointee {
                continuationBox.pointee = nil
                cont.resume()
            }
            continuationBox.deallocate()

            await self.removeSubscriptionHandle(id: handleId)
            await subscriptionState.cleanup()
        }
    }
    
    // Ensure token is kept alive if we ever reach here (unlikely fully cancelled)
    if let token = token {
        // We use string interpolation to avoid unused variable warning while keeping it alive
        _ = "Token kept alive: \(token)"
    }
  }
  
  private func removeSubscriptionHandle(id: UUID) {
    activeSubscriptions.removeValue(forKey: id)
  }
}

/// Actor to manage the state of a single subscription.
///
/// ## Query-Level Reactivity (TypeScript SDK Pattern)
/// This actor applies pending mutations at query evaluation time, matching the TypeScript
/// SDK's `dataForQuery()` -> `_applyOptimisticUpdates()` pattern.
///
/// Instead of persisting pending mutations to the store once, we merge them on-the-fly
/// every time `handleStoreUpdate()` is called. This ensures pending mutations are ALWAYS
/// visible, regardless of subscription lifecycle or store state.
///
/// See: instant-client/src/Reactor.js - dataForQuery(), _applyOptimisticUpdates()
private actor SubscriptionState<Value: EntityIdentifiable & Codable & Sendable> {
    private var currentIDs: [String] = [] // Keep order for consistent results
    private let continuation: AsyncStream<[Value]>.Continuation
    private let store: SharedTripleStore
    private let namespace: String
    private let orderByIsDescending: Bool

    /// Links to include when resolving entities from the store.
    /// This controls which linked entities are fetched during entity resolution.
    /// Without this, bidirectional links cause exponential memory growth.
    private let includedLinks: Set<String>

    /// For fetching pending mutations at query time (TypeScript SDK pattern).
    private let appID: String
    private let clientInstanceID: String

    /// IDs that have been introduced by local optimistic writes, but have not yet been
    /// observed in a server query result.
    ///
    /// ## Why This Exists
    /// SharingInstant applies optimistic writes to the local `TripleStore` immediately.
    /// However, InstantDB subscriptions can emit a server refresh *before* the mutation
    /// has round-tripped and appears in the query result. If we overwrite our `currentIDs`
    /// with the server-provided IDs in that window, the UI appears to "revert" or drop
    /// newly created entities, which is the exact "it gets overridden" symptom.
    ///
    /// By tracking optimistic IDs separately, we can keep them in `currentIDs` until the
    /// server eventually includes them (at which point they become confirmed and we can
    /// stop treating them as optimistic).
    private var optimisticIDs: [String] = []

    init(
      continuation: AsyncStream<[Value]>.Continuation,
      store: SharedTripleStore,
      namespace: String,
      orderByIsDescending: Bool,
      includedLinks: Set<String>,
      appID: String,
      clientInstanceID: String
    ) {
        self.continuation = continuation
        self.store = store
        self.namespace = namespace
        self.orderByIsDescending = orderByIsDescending
        self.includedLinks = includedLinks
        self.appID = appID
        self.clientInstanceID = clientInstanceID
    }
    
    func handleDBUpdate(data: [Value]) async {
        // 1. Merge data into store (Normalize Tree -> Triples)
        // Use manual dictionary merge to convert to Dict
        let dicts = data.compactMap { try? $0.asDictionary() }

        var allTriples: [Triple] = []
        for dict in dicts {
            // Normalize: dict -> triples
            let triples = Normalization.normalize(data: dict, namespace: namespace, attrsStore: store.attrsStore)
            allTriples.append(contentsOf: triples)
        }
        store.addTriples(allTriples)

        let serverIDs = data.map(\.id)
        let serverIDLowercasedSet = Set(serverIDs.map { $0.lowercased() })

        // Once the server has included an ID, it is no longer "optimistic".
        optimisticIDs.removeAll { serverIDLowercasedSet.contains($0.lowercased()) }

        let pendingOptimisticIDs = optimisticIDs.filter {
          !serverIDLowercasedSet.contains($0.lowercased())
        }
        let mergedIDs: [String]
        if orderByIsDescending {
          mergedIDs = pendingOptimisticIDs + serverIDs
        } else {
          mergedIDs = serverIDs + pendingOptimisticIDs
        }

        currentIDs = mergedIDs

        // Yield from the normalized store rather than the raw DB response.
        //
        // ## Why This Exists
        // - Ensures linked entities hydrate consistently from the same source of truth.
        // - Prevents server refreshes from temporarily "overriding" optimistic additions
        //   that have not yet round-tripped into the server query result.
        await handleStoreUpdate()
    }
    
    func handleStoreUpdate() async {
        reactorDebugLog("SubscriptionState.handleStoreUpdate", data: [
          "namespace": namespace,
          "currentIDsCount": currentIDs.count,
          "currentIDs": currentIDs,
          "optimisticIDsCount": optimisticIDs.count,
          "optimisticIDs": optimisticIDs
        ])

        // TypeScript SDK Pattern: Apply pending mutations at query time
        // See Reactor.js dataForQuery() -> _applyOptimisticUpdates()
        //
        // 1. Get pending mutations from SQLite
        let client = await MainActor.run {
            InstantClientFactory.makeClient(appID: appID, instanceID: clientInstanceID)
        }
        let pendingMutations = await client.getUnconfirmedPendingMutations()

        // 2. Extract entity data from pending mutations for our namespace
        var pendingEntityData: [String: [String: Any]] = [:]
        var pendingEntityOrder: [String] = [] // Maintain insertion order

        for mutation in pendingMutations {
            for step in mutation.txSteps {
                guard step.count >= 4,
                      let action = step[0].value as? String,
                      action == "add-triple",
                      let entityId = step[1].value as? String,
                      let attrId = step[2].value as? String else {
                    continue
                }

                // Resolve attribute ID to namespace and field name
                // attrId can be either:
                // 1. A UUID that needs lookup in attrsStore
                // 2. A "namespace/field" format string (legacy/fallback)
                let attrNamespace: String
                let fieldName: String

                if let attr = store.attrsStore.getAttr(attrId),
                   attr.forwardIdentity.count >= 3 {
                    // forwardIdentity = [attrId, namespace, label]
                    attrNamespace = attr.forwardIdentity[1]
                    fieldName = attr.forwardIdentity[2]
                } else {
                    // Fallback: try parsing as "namespace/field"
                    let parts = attrId.components(separatedBy: "/")
                    guard parts.count >= 2 else { continue }
                    attrNamespace = parts[0]
                    fieldName = parts[1]
                }

                // Check if this triple belongs to our namespace
                guard attrNamespace == namespace else { continue }

                let rawValue = step[3].value

                // Initialize entity data if needed
                if pendingEntityData[entityId] == nil {
                    pendingEntityData[entityId] = ["id": entityId]
                    pendingEntityOrder.append(entityId)
                }

                // Store the field value
                pendingEntityData[entityId]?[fieldName] = rawValue
            }
        }

        reactorDebugLog("SubscriptionState.handleStoreUpdate: pending mutations extracted", data: [
          "namespace": namespace,
          "pendingEntityCount": pendingEntityData.count,
          "pendingEntityIds": pendingEntityOrder
        ])

        // 3. Merge currentIDs with pending entity IDs (maintaining order)
        // Pending entities that aren't in currentIDs are new optimistic creates
        var allIDs = currentIDs
        for entityId in pendingEntityOrder {
            if !allIDs.contains(entityId) {
                if orderByIsDescending {
                    allIDs.insert(entityId, at: 0)
                } else {
                    allIDs.append(entityId)
                }
            }
        }

        // 4. Build result by merging store data with pending mutations
        var values: [Value] = []

        for id in allIDs {
            var entityDict: [String: Any]

            // Get base data from store (if exists)
            // CRITICAL: Pass includedLinks to only resolve explicitly requested links.
            if let val: Value = store.get(id: id, includedLinks: includedLinks) {
                entityDict = (try? val.asDictionary()) ?? ["id": id]
            } else {
                entityDict = ["id": id]
            }

            // Merge pending mutation data (overwrites store data for same fields)
            // This is the key TypeScript SDK pattern - pending mutations take precedence
            if let pendingData = pendingEntityData[id] {
                for (key, value) in pendingData {
                    entityDict[key] = value
                }
            }

            // Decode back to Value type
            if let data = try? JSONSerialization.data(withJSONObject: entityDict),
               let val = try? JSONDecoder().decode(Value.self, from: data) {
                values.append(val)
            }
        }

        reactorDebugLog("SubscriptionState.handleStoreUpdate: yielding", data: [
          "namespace": namespace,
          "valueCount": values.count,
          "valueIds": values.map { $0.id },
          "pendingMutationCount": pendingMutations.count
        ])

        continuation.yield(values)
    }

    func handleOptimisticUpsert(id: String) async {
        reactorDebugLog("SubscriptionState.handleOptimisticUpsert", data: [
          "namespace": namespace,
          "id": id,
          "currentIDsCount": currentIDs.count,
          "optimisticIDsCount": optimisticIDs.count
        ])

        // Handle notifyAll() sentinel - just trigger a store update without modifying tracking
        if id == "__notifyAll__" {
          await handleStoreUpdate()
          return
        }

        if !optimisticIDs.contains(id) {
          if orderByIsDescending {
            optimisticIDs.insert(id, at: 0)
          } else {
            optimisticIDs.append(id)
          }
        }

        if !currentIDs.contains(id) {
          if orderByIsDescending {
            currentIDs.insert(id, at: 0)
          } else {
            currentIDs.append(id)
          }
        }

        reactorDebugLog("SubscriptionState.handleOptimisticUpsert: after update", data: [
          "namespace": namespace,
          "id": id,
          "currentIDs": currentIDs,
          "optimisticIDs": optimisticIDs
        ])

        await handleStoreUpdate()
    }
    
    func handleOptimisticDelete(id: String) async {
        currentIDs.removeAll { $0 == id }
        optimisticIDs.removeAll { $0 == id }
        await handleStoreUpdate()
    }

    func cleanup() async {
        // No observers to clean up - query-level reactivity doesn't use per-entity observers
    }
}

extension Encodable {
    func asDictionary() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        guard let dictionary = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any] else {
            throw NSError()
        }
        return dictionary
    }
}
