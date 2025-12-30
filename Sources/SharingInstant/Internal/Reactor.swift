import Foundation
import InstantDB
import Dependencies
import Sharing

// #region agent log
/// Debug endpoint for Cursor debug mode logging
private let debugEndpointURL = URL(string: "http://192.168.68.108:17244/ingest/3fe5bb38-db92-49af-9cd2-9ee98b17811b")

/// Send debug logs to Cursor debug mode
private func debugLogReactor(_ location: String, _ message: String, _ data: [String: Any], _ hypothesisId: String) {
    guard let url = debugEndpointURL else { return }
    var payload: [String: Any] = [
        "location": location,
        "message": message,
        "data": data,
        "timestamp": Date().timeIntervalSince1970 * 1000,
        "sessionId": "sharing-instant-reactor",
        "hypothesisId": hypothesisId
    ]
    guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = jsonData
    URLSession.shared.dataTask(with: request).resume()
}
// #endregion

/// Adapted from: instant-client/src/client_db.ts (Reactor logic)
///
/// The central coordinator for InstantDB data.
///
/// The Reactor manages:
/// 1. Connections to InstantDB (via InstantClient).
/// 2. Subscriptions to queries.
/// 3. The Shared TripleStore.


public actor Reactor {
  // public static let shared = Reactor() // Removed for DI

  
  private let store: SharedTripleStore
  private let clientInstanceID: String
  private var activeSubscriptions: [UUID: SubscriptionHandle] = [:]
  
  public init(store: SharedTripleStore, clientInstanceID: String = "default") {
    self.store = store
    self.clientInstanceID = clientInstanceID
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
  
  private func notifyOptimisticUpsert(namespace: String, id: String) async {
    // #region agent log
    debugLogReactor("Reactor:notifyOptimisticUpsert:START", "Broadcasting optimistic upsert to subscriptions", [
      "namespace": namespace,
      "entityId": id,
      "activeSubscriptionCount": activeSubscriptions.count
    ], "F")
    // #endregion
    
    for (handleId, handle) in activeSubscriptions where handle.namespace == namespace {
      // #region agent log
      debugLogReactor("Reactor:notifyOptimisticUpsert:CHECKING", "Checking subscription filter", [
        "handleId": handleId.uuidString,
        "namespace": namespace,
        "entityId": id,
        "filter": String(describing: handle.filter)
      ], "F")
      // #endregion
      
      switch handle.filter {
      case .matchAll:
        await handle.upsert(id)
      case .idEquals(let expectedId):
        guard expectedId == id else { continue }
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
  public func transact(
    appID: String,
    chunks: [TransactionChunk]
  ) async throws {
    let client = await MainActor.run { InstantClientFactory.makeClient(appID: appID, instanceID: self.clientInstanceID) }

    // Ensure connected
    let isDisconnected = await MainActor.run { client.connectionState == .disconnected }
    if isDisconnected {
      await MainActor.run { client.connect() }
    }

    let initialAttrs = await MainActor.run { client.attributes }
    if !initialAttrs.isEmpty {
      store.updateAttributes(initialAttrs)
    }

    // Optimistic Update
    // We apply the changes to the triple store immediately so callers can read their
    // writes locally while the server transaction is in-flight.
    await applyOptimisticUpdate(chunks: chunks)

    // Persist + enqueue mutations while offline, and flush automatically on reconnect.
    _ = try await client.transactLocalFirst(chunks)
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

    for chunk in chunks {
      for op in chunk.ops {
        guard let action = op.first as? String else { continue }

        let namespace = (op.count > 1 ? op[1] as? String : nil) ?? chunk.namespace
        let id = (op.count > 2 ? op[2] as? String : nil) ?? chunk.id

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
          await notifyOptimisticUpsert(namespace: namespace, id: id)

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
          await notifyOptimisticUpsert(namespace: namespace, id: id)

        case "unlink":
          guard op.count > 3, let payload = op[3] as? [String: Any] else { continue }
          applyOptimisticUnlink(
            namespace: namespace,
            entityId: id,
            payload: payload,
            timestamp: timestamp
          )
          await notifyOptimisticUpsert(namespace: namespace, id: id)

        case "delete":
          store.deleteEntity(id: id)
          await notifyOptimisticDelete(namespace: namespace, id: id)

        default:
          continue
        }
      }
    }
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
    let subscriptionState = SubscriptionState<Value>(
      continuation: continuation,
      store: store,
      namespace: namespace,
      orderByIsDescending: orderBy?.isDescending ?? false
    )

    let handleId = UUID()
    activeSubscriptions[handleId] = SubscriptionHandle(
      namespace: namespace,
      filter: subscriptionFilter(whereClause: whereClause),
      upsert: { id in
        // #region agent log
        debugLogReactor("Reactor:SubscriptionHandle:UPSERT", "Optimistic upsert notification received", [
          "handleId": handleId.uuidString,
          "namespace": namespace,
          "entityId": id,
          "includedLinksCount": includedLinks.count,
          "linkTreeCount": linkTree.count
        ], "F")
        // #endregion
        await subscriptionState.handleOptimisticUpsert(id: id)
      },
      delete: { id in
        await subscriptionState.handleOptimisticDelete(id: id)
      }
    )
    
    // Setup Store Observer
    // We observe the TripleStore for any changes to the entities we care about.
    // When the store changes, we re-evaluate our query against the store to yield new data.
    // The TripleStore acts as the "normalized cache" or "source of truth".
    
    // Note: We don't know WHICH IDs to observe initially until we get data from DB.
    // The SubscriptionState will handle adding observers as data comes in.
    
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
        
	        return try? client.subscribe(q) { [weak subscriptionState] result in
              if result.isLoading {
                return
              }

	            if let error = result.error {
	                Task { @MainActor in
	                  InstantLogger.error("Reactor subscription callback error.", error: error)
	                }
	                return
	            }
            
            sharedStore.updateAttributes(client.attributes)

            let data = result.data
            Task {
                // 1. Merge to Store and Update Subscription State
                // `subscriptionState` is an actor, so we can call its methods.
                await subscriptionState?.handleDBUpdate(data: data)
            }
        }
    }
    
    // Keep alive until cancelled
    await withTaskCancellationHandler {
        // Wait indefinitely for cancellation
        try? await Task.sleep(nanoseconds: .max)
    } onCancel: {
        Task { [handleId] in
          await self.removeSubscriptionHandle(id: handleId)
        }
        Task {
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

/// Actor to manage the state of a single subscription
private actor SubscriptionState<Value: EntityIdentifiable & Codable & Sendable> {
    private var currentIDs: [String] = [] // Keep order for consistent results
    private var observerTokens: [String: UUID] = [:]
    private let continuation: AsyncStream<[Value]>.Continuation
    private let store: SharedTripleStore
    private let namespace: String
    private let orderByIsDescending: Bool

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
      orderByIsDescending: Bool
    ) {
        self.continuation = continuation
        self.store = store
        self.namespace = namespace
        self.orderByIsDescending = orderByIsDescending
    }
    
    func handleDBUpdate(data: [Value]) async {
        let previousIDs = currentIDs
        
        // #region agent log
        debugLogReactor("SubscriptionState:handleDBUpdate:START", "Received DB update", [
          "namespace": namespace,
          "previousIDsCount": previousIDs.count,
          "newDataCount": data.count,
          "optimisticIDsCount": optimisticIDs.count,
          "newDataIds": data.map { $0.id }
        ], "G")
        // #endregion

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

        let mergedIDSet = Set(mergedIDs)

        // Remove stale observers.
        //
        // IMPORTANT:
        // We remove observers using the *previous* ID list, so that we do not
        // accidentally drop optimistic IDs that are not (yet) present in `serverIDs`.
        for id in previousIDs {
            if !mergedIDSet.contains(id), let token = observerTokens[id] {
                store.removeObserver(id: id, token: token)
                observerTokens.removeValue(forKey: id)
            }
        }

        // Add new observers.
        let previousIDSet = Set(previousIDs)
        for id in mergedIDs where !previousIDSet.contains(id) {
          let token = store.addObserver(id: id) { [weak self] in
              guard let self = self else { return }
              Task {
                  await self.handleStoreUpdate()
              }
          }
          observerTokens[id] = token
        }

        currentIDs = mergedIDs
        
        // #region agent log
        debugLogReactor("SubscriptionState:handleDBUpdate:MERGED", "Merged IDs after DB update", [
          "namespace": namespace,
          "finalCurrentIDsCount": currentIDs.count,
          "finalCurrentIDs": currentIDs,
          "pendingOptimisticIDs": optimisticIDs,
          "serverIDs": serverIDs
        ], "G")
        // #endregion

        // Yield from the normalized store rather than the raw DB response.
        //
        // ## Why This Exists
        // - Ensures linked entities hydrate consistently from the same source of truth.
        // - Prevents server refreshes from temporarily "overriding" optimistic additions
        //   that have not yet round-tripped into the server query result.
        await handleStoreUpdate()
    }
    
    func handleStoreUpdate() async {
        // Re-construct result from store
        var values: [Value] = []
        
        // Iterate currentIDs to maintain order
        for id in currentIDs {
            if let val: Value = store.get(id: id) {
                values.append(val)
            }
        }
        
        continuation.yield(values)
    }
    
    func handleOptimisticUpsert(id: String) async {
        // #region agent log
        debugLogReactor("SubscriptionState:handleOptimisticUpsert:START", "Processing optimistic upsert", [
          "namespace": namespace,
          "entityId": id,
          "alreadyInOptimisticIDs": optimisticIDs.contains(id),
          "alreadyInCurrentIDs": currentIDs.contains(id),
          "currentIDsCount": currentIDs.count
        ], "F")
        // #endregion
        
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
        
        if observerTokens[id] == nil {
            let token = store.addObserver(id: id) { [weak self] in
                guard let self else { return }
                Task {
                    await self.handleStoreUpdate()
                }
            }
            observerTokens[id] = token
        }
        
        await handleStoreUpdate()
    }
    
    func handleOptimisticDelete(id: String) async {
        if let token = observerTokens[id] {
            store.removeObserver(id: id, token: token)
            observerTokens.removeValue(forKey: id)
        }
        
        currentIDs.removeAll { $0 == id }
        await handleStoreUpdate()
    }
    
    func cleanup() async {
        for (id, token) in observerTokens {
            store.removeObserver(id: id, token: token)
        }
        observerTokens.removeAll()
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
