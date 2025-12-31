# SharingInstant Sync Architecture Analysis

## Executive Summary

The SharingInstant Swift library attempts to provide InstantDB synchronization through Point-Free's `@Shared` property wrapper. However, a fundamental architectural mismatch exists between how TypeScript's InstantDB client handles mutations and how `@Shared` works. This document analyzes the problem, documents the TypeScript approach, and explores potential solutions.

---

## Table of Contents

1. [The Problem](#the-problem)
2. [TypeScript SDK Architecture](#typescript-sdk-architecture)
3. [Why @Shared is Problematic](#why-shared-is-problematic)
4. [Evidence from Debug Logs](#evidence-from-debug-logs)
5. [Potential Solutions](#potential-solutions)
6. [Unknown Unknowns](#unknown-unknowns)
7. [Recommendations](#recommendations)

---

## The Problem

### Observed Symptoms

1. **Ghost Deletions**: When the app starts fresh, profiles that exist on the server are incorrectly deleted
2. **Re-sync Bug**: When creating a new item after server-side deletions, deleted items reappear
3. **Race Conditions**: Multiple `@Shared` subscriptions to the same namespace cause incorrect diff computations
4. **Linked Entity Traversal**: When saving a post with an author link, the entire author's posts array gets re-synced

### Root Cause Summary

The Swift implementation tries to **compute what changed** by comparing local state to server state. This is fundamentally incompatible with:

1. **Multiple views of the same data**: Different `@Shared` properties can have different subsets of the same namespace
2. **Asynchronous state updates**: Server state and local state update at different times
3. **Linked entity graphs**: Traversing linked entities pulls in data the user didn't intend to modify

---

## TypeScript SDK Architecture

### Core Principle: Explicit Mutations, Not Diffs

The TypeScript SDK does **NOT** compute diffs. Instead, it tracks **explicit user-initiated mutations** separately from server data.

### Key Files and Code

#### 1. Reactor.js - The Heart of State Management

**File**: `instant/client/packages/core/src/Reactor.js`

The `pendingMutations` is stored in a persisted key-value store and accessed via helper methods:

```javascript
// Line 817-818: Accessor for pending mutations
_pendingMutations() {
  return this.kv.currentValue.pendingMutations ?? new Map();
}

// Line 821-826: Mutator for pending mutations
_updatePendingMutations(f) {
  this.kv.updateInPlace((prev) => {
    const muts = prev.pendingMutations ?? new Map();
    prev.pendingMutations = muts;
    f(muts);
  });
}
```

**Critical insight**: `pendingMutations` is a **Map of transaction ID → mutation operations**. It stores what the user explicitly asked for, not what we think changed.

#### 2. How Transactions Work

**File**: `instant/client/packages/core/src/Reactor.js`

```javascript
// Line 1348-1358: pushOps - stores mutation and sends to server
pushOps = (txSteps, error) => {
  const eventId = uuid();
  const mutations = [...this._pendingMutations().values()];
  const order = Math.max(0, ...mutations.map((mut) => mut.order || 0)) + 1;
  const mutation = {
    op: 'transact',
    'tx-steps': txSteps,
    created: Date.now(),
    error,
    order,
  };
  // ... stores in pendingMutations and sends to server
}
```

**Key point**: `pushOps` sends **only the current mutation**, not all pending mutations or the entire state. Each mutation gets a unique `eventId` (UUID) for tracking.

#### 3. Optimistic Updates at Read Time

**File**: `instant/client/packages/core/src/Reactor.js`

```javascript
// Line 1263-1272: Apply optimistic updates ON TOP of server data
_applyOptimisticUpdates(store, attrsStore, mutations, processedTxId) {
  for (const [_, mut] of mutations) {
    // Only apply mutations that haven't been processed by server yet
    if (!mut['tx-id'] || (processedTxId && mut['tx-id'] > processedTxId)) {
      const result = s.transact(store, attrsStore, mut['tx-steps']);
      store = result.store;
      attrsStore = result.attrsStore;
    }
  }
  return { store, attrsStore };
}
```

**This is the key architectural difference**: 
- Server data (`store`) is the **source of truth**
- Pending mutations are a **separate layer** applied at read time
- The client never "computes" what changed - it knows because the user explicitly told it
- Mutations are removed only after `processedTxId` confirms server processed them

#### 4. Link Operations - The Critical Difference

**File**: `instant/client/packages/core/src/instaml.ts`

```typescript
// Line 154-178: expandLink - Links only contain IDs, not full entity objects
function expandLink({ attrsStore }: Ctx, [etype, eidA, obj]) {
  const addTriples = Object.entries(obj).flatMap(([label, eidOrEids]) => {
    const eids = Array.isArray(eidOrEids) ? eidOrEids : [eidOrEids];
    const fwdAttr = getAttrByFwdIdentName(attrsStore, etype, label);
    const revAttr = getAttrByReverseIdentName(attrsStore, etype, label);
    return eids.map((eidB) => {
      const txStep = fwdAttr
        ? [
            'add-triple',
            extractLookup(attrsStore, etype, eidA),
            fwdAttr.id,
            // Only the ID of the linked entity is used!
            extractLookup(attrsStore, fwdAttr['reverse-identity']![1], eidB),
          ]
        : [
            'add-triple',
            extractLookup(attrsStore, revAttr!['forward-identity']![1], eidB),
            revAttr?.id,
            extractLookup(attrsStore, etype, eidA),
          ];
      return txStep;
    });
  });
  return withIdAttrForLookup(attrsStore, etype, eidA, addTriples);
}
```

**Important**: When you link a post to an author, you pass `authorId`, not the full `Author` object. The function generates `add-triple` operations with just the IDs - it never traverses into the linked entity's data.

### TypeScript Transaction Example

```typescript
// User wants to create a post linked to an author
db.transact([
  tx.posts[postId].update({ content: "Hello" }),
  tx.posts[postId].link({ author: authorId })
])

// This generates EXACTLY these operations:
// [
//   ["update", "posts", postId, { content: "Hello" }],
//   ["link", "posts", postId, { author: authorId }]
// ]

// Notice: NO operations for the author entity itself
// NO operations for the author's other posts
// ONLY what the user explicitly requested
```

---

## Why @Shared is Problematic

### The Fundamental Mismatch

`@Shared` is designed for **state synchronization**, not **mutation tracking**.

| Aspect | TypeScript SDK | @Shared |
|--------|---------------|---------|
| **What it stores** | Explicit mutations | Full state snapshots |
| **How it detects changes** | User explicitly calls `transact()` | Property wrapper detects any mutation |
| **Granularity** | Individual operations | Entire collection |
| **Linked entities** | Only IDs | Full embedded objects |

### Problem 1: Multiple Subscriptions Race

The MicroblogDemo has multiple `@Shared` properties for the same namespace:

```swift
// Subscription 1: Posts with author links
@Shared(.instantSync(Schema.posts.with(\.author)...)) var posts

// Subscription 2: Profiles directly  
@Shared(.instantSync(Schema.profiles...)) var profiles
```

When `ensureProfilesExist()` modifies profiles:
1. **Subscription 1** sees 1 profile (only authors of existing posts)
2. **Subscription 2** sees 2 profiles (all profiles)

Both trigger `save()` at nearly the same time:
- Save 1: currentIDs = [Alice] → computes Bob as "deleted"
- Save 2: currentIDs = [Alice, Bob] → computes nothing changed

**Result**: Bob gets deleted incorrectly.

### Problem 2: No Mutation Tracking

When you call:
```swift
$profiles.withLock { $0.insert(newProfile) }
```

The `@Shared` property wrapper:
1. Detects the collection changed
2. Calls `save()` with the entire new collection
3. Has NO knowledge of what specifically changed

We try to compute the diff by comparing to server state, but:
- Server state might be stale
- Another subscription might have a different view
- Race conditions cause incorrect diffs

### Problem 3: Linked Entity Traversal

When saving a `Post` with an embedded `Author`:

```swift
struct Post: Entity {
  var id: String
  var content: String
  var author: Profile  // Full embedded object!
}
```

Our `traverse()` function:
1. Processes the Post
2. Sees `author` is a linked entity
3. Recursively traverses into `author`
4. Sees `author.posts` array
5. Traverses ALL of author's posts
6. Creates update operations for posts that weren't meant to be modified

**This is fundamentally different from TypeScript**, where links only contain IDs.

---

## Evidence from Debug Logs

### Log Evidence: Race Condition

From the debug logs at timestamp `1767131294259`:

```json
{"location":"save.entry","message":"Save called","data":{"itemCount":1,"namespace":"profiles"}}
{"location":"save.entry","message":"Save called","data":{"itemCount":0,"namespace":"profiles"}}
```

Two saves for the same namespace, milliseconds apart, with different item counts!

### Log Evidence: Incorrect Deletion Detection

```json
{"location":"StateTracker.computeDiff","data":{
  "serverStateCount":2,
  "currentIDsCount":1,
  "serverIDs":["alice-id","bob-id"],
  "currentIDs":["alice-id"]
}}
{"location":"StateTracker.computeDiff","data":{
  "newlyDeletedCount":1  // Bob incorrectly marked as deleted!
}}
```

The subscription only sees Alice (because it's a posts-with-author query), but the server has both Alice and Bob. The diff computation incorrectly thinks Bob should be deleted.

### Log Evidence: Linked Entity Problem

From earlier debug session:

```json
{"location":"traverse.chunkCreated","data":{
  "entityId":"old-post-id",
  "namespace":"posts",
  "isTopLevel":false  // This is a linked entity being traversed!
}}
```

Old posts were being re-synced because they were in the author's `posts` array.

---

## Potential Solutions

### Option A: Mutation Tracking Layer (Attempted, Partially Failed)

**Approach**: Track what the user explicitly changed, not the full state.

**Implementation**:
```swift
actor StateTracker {
  var serverStateByKey: [String: Set<String>]
  var locallyAddedByKey: [String: Set<String>]
  var locallyDeletedByKey: [String: Set<String>]
  
  func computeDiff(keyID: String, currentIDs: Set<String>) -> (added: Set<String>, deleted: Set<String>)
}
```

**Why it partially failed**: 
- Multiple subscriptions share the same `StateTracker`
- Different subscriptions have different views of `currentIDs`
- Can't reliably distinguish "user deleted this" from "this subscription doesn't see this item"

### Option B: Per-Subscription State Tracking

**Approach**: Each `@Shared` instance tracks its own server state independently.

**Implementation**:
```swift
class InstantSyncKey<Value> {
  // Each subscription has its own identity
  let subscriptionID = UUID()
  
  // Track server state per-subscription, not per-namespace
  var myServerState: Set<String>
}
```

**Challenges**:
- How to coordinate between subscriptions for the same namespace?
- What if two subscriptions see overlapping but different subsets?
- Memory overhead of tracking per-subscription

### Option C: Explicit Mutation API (Matches TypeScript)

**Approach**: Don't use `@Shared` for mutations. Use explicit transaction API.

**Implementation**:
```swift
// Read-only subscriptions
@Shared(.instantSync(Schema.posts)) var posts

// Explicit mutations (like TypeScript)
try await db.transact([
  .update("posts", postId, ["content": "Hello"]),
  .link("posts", postId, ["author": authorId])
])
```

**Advantages**:
- Matches TypeScript exactly
- No diff computation needed
- No race conditions
- Links are just IDs

**Disadvantages**:
- Loses the ergonomic `$posts.withLock { }` syntax
- Two different APIs for read vs write
- Requires significant refactoring of existing code

### Option D: Hybrid Approach

**Approach**: Use `@Shared` for reads, intercept mutations at a lower level.

**Implementation**:
```swift
// Custom @Shared that intercepts mutations
@SharedInstant(.sync(Schema.posts)) var posts

// Under the hood:
// - Reads use normal @Shared subscription
// - Writes intercept the mutation and convert to explicit operations
// - Only the specific change is sent, not the full state
```

**Challenges**:
- Requires deep integration with @Shared internals
- May not be possible without modifying swift-sharing
- Complex to implement correctly

### Option E: Snapshot-Based Diffing (Like Firestore)

**Approach**: Before saving, fetch current server state and compute diff against that.

**Implementation**:
```swift
func save() async {
  // Fetch current server state
  let serverSnapshot = await fetchCurrentState()
  
  // Compute diff against fresh server state
  let diff = computeDiff(local: currentState, server: serverSnapshot)
  
  // Send only the diff
  await sendDiff(diff)
}
```

**Advantages**:
- Always diffing against fresh server state
- No race conditions from stale state

**Disadvantages**:
- Extra network round-trip on every save
- Latency impact
- Still doesn't solve the linked entity problem

---

## Unknown Unknowns

### 1. Concurrent Modifications from Other Clients

What happens when:
- Client A and Client B both modify the same entity
- Client A's save is in flight when Client B's modification arrives
- The server state changes between diff computation and transaction execution

**TypeScript handles this** with transaction IDs and server-side conflict resolution. Our diff-based approach has no such mechanism.

### 2. Partial Subscription Results

When using queries with filters or limits:
```swift
@Shared(.instantSync(Schema.posts.where(\.isPublished, .eq, true)))
```

The subscription only returns published posts. If we compute diffs against this partial view, we might incorrectly delete unpublished posts.

### 3. Nested Link Cycles

What if:
- Post A has author User X
- User X has posts [A, B, C]
- Post B has comments [...]
- Comments have authors [...]

The traversal could potentially create infinite loops or exponentially large transaction sets.

### 4. Transaction Atomicity

TypeScript transactions are atomic - all operations succeed or fail together. Our current approach sends operations that might partially succeed, leaving the database in an inconsistent state.

### 5. Offline Support

TypeScript's `pendingMutations` naturally supports offline:
- Mutations are stored locally
- Applied optimistically
- Synced when connection returns

Our diff-based approach requires server state to compute diffs, making offline support problematic.

### 6. Schema Migrations

What happens when the schema changes and:
- Old entities have fields that no longer exist
- New required fields are added
- Link relationships change

The TypeScript SDK handles this through explicit migrations. Our reflection-based approach might silently corrupt data.

### 7. Memory Pressure

Tracking server state for every subscription could lead to:
- Memory bloat with large datasets
- Stale state if subscriptions aren't properly cleaned up
- Memory leaks from retained closures

---

## Recommendations

### Short-Term (Immediate Stability)

1. **Disable automatic deletion detection** - Only send explicit additions
2. **Don't traverse linked entities** - Only extract IDs for link operations
3. **Add subscription identity** - Track state per-subscription, not per-namespace

### Medium-Term (Architectural Improvement)

1. **Implement explicit mutation API** alongside `@Shared`
2. **Add transaction batching** to reduce race conditions
3. **Implement proper conflict resolution**

### Long-Term (Full Parity with TypeScript)

1. **Redesign around explicit mutations** - Match TypeScript's `pendingMutations` architecture
2. **Consider custom property wrapper** - One that tracks mutations, not just state
3. **Implement offline support** - Store mutations locally, apply optimistically

---

## Conclusion

The fundamental issue is architectural: `@Shared` gives us **state snapshots**, but InstantDB needs **explicit mutations**. Trying to derive mutations from state changes is inherently lossy and race-prone.

The TypeScript SDK's approach of storing explicit mutations separately from server data is more robust because:
1. It knows exactly what the user intended
2. It doesn't need to compute diffs
3. It can apply mutations optimistically without confusion
4. It handles offline naturally

To achieve parity, SharingInstant needs to either:
- Abandon `@Shared` for writes and use explicit transactions
- Create a custom property wrapper that tracks mutations at the operation level
- Accept the limitations and document them clearly

---

## Instant iOS SDK: A Potential Solution Path

The official Instant iOS SDK (`instant-ios-sdk/`) provides a different approach that could inform SharingInstant's architecture.

### The @InstantEntity Macro

The iOS SDK uses a Swift macro to generate explicit transaction methods:

**File**: `instant-ios-sdk/demos/instantdb-example/instantdb-example/CaseStudies/TransactionTest/Models/Goal.swift`

```swift
@InstantEntity("goals")
struct Goal {
  let id: String
  var title: String
  var difficulty: Int?
  var completed: Bool?
}
```

This macro generates:
- `Goal.create(title:difficulty:completed:)` → Returns `TransactionChunk`
- `Goal.update(id:title:difficulty:)` → Returns `TransactionChunk`
- `Goal.delete(id:)` → Returns `TransactionChunk`
- `Goal.link(id:_:to:)` → Returns `TransactionChunk`
- `Goal.unlink(id:_:from:)` → Returns `TransactionChunk`

### Explicit Transaction API

**File**: `instant-ios-sdk/demos/instantdb-example/instantdb-example/CaseStudies/TransactionTest/ViewModels/TransactionTestViewModel.swift`

```swift
// Create
func createGoal(title: String, difficulty: Int) {
  try db.transact {
    Goal.create(title: title, difficulty: difficulty, completed: false)
  }
}

// Update
func updateGoal(goalId: String, title: String, difficulty: Int) {
  try db.transact {
    Goal.update(id: goalId, title: title, difficulty: difficulty)
  }
}

// Delete
func deleteGoal(goalId: String) {
  try db.transact {
    Goal.delete(id: goalId)
  }
}
```

### TransactionChunk Structure

**File**: `instant-ios-sdk/Sources/InstantDB/Transaction/TransactionChunk.swift`

```swift
public struct TransactionChunk: @unchecked Sendable {
    public let namespace: String
    public let id: String
    public let ops: [[Any]]  // The actual operations: ["update", "goals", id, attrs]
}
```

### Generated Link Methods

**File**: `instant-ios-sdk/Sources/InstantDBMacros/InstantEntityMacro.swift`

```swift
// Generated link method - only takes IDs, not full entities
static func link(id: String, _ relationship: String, to ids: [String]) -> TransactionChunk {
    TransactionChunk(
        namespace: namespace,
        id: id,
        ops: [["link", namespace, id, [relationship: ids]]]
    )
}
```

**Key insight**: The link method only takes IDs (`to ids: [String]`), never full entity objects. This matches the TypeScript behavior exactly.

### Query Subscriptions (Separate from Mutations)

The iOS SDK keeps queries and mutations completely separate:

```swift
// Subscribe to query (READ)
try db.subscribe(db.query(Goal.self)) { result in
  self.goals = result.data
}

// Explicit mutation (WRITE) - completely separate operation
try db.transact { Goal.create(title: "New Goal") }
```

### Why This Matters for SharingInstant

The iOS SDK demonstrates that it's possible to have:
1. **Type-safe queries** with `db.query(Goal.self)`
2. **Explicit mutations** with `Goal.create()`, `Goal.update()`, `Goal.delete()`
3. **Links as IDs only** with `Goal.link(id:_:to:)`

The key difference from SharingInstant's `@Shared` approach:
- iOS SDK: Mutations are **explicit** - you call `Goal.create()` and it generates specific operations
- SharingInstant: Mutations are **implicit** - you modify a collection and we try to figure out what changed

### Potential Hybrid Approach

SharingInstant could potentially adopt a hybrid model:

```swift
// Read-only subscription (like current @Shared)
@Shared(.instantSync(Schema.goals)) var goals

// But mutations use explicit API (like iOS SDK)
try await db.transact {
  Goal.create(title: "New Goal")
  Goal.link(id: goalId, "owner", to: userId)
}
```

This would:
1. Keep the ergonomic `@Shared` for reactive reads
2. Use explicit transactions for writes (no diff computation needed)
3. Match TypeScript behavior exactly
4. Eliminate race conditions

The tradeoff is losing the `$goals.withLock { $0.insert(newGoal) }` syntax, but gaining correctness and predictability.

---

## Appendix: Key Files Reference

### TypeScript SDK Files

| File | Purpose |
|------|---------|
| `instant/client/packages/core/src/Reactor.js` | Main state management, `pendingMutations` |
| `instant/client/packages/core/src/store.ts` | Entity storage and retrieval |
| `instant/client/packages/core/src/instaml.ts` | Transaction DSL (update, link, delete) |
| `instant/client/packages/core/src/instatx.ts` | Transaction builder |
| `instant/client/packages/react/src/index.ts` | React hooks (`useQuery`, `useMutation`) |

### Instant iOS SDK Files

| File | Purpose |
|------|---------|
| `instant-ios-sdk/Sources/InstantDBMacros/InstantEntityMacro.swift` | `@InstantEntity` macro that generates CRUD methods |
| `instant-ios-sdk/Sources/InstantDB/Transaction/TransactionChunk.swift` | Transaction operation structure |
| `instant-ios-sdk/Sources/InstantDB/Transaction/TransactionBuilder.swift` | `@dynamicMemberLookup` transaction builder |
| `instant-ios-sdk/Sources/InstantDB/Query/TypedQuery.swift` | Type-safe query builder |
| `instant-ios-sdk/Sources/InstantDB/Core/InstantClient.swift` | Main client with `transact()` methods |

### SharingInstant Files

| File | Purpose |
|------|---------|
| `sharing-instant/Sources/SharingInstant/InstantSyncKey.swift` | Main sync implementation with `StateTracker` |
| `sharing-instant/Examples/CaseStudies/MicroblogDemo.swift` | Demo showing the bug |
| `sharing-instant/Tests/SharingInstantTests/PendingMutationsTests.swift` | Tests for mutation behavior |

---

*Document created: December 30, 2025*
*Based on debug session analysis of SharingInstant sync issues*
