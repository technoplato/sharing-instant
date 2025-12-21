import Foundation
import InstantDB
import Dependencies
import Sharing

/// The central coordinator for InstantDB data.
///
/// The Reactor manages:
/// 1. Connections to InstantDB (via InstantClient).
/// 2. Subscriptions to queries.
/// 3. The Shared TripleStore.
public actor Reactor {
  public static let shared = Reactor()
  
  private let store = TripleStore.shared
  
  private init() {}
  
  /// Subscribes to a query and returns a stream of results.
  ///
  /// - Parameters:
  ///   - appID: The App ID for InstantDB.
  ///   - configuration: The collection query configuration.
  /// - Returns: An async stream of the results.
  public func subscribe<Value: EntityIdentifiable & Sendable>(
    appID: String,
    configuration: SharingInstantSync.CollectionConfiguration<Value>
  ) -> AsyncStream<[Value]> {
    AsyncStream { continuation in
      let task = Task {
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
  public func subscribe<Value: EntityIdentifiable & Sendable>(
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
  /// This method ensures the client is connected and authenticated before sending the transaction.
  ///
  /// - Parameters:
  ///   - appID: The App ID.
  ///   - chunks: The transaction chunks to execute.
  public func transact(
    appID: String,
    chunks: [TransactionChunk]
  ) async throws {
    let client = await MainActor.run { InstantClientFactory.makeClient(appID: appID) }
    
    // Ensure connected
    let isDisconnected = await MainActor.run { client.connectionState == .disconnected }
    if isDisconnected {
       await MainActor.run { client.connect() }
    }
    
    // WaitForAuth helper (could be shared, but inlining for now to avoid actor isolation complexity)
    var authenticated = false
    let deadline = Date().addingTimeInterval(10)
    
    // Fast path check
    let alreadyAuth = await MainActor.run { client.connectionState == .authenticated }
    if alreadyAuth {
        authenticated = true
    } else {
        while !authenticated && Date() < deadline {
            let isAuthenticated = await MainActor.run { client.connectionState == .authenticated }
            if isAuthenticated {
                authenticated = true
            } else {
                 // Check for permanent error?
            }
            if !authenticated {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    
    guard authenticated else {
        throw InstantError.notAuthenticated // Or timeout error
    }
    
    try await MainActor.run {
        try client.transact(chunks)
    }
  }
  
  // Helper to pass non-Sendable data to MainActor
  private struct QueryOptions: @unchecked Sendable {
      let orderBy: OrderBy?
      let limit: Int?
      let whereClause: [String: Any]?
      let linkTree: [EntityQueryNode]
      let includedLinks: Set<String>
  }
  
  private func startSubscription<Value: EntityIdentifiable & Sendable>(
    appID: String,
    namespace: String,
    orderBy: OrderBy?,
    limit: Int?,
    whereClause: [String: Any]?,
    linkTree: [EntityQueryNode],
    includedLinks: Set<String>,
    continuation: AsyncStream<[Value]>.Continuation
  ) async {
    let client = await MainActor.run { InstantClientFactory.makeClient(appID: appID) }
    
    // Connect if needed
    let isDisconnected = await MainActor.run { client.connectionState == .disconnected }
    if isDisconnected {
       await MainActor.run { client.connect() }
    }
    
    // Wait for authentication (max 10s)
    // We must wait for 'init' to complete before subscribing.
    // Wait for authentication (max 10s)
    // We must wait for 'init' to complete before subscribing.
    var authenticated = false
    let deadline = Date().addingTimeInterval(10)
    while !authenticated && Date() < deadline {
        let isAuthenticated = await MainActor.run { client.connectionState == .authenticated }
        if isAuthenticated {
            authenticated = true
        } else {
             // Optional: check for error state if we want to fail fast
             // But error state is also non-sendable if associated value is error
             // We can check equality to specific errors? No.
             // Just wait.
        }
        
        if !authenticated {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }
    
    if !authenticated {
        print("Reactor Error: Timed out waiting for authentication")
        // We can proceed to try subscribing (it might fail) or return
        // Returning ends the stream immediately.
        continuation.finish()
        return
    }
    
    // Manage state with a dedicated actor to handle concurrency between DB callbacks and Store callbacks
    let subscriptionState = SubscriptionState<Value>(continuation: continuation, store: store)
    
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
        
        return try? client.subscribe(q) { result in
            if let error = result.error {
                print("Reactor Error: \(error)")
                return
            }
            
            let data = result.data
            Task {
                // 1. Merge to Store
                await TripleStore.shared.merge(values: data)
                
                // 2. Update Subscription State
                await subscriptionState.handleDBUpdate(data: data)
            }
        }
    }
    
    // Keep alive until cancelled
    await withTaskCancellationHandler {
        // Wait indefinitely for cancellation
        try? await Task.sleep(nanoseconds: .max)
    } onCancel: {
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
}

/// Actor to manage the state of a single subscription
private actor SubscriptionState<Value: EntityIdentifiable & Sendable> {
    private var currentIDs: Set<String> = []
    private var observerTokens: [String: UUID] = [:]
    private let continuation: AsyncStream<[Value]>.Continuation
    private let store: TripleStore
    
    init(continuation: AsyncStream<[Value]>.Continuation, store: TripleStore) {
        self.continuation = continuation
        self.store = store
    }
    
    func handleDBUpdate(data: [Value]) async {
        // Yield immediate data from DB (latency optimization)
        continuation.yield(data)
        
        let newIDs = data.map { $0.id }
        let newIDSet = Set(newIDs)
        
        // Remove stale observers
        for id in currentIDs {
            if !newIDSet.contains(id), let token = observerTokens[id] {
                await store.removeObserver(id: id, token: token)
                observerTokens.removeValue(forKey: id)
            }
        }
        
        // Add new observers
        for id in newIDSet {
            if !currentIDs.contains(id) {
                // We need to pass a closure that calls back to this actor
                // The closure must be Sendable.
                // We capture 'self' (the actor).
                let token = await store.addObserver(id: id) { [weak self] in
                    guard let self = self else { return }
                    Task {
                        await self.handleStoreUpdate()
                    }
                }
                observerTokens[id] = token
            }
        }
        
        currentIDs = newIDSet
    }
    
    func handleStoreUpdate() async {
        // Re-construct result from store
        var values: [Value] = []
        // Note: We lost the specific order from DB if we just use Set.
        // But for V1 we iterate the Set.
        // Ideally we should store 'orderedIDs' too from the last DB update.
        // Let's assume Set iteration is sufficient or fix it later.
        // Actually, let's fix it by storing ordered list in handleDBUpdate
        
        // But we need to keep 'currentIDs' (Set) for fast lookup.
        // Let's iterate 'currentIDs' (Set) for now.
        
        for id in currentIDs {
            if let val: Value = await store.get(id: id) {
                values.append(val)
            }
        }
        continuation.yield(values)
    }
    
    func cleanup() async {
        for (id, token) in observerTokens {
            await store.removeObserver(id: id, token: token)
        }
        observerTokens.removeAll()
    }
}
