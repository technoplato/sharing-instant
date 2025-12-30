# SharingInstant Bug Report: Optimistic Insert Overwritten by Server Refresh

## Summary

When inserting a new entity into a `@Shared(.instantSync(...))` collection, the optimistic insert is correctly applied initially, but a subsequent server refresh overwrites the local array with stale server data that doesn't include the newly created entity.

**Root Cause Hypothesis**: When two features query the same entity type with DIFFERENT `.with()` clauses, they create separate subscriptions with different `UniqueRequestKeyID` values. Optimistic updates may not propagate correctly across these different subscription keys.

## Case Study

A reproducible case study has been created at:
`/Users/mlustig/Development/personal/instantdb/sharing-instant/Examples/CaseStudies/DifferentWithClausesDemo.swift`

This demonstrates the issue using Posts with two different queries:
- **Composer**: `Schema.posts.with(\.author)` 
- **Feed**: `Schema.posts.with(\.author).with(\.comments)`

## Comparison with TypeScript Client

The official TypeScript InstantDB client uses a **centralized `pendingMutations` Map** that is applied to ALL queries at read time. When you insert via one query, ALL queries see the optimistic update immediately.

The Swift SharingInstant client uses **per-subscription optimistic tracking** (`optimisticIDs` in each `SubscriptionState` actor). This means optimistic updates may not propagate correctly across different query shapes.

See: `/Users/mlustig/Development/personal/instantdb/instant/client/packages/core/src/Reactor.js` lines 1263-1272 for the TypeScript implementation of `_applyOptimisticUpdates`.

## Environment

- SharingInstant version: Local package at `../../../instantdb/sharing-instant`
- InstantDB App ID: `9e78a752-2611-4db3-a0c1-e5452bbc5ec0`
- Platform: iOS 18 (physical device)

## Steps to Reproduce

1. Start with an empty or nearly empty InstantDB collection
2. Insert a new entity using `@Shared(.instantSync(...))`:
   ```swift
   state.$recordings.withLock { recordings in
       recordings.insert(media, at: 0)
   }
   ```
3. Wait ~10 seconds while the app continues to use the collection
4. Observe that the array now contains a DIFFERENT entity (or is empty)

## Expected Behavior

The newly inserted entity should remain in the local array until the server confirms it, at which point it should still be present.

## Actual Behavior

The newly inserted entity is replaced by stale server data. The `optimisticIDs` tracking mechanism in `SubscriptionState` is not preventing the server refresh from overwriting the local optimistic insert.

## Evidence from Debug Logs

### 1. Insert succeeds (timestamp: 1767059251807)
```json
{
  "message": "Media inserted into recordings",
  "data": {
    "beforeInsertCount": 0,
    "afterInsertCount": 1,
    "mediaID": "591c1c35-0d8a-4862-94d7-2bd0b66310c5",
    "afterInsertIds": ["591c1c35-0d8a-4862-94d7-2bd0b66310c5"]
  }
}
```

### 2. Array still correct at ~6 seconds (TCA Action #27)
```
_recordings: #1 IdentifiedArray(
  Media(
    id: "591c1c35-0d8a-4862-94d7-2bd0b66310c5"
    ...
  )
)
```

### 3. Array contains DIFFERENT ID at ~12 seconds (timestamp: 1767059263912)
```json
{
  "message": "Inside recordings lock",
  "data": {
    "foundIndex": "NOT FOUND",
    "recordingsCount": 1,
    "mediaID": "591c1c35-0d8a-4862-94d7-2bd0b66310c5",
    "allMediaIdsInArray": ["012fdcc7-609e-43d9-9c08-dd8a1e6dbd37"]
  }
}
```

The array now contains `012fdcc7-609e-43d9-9c08-dd8a1e6dbd37` instead of `591c1c35-0d8a-4862-94d7-2bd0b66310c5`.

## Analysis

Looking at the `Reactor.swift` code in SharingInstant, the `SubscriptionState` actor has an `optimisticIDs` array (lines 528-541) that's supposed to track locally-inserted IDs and prevent them from being dropped during server refreshes.

However, the bug suggests that either:
1. The optimistic ID is not being added to `optimisticIDs` when we call `withLock { recordings.insert(...) }`
2. The server refresh is not correctly merging `optimisticIDs` with `serverIDs`
3. There's a race condition where the server refresh happens before the optimistic notification reaches `SubscriptionState`

## Relevant Code Paths

### Insert path (InstantSyncKey.swift)
When `save()` is called, it should:
1. Apply optimistic update via `reactor.transact()`
2. Call `notifyOptimisticUpsert()` which should add the ID to `optimisticIDs`

### Server refresh path (Reactor.swift)
When `handleDBUpdate()` is called, it should:
1. Merge `optimisticIDs` with `serverIDs` 
2. Only remove from `optimisticIDs` if the server has confirmed the ID

## Workaround

Currently, the only workaround is to store the entity locally in TCA state and not rely on the `@Shared(.instantSync(...))` array for the current session's data.

## Impact

This bug breaks the "optimistic update" guarantee of SharingInstant. Users see their newly created data disappear from the UI until a full refresh or app restart.
