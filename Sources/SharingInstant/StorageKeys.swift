import Combine
import Dependencies
import Foundation
import IdentifiedCollections
import InstantDB
import Sharing

// MARK: - Public Key Helpers

extension SharedReaderKey where Self == StorageItemKey.Default {
  /// Returns a reactive snapshot of a single storage file.
  ///
  /// ## Why This Exists
  /// Storage uploads/deletes are asynchronous, but SwiftUI wants a simple, stable value to
  /// render. This key merges:
  /// - local mutation state (optimistic uploads, failures, retries), and
  /// - server `$files` metadata (most importantly: `url` for rendering),
  /// into a single ``StorageItem``.
  public static func storageItem(
    _ ref: StorageRef
  ) -> Self {
    Self[
      StorageItemKey(ref: ref, appID: nil),
      default: StorageItem(
        ref: ref,
        status: .idle,
        fileID: nil,
        url: nil,
        localPreview: nil
      )
    ]
  }
}

extension SharedReaderKey where Self == StorageFeedKey.Default {
  /// Returns a reactive feed of files from `$files`, merged with any local optimistic uploads.
  ///
  /// - Parameter scope: Controls which files are included in the feed.
  public static func storageFeed(
    scope: StorageFeedScope = .user
  ) -> Self {
    Self[
      StorageFeedKey(scope: scope, appID: nil),
      default: []
    ]
  }
}

// MARK: - StorageItemKey

public struct StorageItemKey: SharedReaderKey {
  public typealias Value = StorageItem

  let appID: String
  let ref: StorageRef

  public init(
    ref: StorageRef,
    appID: String? = nil
  ) {
    @Dependency(\.instantAppID) var defaultAppID
    self.appID = appID ?? defaultAppID
    self.ref = ref
  }

  public var id: String {
    "storage-item-\(appID)-\(ref.path)"
  }

  public func load(
    context: LoadContext<Value>,
    continuation: LoadContinuation<Value>
  ) {
    continuation.resume(returning: snapshot(remote: nil))
  }

  public func subscribe(
    context: LoadContext<Value>,
    subscriber: SharedSubscriber<Value>
  ) -> SharedSubscription {
    subscriber.yield(snapshot(remote: nil))

    @Dependency(\.context) var dependencyContext

    let cache = StorageItemRemoteCache()

    let remoteTask = Task { @MainActor in
      guard dependencyContext != .test else { return }

      @Dependency(\.instantReactor) var reactor

      let config = SharingInstantQuery.Configuration<StorageFileRecord>(
        namespace: StorageFileRecord.namespace,
        limit: 1,
        whereClause: ["path": ref.path]
      )

      let stream = await reactor.subscribe(appID: appID, configuration: config)
      for await files in stream {
        let file = files.first(where: { $0.path == self.ref.path })
        await cache.setRemote(file)
        subscriber.yield(snapshot(remote: file))
      }
    }

    let localTask = Task { @MainActor in
      let notifications = NotificationCenter.default.notifications(named: StorageNotifications.stateDidChange)
      for await notification in notifications {
        guard let userInfo = notification.userInfo else { continue }
        guard let changedAppID = userInfo[StorageNotifications.appIDKey] as? String else { continue }
        guard changedAppID == self.appID else { continue }

        if let changedPath = userInfo[StorageNotifications.pathKey] as? String {
          guard changedPath == self.ref.path else { continue }
        }

        subscriber.yield(snapshot(remote: await cache.remote()))
      }
    }

    return SharedSubscription {
      remoteTask.cancel()
      localTask.cancel()
    }
  }

  private func snapshot(remote: StorageFileRecord?) -> StorageItem {
    let state = StorageSharedStore.state(appID: appID)
    let entry = state.withLock { $0.entries[ref.path] }

    let status: StorageStatus
    if let entry {
      status = entry.status
    } else if remote != nil {
      status = .uploaded
    } else {
      status = .idle
    }

    let fileID = entry?.remoteFileID ?? remote?.id
    let url = remote?.url.flatMap(URL.init(string:))

    return StorageItem(
      ref: entry?.ref ?? ref,
      status: status,
      fileID: fileID,
      url: url,
      localPreview: entry?.localPreview
    )
  }
}

// MARK: - StorageFeedKey

public struct StorageFeedKey: SharedReaderKey {
  public typealias Value = IdentifiedArrayOf<StorageItem>

  let appID: String
  let scope: StorageFeedScope

  public init(
    scope: StorageFeedScope = .user,
    appID: String? = nil
  ) {
    @Dependency(\.instantAppID) var defaultAppID
    self.appID = appID ?? defaultAppID
    self.scope = scope
  }

  public var id: String {
    "storage-feed-\(appID)-\(String(describing: scope))"
  }

  public func load(
    context: LoadContext<Value>,
    continuation: LoadContinuation<Value>
  ) {
    continuation.resume(returning: merged(remote: []))
  }

  public func subscribe(
    context: LoadContext<Value>,
    subscriber: SharedSubscriber<Value>
  ) -> SharedSubscription {
    subscriber.yield(merged(remote: []))

    @Dependency(\.context) var dependencyContext

    let cache = StorageFeedRemoteCache()

    let appID = self.appID
    let scope = self.scope

    let remoteTask = Task { @MainActor in
      guard dependencyContext != .test else { return }

      let client = InstantClientFactory.makeClient(appID: appID)
      await cache.setUserID(client.authManager.state.user?.id)
      await cache.setRemote([])

      var subscriptionTask: Task<Void, Never>?
      defer { subscriptionTask?.cancel() }

      func restartSubscription(whereClause: [String: Any]?) {
        subscriptionTask?.cancel()

        let config = SharingInstantQuery.Configuration<StorageFileRecord>(
          namespace: StorageFileRecord.namespace,
          orderBy: .desc("serverCreatedAt"),
          whereClause: whereClause
        )

        subscriptionTask = Task { @MainActor in
          @Dependency(\.instantReactor) var reactor

          let stream = await reactor.subscribe(appID: appID, configuration: config)
          for await files in stream {
            await cache.setRemote(files)
            let snapshot = await cache.snapshot()
            subscriber.yield(merged(remote: snapshot.remote, userID: snapshot.userID))
          }
        }
      }

      func refreshSubscription() async {
        let snapshot = await cache.snapshot()
        let whereClause = makeWhereClause(scope: scope, userID: snapshot.userID)

        if shouldSubscribeToRemote(scope: scope, userID: snapshot.userID) {
          restartSubscription(whereClause: whereClause)
        } else {
          subscriptionTask?.cancel()
          subscriptionTask = nil
        }
      }

      await refreshSubscription()

      if case .user = scope {
        let authStream = client.authManager.$state.values
        for await state in authStream {
          let newUserID = state.user?.id
          let previousUserID = await cache.userID()
          guard newUserID != previousUserID else { continue }

          await cache.setUserID(newUserID)
          await cache.setRemote([])

          let snapshot = await cache.snapshot()
          subscriber.yield(merged(remote: snapshot.remote, userID: snapshot.userID))
          await refreshSubscription()
        }
      } else {
        try? await Task.sleep(nanoseconds: .max)
      }
    }

    let localTask = Task { @MainActor in
      let notifications = NotificationCenter.default.notifications(named: StorageNotifications.stateDidChange)
      for await notification in notifications {
        guard let userInfo = notification.userInfo else { continue }
        guard let changedAppID = userInfo[StorageNotifications.appIDKey] as? String else { continue }
        guard changedAppID == appID else { continue }

        let snapshot = await cache.snapshot()
        subscriber.yield(merged(remote: snapshot.remote, userID: snapshot.userID))
      }
    }

    return SharedSubscription {
      remoteTask.cancel()
      localTask.cancel()
    }
  }

  private func merged(
    remote: [StorageFileRecord],
    userID: String? = nil
  ) -> IdentifiedArrayOf<StorageItem> {
    let state = StorageSharedStore.state(appID: appID)
    let snapshot = state.withLock { $0.entries }

    let remoteByPath = Dictionary(uniqueKeysWithValues: remote.map { ($0.path, $0) })
    let scopePrefix = prefixForScope(scope: scope, userID: userID)

    func isInScope(path: String) -> Bool {
      guard let scopePrefix else { return true }
      return path.hasPrefix(scopePrefix)
    }

    var items: [StorageItem] = []

    for record in remote where isInScope(path: record.path) {
      let local = snapshot[record.path]
      let ref = local?.ref ?? StorageRef(
        path: record.path,
        kind: StorageKind.infer(path: record.path, contentType: record.contentType),
        displayName: URL(fileURLWithPath: record.path).lastPathComponent
      )

      let status = local?.status ?? .uploaded
      let fileID = local?.remoteFileID ?? record.id

      items.append(
        StorageItem(
          ref: ref,
          status: status,
          fileID: fileID,
          url: record.url.flatMap(URL.init(string:)),
          localPreview: local?.localPreview
        )
      )
    }

    let localOnly = snapshot
      .values
      .filter { entry in
        guard isInScope(path: entry.ref.path) else { return false }
        guard remoteByPath[entry.ref.path] == nil else { return false }
        guard entry.status != .deleted else { return false }
        return true
      }
      .sorted { lhs, rhs in
        lhs.createdAt > rhs.createdAt
      }

    let localItems = localOnly.map { entry in
      StorageItem(
        ref: entry.ref,
        status: entry.status,
        fileID: entry.remoteFileID,
        url: nil,
        localPreview: entry.localPreview
      )
    }

    items = localItems + items

    return IdentifiedArrayOf(uniqueElements: items)
  }

  private func shouldSubscribeToRemote(
    scope: StorageFeedScope,
    userID: String?
  ) -> Bool {
    switch scope {
    case .all, .prefix:
      return true
    case .user:
      return userID != nil
    }
  }

  private func makeWhereClause(
    scope: StorageFeedScope,
    userID: String?
  ) -> [String: Any]? {
    switch scope {
    case .all:
      return nil
    case .prefix(let prefix):
      let trimmed = prefix
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

      guard !trimmed.isEmpty else { return nil }
      return ["path": ["$ilike": "\(trimmed)/%"]]
    case .user:
      guard let userID else { return nil }
      return ["path": ["$ilike": "\(userID)/%"]]
    }
  }

  private func prefixForScope(
    scope: StorageFeedScope,
    userID: String?
  ) -> String? {
    switch scope {
    case .all:
      return nil
    case .prefix(let prefix):
      let trimmed = prefix
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      return trimmed.isEmpty ? nil : "\(trimmed)/"
    case .user:
      return userID.map { "\($0)/" }
    }
  }
}

// MARK: - Subscription Caches

private actor StorageItemRemoteCache {
  private var value: StorageFileRecord?

  func setRemote(_ record: StorageFileRecord?) {
    value = record
  }

  func remote() -> StorageFileRecord? {
    value
  }
}

private actor StorageFeedRemoteCache {
  private var remoteValue: [StorageFileRecord] = []
  private var userIDValue: String?

  func setRemote(_ records: [StorageFileRecord]) {
    remoteValue = records
  }

  func setUserID(_ userID: String?) {
    userIDValue = userID
  }

  func userID() -> String? {
    userIDValue
  }

  func snapshot() -> (remote: [StorageFileRecord], userID: String?) {
    (remoteValue, userIDValue)
  }
}
