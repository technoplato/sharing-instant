/// SharingInstant - A Swift Sharing integration for InstantDB
///
/// This library provides seamless integration between InstantDB's real-time database
/// and Point-Free's Sharing library, enabling local-first, optimistic updates with
/// automatic synchronization.
///
/// ## Overview
///
/// SharingInstant allows you to use familiar SwiftUI patterns with InstantDB:
///
/// ```swift
/// // Type-safe with generated schema
/// @Shared(Schema.todos)
/// private var todos: IdentifiedArrayOf<Todo> = []
///
/// // With ordering
/// @Shared(Schema.todos.orderBy(\.createdAt, .desc))
/// private var todos: IdentifiedArrayOf<Todo> = []
///
/// // Or with manual configuration
/// @Shared(
///   .instantSync(
///     configuration: .init(
///       namespace: "todos",
///       orderBy: .desc("createdAt")
///     )
///   )
/// )
/// private var todos: IdentifiedArrayOf<Todo> = []
/// ```
///
/// ## Topics
///
/// ### Getting Started
///
/// - ``EntityIdentifiable``
/// - ``EntityKey``
/// - ``SharingInstantSync``
/// - ``SharingInstantQuery``
///
/// ### Sync Keys
///
/// - ``InstantSyncCollectionKey``
/// - ``InstantQueryKey``
///
/// ### Configuration
///
/// - ``OrderBy``
/// - ``EntityKeyOrderDirection``
/// - ``UniqueRequestKeyID``

// Re-export key types for convenience
@_exported import Dependencies
@_exported import IdentifiedCollections
@_exported import InstantDB
@_exported import Sharing
