# Issue: `InstantSyncKey.save()` Does Not Track Deletions

## Summary

When using `@Shared(.instantSync(...))` with `.withLock { $0.remove(id:) }` to delete items from a collection, the deletion is **not sent to InstantDB**. The item is removed from the local collection, but no `["delete", namespace, id]` operation is transmitted to the server.

## Expected Behavior

When calling:

```swift
$todos.withLock { todos in
    todos.remove(atOffsets: offsets)
}
```

The `InstantSyncKey.save()` method should:
1. Compare the new collection state with the previous state
2. Identify which IDs were removed
3. Generate `["delete", namespace, id]` operations for each removed item
4. Send those delete operations to InstantDB

## Actual Behavior

The `save()` method only iterates over items **currently in the collection** and sends `["update", ...]` and `["link", ...]` operations. It does not track which items were removed, so **no delete operations are ever sent**.

### Evidence

From `InstantSyncKey.swift` lines 367-598, the `save()` method:

```swift
public func save(
    _ value: Value,
    context: SaveContext,
    continuation: SaveContinuation
) {
    // ...
    
    // Only iterates over current items - never tracks deletions
    for item in value {
        // Creates update ops for each item
        // Creates link ops for relationships
        // NEVER creates delete ops for removed items
    }
}
```

The `SaveContext` enum from swift-sharing only provides:
- `.didSet` - mutation via `withLock`
- `.userInitiated` - explicit `save()` call

It does **not** provide the previous value, so `save()` has no way to know what was removed.

### Test Case

Created `RapidUpdateSharingInstantTest.swift` which:
1. Creates test entities using `@Shared(.instantSync(...))` + `.withLock { append() }` ✅ Works
2. Updates entities using `.withLock { $0[index].field = newValue }` ✅ Works  
3. Deletes entities using `.withLock { $0.remove(id:) }` ❌ **Does not delete from InstantDB**

The local collection updates correctly, but the InstantDB dashboard shows the items still exist.

## Workaround

Use `InstantClient` directly for deletions:

```swift
import InstantDB

// Get the SDK client
let db = InstantClientFactory.makeClient()

// Build delete operations manually
let deleteChunks: [TransactionChunk] = idsToDelete.map { id in
    TransactionChunk(
        namespace: "myNamespace",
        id: id,
        ops: [["delete", "myNamespace", id]]
    )
}

// Send directly to InstantDB
try db.transact(deleteChunks)

// Also update local state so UI reflects the change
$items.withLock { items in
    for id in idsToDelete {
        items.remove(id: id)
    }
}
```

## Proposed Fix

The `InstantSyncKey` needs to track the previous set of IDs and compare with the new set on each `save()`. Options:

### Option 1: Track Previous IDs in Key State

```swift
// In InstantSyncCollectionKey
private var previousIds: Set<String> = []

public func save(_ value: Value, context: SaveContext, continuation: SaveContinuation) {
    let currentIds = Set(value.map { $0.id })
    let deletedIds = previousIds.subtracting(currentIds)
    
    // Generate delete ops for removed items
    for deletedId in deletedIds {
        // Add ["delete", namespace, deletedId] to transaction
    }
    
    // Update tracking
    previousIds = currentIds
    
    // ... rest of save logic
}
```

### Option 2: Request `oldValue` from swift-sharing

The `SaveContext` could be extended to include the previous value:

```swift
public enum SaveContext: Hashable, Sendable {
    case didSet(oldValue: Value?)  // Would need generic constraint
    case userInitiated
}
```

This would require changes to the swift-sharing library.

## Impact

This affects any SharingInstant user who expects `.withLock { remove() }` to sync deletions to InstantDB. The pattern shown in `AdvancedTodoDemo.swift`:

```swift
private func deleteTodos(at offsets: IndexSet) {
    $todos.withLock { todos in
        todos.remove(atOffsets: offsets)
    }
}
```

**Does not actually delete from InstantDB** - only from the local collection.

## Related Files

- `Sources/SharingInstant/InstantSyncKey.swift` - The `save()` method that needs fixing
- `Sources/SharingInstant/Internal/Reactor.swift` - Already handles `"delete"` operations when received
- `Examples/CaseStudies/AdvancedTodoDemo.swift` - Uses the broken deletion pattern

## Environment

- SharingInstant: Current main branch
- swift-sharing: Latest
- InstantDB Swift SDK: Latest
- Date discovered: 2025-12-30
