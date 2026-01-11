# Recovery Progress - Jan 9-10, 2026

## What Happened
At 21:53:37 on Jan 9, ~24 files in sharing-instant were mysteriously blanked out (reduced to 1-line empty files). This happened when a new Cursor session started. The cause is unclear but may be related to IDE buffer issues.

## What We Did
1. Created backup branch `backup-weird-state` with all the weird changes committed (commit `bcfde3d`)
2. Switched back to `master` - this automatically restored all 24 zeroed files to their correct state

## Current State
- `master` branch: Clean, all zeroed files restored
- `backup-weird-state` branch: Contains the weird state + some legitimate changes we want to recover
- **Staged for commit**: Recovered files (see below)

---

## Decision Log

### Jan 10, 10:20 AM - Simple KEEP Files (STAGED)

These files have been recovered from `backup-weird-state` and staged:

- [x] `.gitignore` - adds `debug-logs.jsonl`
- [x] `Examples/CaseStudies/App.swift` - adds MemoryMonitor overlay
- [x] `Examples/CaseStudies/RecursiveLoaderDemo.swift` - adds `#if os(iOS)` guard
- [x] `Examples/CaseStudies/Internal/MemoryMonitor.swift` - NEW file, debug tool
- [x] `Tests/SharingInstantTests/SynchronousConsistencyTests.swift` - NEW test file

### Jan 10, 10:20 AM - InstantSyncKey.swift Review

**Decision: KEEP MASTER (do not recover from backup)**

**What backup had that master doesn't:**
- `StateTracker` actor (~110 lines) that tracks server-confirmed IDs, locally-added IDs, locally-deleted IDs
- Active `save()` method (~200 lines) that computes diffs and sends only changes
- `subscribe()` that filters out locally-deleted items

**What master has that backup doesn't:**
- Explicit documentation explaining WHY StateTracker was removed
- Cleaner, simpler code path

**Why keep master:**
The StateTracker was intentionally removed because:
1. It used a "fragile 50% heuristic for deletion detection"
2. It didn't match TypeScript SDK behavior (TypeScript uses explicit mutations only)
3. The explicit mutation approach (`$todos.create()`, `$todos.delete()`) is cleaner and more predictable

The backup version represents older code that was deliberately replaced.

### Jan 10, 10:20 AM - SharedMutations.swift Review

**Decision: KEEP MASTER (do not recover from backup)**

**What backup had that master doesn't:**
- Nothing - backup is a strict subset of master

**What master has that backup doesn't:**
1. `MutationCallbacks<T>` struct - TanStack Query-style callbacks (onMutate, onSuccess, onError, onSettled)
2. `MutationCallbacks` convenience initializers
3. `updateField()` / `updateFields()` helper methods for IdentifiedArray
4. `DictionaryEncoder` for encoding entity attributes

**Why keep master:**
Master has MORE features. The backup is an older, less complete version. MutationCallbacks are used by AdvancedTodoDemo for toast notifications.

### Jan 10, 10:26 AM - TripleStore.swift Review

**Decision: KEEP MASTER (do not recover from backup)**

**What backup had that master doesn't:**
- Nothing - backup removes functionality without adding anything

**What master has that backup doesn't:**
1. **Reverse link notification** - When a ref triple is added/retracted, notifies BOTH source AND target entity (backup only notifies source)
2. **Reverse link cleanup on delete** - Deletes reverse links via `getReverseRefs()` when entity is deleted, preventing "ghost" entities
3. Comments explaining this matches TypeScript SDK behavior in `store.ts deleteEntity()`

**Why keep master:**
These are bug fixes. Without reverse link notification, subscriptions driven by reverse links won't see updates. Without cleanup on delete, VAE index retains stale references causing ghost entities.

### Jan 10, 10:26 AM - TripleStore+Extensions.swift Review

**Decision: KEEP MASTER (do not recover from backup)**

**What backup had that master doesn't:**
- Nothing - backup removes safety checks without adding anything

**What master has that backup doesn't:**
1. **Ghost entity filtering** - Skips entities with only "id" field (deleted/not-fully-loaded), prevents decode failures
2. **Nested reverse link resolution** - Resolves reverse links at ALL depths (`depth < maxDepth`), not just depth 0
3. **Empty array filtering** - Doesn't add empty arrays when all reverse-linked entities were deleted

**Why keep master:**
- Ghost entity filtering prevents crashes when entities are deleted but refs remain
- Nested resolution enables queries like `posts.with(\.comments) { $0.with(\.author) }` where author is a reverse link
- Empty array filtering prevents decode issues

### Jan 10, 10:35 AM - InstantSyncKey+Helpers.swift Review

**Decision: KEEP MASTER (do not recover from backup)**

**What backup had that master doesn't:**
- Binds `orderBy`, `orderDirection`, `whereClauses` variables in switch case (but doesn't use them)
- Uses `if let limit = limit` instead of `if limit != nil`

**What master has that backup doesn't:**
- Uses `_` wildcards for unused parameters (cleaner, no compiler warnings)

**Why keep master:**
Both versions have identical function bodies - neither actually implements orderBy/where/limit in this helper function. The actual query options are implemented in `Reactor.swift` and `InstantQueryKey.swift`. Master is cleaner by using `_` for unused params rather than binding them and ignoring them.

### Jan 10, 10:35 AM - main.swift (instant-schema CLI) Review

**Decision: KEEP MASTER (do not recover from backup)**

**What backup had that master doesn't:**
- Simpler single `ensureCleanWorkingDirectory()` call

**What master has that backup doesn't:**
- Separate validation for schema file AND output directory
- More specific error messages ("Schema file is committed" vs "Output directory is clean")

**Why keep master:**
Master has more granular validation with better error messages. Easier to debug issues.

### Jan 10, 10:35 AM - Generated/* files Review

**Decision: KEEP MASTER (do not recover from backup)**

**What backup had:**
- Older, smaller generated schema files (1319 fewer lines)

**What master has:**
- Current generated files matching the schema

**Why keep master:**
These are AUTO-GENERATED from `instant.schema.ts`. Should never be manually edited. Master has the current generation. If needed, regenerate with `swift run instant-schema generate`.

### Jan 10, 10:40 AM - ReactorOptimisticUpdateTests.swift Review

**Decision: KEEP MASTER (do not recover from backup)**

**What backup had that master doesn't:**
- Updated doc comments referencing "query-level reactivity" refactor

**What master has that backup doesn't:**
- 3 test methods: `testTripleStoreObserverPatternWorks()`, `testTripleStoreDeleteNotifiesObservers()`, `testMultipleEntityObserversAreIndependent()`
- `ObserverCounter` helper actor

**Why keep master:**
Master has MORE tests. Backup removed tests assuming per-entity observers were removed, but master still has that functionality.

### Jan 10, 10:45 AM - TripleStoreReverseLinkResolutionTests.swift Review

**Decision: KEEP MASTER + ADD TODO COMMENT (staged)**

**What backup had that master doesn't:**
- Adds `includedLinks: ["author"]` parameter to `store.get()` call
- Comment explaining bidirectional relationship memory concerns

**What master has that backup doesn't:**
- Working test code (backup's change would fail to compile)

**Investigation findings:**
The backup modified this test to use an `includedLinks` parameter that **does not exist** on `store.get()`:
```swift
// Backup (does not compile):
store.get(id: postId, attrsStore: attrsStore, includedLinks: ["author"])
```

Git history search revealed:
1. `store.get()` has NEVER had an `includedLinks` parameter in any commit
2. The `includedLinks` concept DOES exist in `Reactor.swift` for subscriptions
3. This appears to be incomplete/planned work that was never finished

**Action taken:**
Added detailed TODO comment to the test documenting this artifact for future investigation. The comment explains the recovery context and raises questions about whether `store.get()` should support `includedLinks`.

---

## VERIFICATION COMPLETE

**Total files in backup diff: 49**

| Category | Count | Status |
|----------|-------|--------|
| Staged to commit | 6 | ✅ Ready |
| Zeroed files (auto-restored) | 24 | ✅ Done |
| Reviewed, keeping master | 11 | ✅ Done |
| Demo reverts (not recovering) | 4 | ✅ Done |
| Test snapshots (keeping master) | 4 | ✅ Done |

**All 49 files accounted for.**

---

## FINAL SUMMARY

### Files to COMMIT (currently staged):
- `.gitignore` - adds `debug-logs.jsonl`
- `Examples/CaseStudies/App.swift` - adds MemoryMonitor overlay
- `Examples/CaseStudies/RecursiveLoaderDemo.swift` - adds `#if os(iOS)` guard
- `Examples/CaseStudies/Internal/MemoryMonitor.swift` (NEW) - debug memory monitor tool
- `Tests/SharingInstantTests/SynchronousConsistencyTests.swift` (NEW) - TripleStore consistency tests
- `Tests/SharingInstantTests/TripleStoreReverseLinkResolutionTests.swift` - added TODO comment about `includedLinks`

### Files keeping MASTER (no recovery needed):
- `Sources/SharingInstant/InstantSyncKey.swift`
- `Sources/SharingInstant/SharedMutations.swift`
- `Sources/SharingInstant/Internal/TripleStore.swift`
- `Sources/SharingInstant/Extensions/TripleStore+Extensions.swift`
- `Sources/SharingInstant/InstantSyncKey+Helpers.swift`
- `Sources/instant-schema/main.swift`
- `Tests/SharingInstantTests/Generated/*`
- `Tests/SharingInstantTests/ReactorOptimisticUpdateTests.swift`

### Files NOT recovering (old syntax reverted in backup):
- `Examples/CaseStudies/AdvancedTodoDemo.swift`
- `Examples/CaseStudies/DifferentWithClausesDemo.swift`
- `Examples/CaseStudies/ObservableModelDemo.swift`
- `Examples/CaseStudies/SwiftUISyncDemo.swift`
- Various test snapshots

---

## Next Steps
1. Review staged changes one more time: `git diff --staged`
2. Commit the staged files
3. Keep `backup-weird-state` branch for reference (contains the `includedLinks` artifact)
4. Optionally commit this RECOVERY-PROGRESS.md file

## Commands Reference
```bash
# View staged changes:
git diff --staged

# Commit:
git commit -m "feat: Add MemoryMonitor, SynchronousConsistencyTests, and includedLinks TODO"

# Keep backup branch for reference (has includedLinks artifact)
# git branch -D backup-weird-state  # Don't do this yet
```

---

# instant-ios-sdk Recovery - Jan 11, 2026

## What Happened

The same Cursor IDE corruption that affected `sharing-instant` also hit the sibling `instant-ios-sdk` repository. Files on the `feat/local-first-triple-store` branch were either zeroed out (0-3 bytes) or reverted to their `main` branch state, losing all feature branch enhancements.

## Impact Summary

| Category | Files Affected | Lines Lost |
|----------|----------------|------------|
| Zeroed out (0 bytes) | 7 files | ~2,432 lines |
| Near-empty (1-3 bytes) | 8 files | ~4,456 lines |
| Reverted to main | 17 files | ~2,000 lines |
| Partial changes | 4 files | ~1,000 lines |
| **Total** | **35 files** | **~9,775 lines** |

## Recovery Approach

Unlike `sharing-instant`, this repo had a clean recovery path: the branch was tracked and up-to-date with the remote `fork/feat/local-first-triple-store`.

### Steps Taken

1. **Created backup branch**: `backup-weird-cursor-corruption-jan11`
   - Committed all corrupted state for reference (commit `eeecc48`)

2. **Switched back to feature branch**: `git checkout feat/local-first-triple-store`
   - This automatically discarded all local changes and restored files from the remote tracking branch

3. **Verified recovery**:
   - `swift build` - ✅ Builds successfully (only minor warnings)
   - `swift test` - ✅ All tests pass

## Key Files That Were Zeroed

These NEW feature files were completely emptied:
- `Sources/InstantDB/Store/TripleStore.swift` (448 lines)
- `Sources/InstantDB/Presence/PresenceManager.swift` (874 lines)
- `Sources/InstantDB/LocalStorage/LocalStorage.swift` (750 lines)
- `Sources/InstantDB/Network/ServerMessagePayloads.swift` (570 lines)
- `Sources/InstantDB/LocalFirst/LocalFirstManager.swift` (511 lines)
- `Sources/InstantDB/Store/Triple.swift` (330 lines)
- `Sources/InstantDB/Store/AttrsStore.swift` (309 lines)
- And 8 more...

## Key Files That Were Reverted to Main

These files lost their feature branch enhancements:
- `Sources/InstantDB/Core/InstantClient.swift` (1423 → 692 lines)
- `Sources/InstantDB/Core/Types.swift` (594 → 377 lines)
- `Sources/InstantDB/Query/InstaQLProcessor.swift` (454 → 73 lines)
- `Sources/InstantDB/Network/WebSocketConnection.swift` (529 → 375 lines)
- And 13 more...

## Current State

- **Branch**: `feat/local-first-triple-store` - ✅ Fully restored
- **Backup**: `backup-weird-cursor-corruption-jan11` - Contains corrupted state
- **Build**: ✅ Passing
- **Tests**: ✅ Passing

## Notes

The corruption pattern was identical to `sharing-instant`:
- Files were either completely zeroed (0 bytes)
- Or reverted to their `main` branch state
- Some files had partial changes (a mix of main + some feature code)

The key difference: `instant-ios-sdk` had a clean remote to restore from, while `sharing-instant` required manual file-by-file review.

---

# Full TypeScript SDK Test Parity - Jan 11, 2026

## Summary

Completed full implementation of TypeScript SDK test parity for link resolution, including:
1. Implementation of `includedLinks` parameter (the artifact discovered during recovery)
2. 24 new tests ported from TypeScript SDK
3. Fixed reverse cardinality logic using `unique?` field

## Commits Pushed to Remote

### Commit 1: TypeScript SDK Test Parity
- **Hash**: `7c6021a086f0588f59a135df021fc914d6a4aff5`
- **Date**: 2026-01-11 18:05:03 -0500
- **Message**: `feat: Add TypeScript SDK test parity for link resolution`
- **Remote**: Pushed to `origin/master`

**Changes (9 files, +2173 lines):**
- `Sources/SharingInstant/Extensions/TripleStore+Extensions.swift` - Added `includedLinks` parameter, fixed reverse cardinality
- `Sources/SharingInstant/Internal/TripleStore.swift` - Added `includedLinks` parameter to `get()`
- `Tests/SharingInstantTests/Fixtures/ZenecaEntities.swift` - NEW: Entity structs for zeneca domain
- `Tests/SharingInstantTests/Fixtures/ZenecaTestData.swift` - NEW: Test data factory with documentation
- `Tests/SharingInstantTests/Fixtures/TestHelpers.swift` - NEW: Helper functions for creating attributes
- `Tests/SharingInstantTests/TripleStoreLinkTests.swift` - NEW: 8 tests from store.test.ts
- `Tests/SharingInstantTests/TripleStoreQueryTests.swift` - NEW: 9 tests from instaql.test.ts
- `Tests/SharingInstantTests/IncludedLinksTests.swift` - NEW: 7 tests for includedLinks parameter
- `Tests/SharingInstantTests/TripleStoreReverseLinkResolutionTests.swift` - Fixed `unique?` key naming

**Upstream Sources:**
- https://github.com/instantdb/instant/blob/main/client/packages/core/__tests__/src/store.test.ts
- https://github.com/instantdb/instant/blob/main/client/packages/core/__tests__/src/instaql.test.ts
- https://github.com/instantdb/instant/blob/main/client/packages/core/__tests__/src/data/zeneca/

### Commit 2: Debug Tooling & Consistency Tests
- **Hash**: `c3455bae697b0ead0db6ebb00b45fdfdf757eaf6`
- **Date**: 2026-01-11 18:05:57 -0500
- **Message**: `chore: Add memory monitor and synchronous consistency tests`
- **Remote**: Pushed to `origin/master`

**Changes (5 files, +466 lines):**
- `.gitignore` - Added `debug-logs.jsonl`
- `Examples/CaseStudies/App.swift` - Added MemoryMonitor overlay (DEBUG only)
- `Examples/CaseStudies/Internal/MemoryMonitor.swift` - NEW: Debug memory monitoring utility
- `Examples/CaseStudies/RecursiveLoaderDemo.swift` - macOS compatibility fix
- `Tests/SharingInstantTests/SynchronousConsistencyTests.swift` - NEW: Synchronous consistency tests

## Key Technical Discoveries

### 1. `includedLinks` Parameter Implementation

The recovery revealed an artifact where `includedLinks` was used but never implemented. This has now been fully implemented:

```swift
// TripleStore+Extensions.swift
public func resolve(
    id: String,
    attrsStore: AttrsStore,
    depth: Int = 0,
    maxDepth: Int = 10,
    includedLinks: Set<String>? = nil  // NEW PARAMETER
) -> [String: Any]

public func get<T: Decodable>(
    id: String,
    attrsStore: AttrsStore,
    includedLinks: Set<String>? = nil
) -> T?
```

Behavior:
- `nil` → resolve ALL links (default, backward-compatible)
- `[]` (empty set) → resolve NO links (only scalar attributes)
- `["posts", "author"]` → resolve only specified links

### 2. `unique?` Field (Clojure Naming Convention)

The server uses Clojure predicate naming with `?` suffix. This was causing decode failures:

```swift
// WRONG - won't be decoded
dict["unique"] = true

// CORRECT - matches server encoding
dict["unique?"] = true
```

The `unique?` field encodes REVERSE cardinality:
- `unique? = true` → reverse link is singular (e.g., `posts.author: Profile?`)
- `unique? = false/nil` → reverse link is array (e.g., `bookshelves.users: [User]?`)

### 3. Reverse Cardinality Fix

Fixed the cardinality determination in `TripleStore+Extensions.swift`:

```swift
// BEFORE (wrong):
let isReverseSingular = attr.cardinality == .one

// AFTER (correct):
let isReverseSingular = attr.unique == true
```

## Test Results

All 25 new tests pass:
- `TripleStoreLinkTests`: 8 tests
- `TripleStoreQueryTests`: 9 tests
- `IncludedLinksTests`: 7 tests
- `TripleStoreReverseLinkResolutionTests`: 1 test

## Lessons Learned

1. **Always push work to remote frequently** - The recovery was only possible because we had commits on the remote
2. **Document quirky conventions** - The `unique?` Clojure naming caused hours of debugging
3. **Link to upstream sources** - All tests now include GitHub links to TypeScript SDK equivalents
4. **Keep recovery documentation** - This file serves as institutional memory
