# Debugging & Observability

Understand what’s happening across optimistic updates, schema refreshes, and real-time updates.

## Overview

SharingInstant sits at the intersection of three “noisy” systems:

1. SwiftUI state updates (local, immediate)
2. WebSocket synchronization (remote, asynchronous)
3. Schema- and link-driven decoding (dynamic, server-defined)

When things go wrong, the fastest path to a fix is almost always to determine which layer is
disagreeing with the others.

This article documents the knobs that make those layers observable without turning every app run
into a wall of `print(...)` statements.

## Logging Layers

### 1) Application-level logging (SharingInstant `InstantLogger`)

Use ``InstantLogger`` when you want logs that describe *your app’s* behavior (user actions,
state transitions, and the meaning of a sync), not the details of the protocol.

For example, you can keep stdout quiet while still emitting to Console.app:

```swift
InstantLoggerConfig.printToStdout = false
InstantLoggerConfig.logToOSLog = true
```

> Tip: `InstantLogger` can also sync logs to InstantDB when `InstantLoggerConfig.syncToInstantDB`
> is enabled and your schema includes a `logs` namespace. This is useful for debugging issues that
> only reproduce on a physical device.

### 2) Transport / query / schema logging (InstantDB Swift SDK)

The underlying InstantDB Swift SDK intentionally keeps stdout quiet by default.

Enable verbose logging via environment variables:

- `INSTANTDB_LOG_LEVEL`: `off`, `error`, `info`, `debug` (default: `error`)
- `INSTANTDB_DEBUG=1`: forces `debug`

### 3) SharingInstant internal diagnostics

SharingInstant has a small set of internal diagnostics (for example, decoding failures from the
normalized TripleStore) routed through `os.Logger` so they don’t spam stdout.

Enable them via:

- `SHARINGINSTANT_LOG_LEVEL`: `off`, `error`, `info`, `debug` (default: `error`)
- `SHARINGINSTANT_DEBUG=1`: forces `debug`

For convenience, SharingInstant also respects `INSTANTDB_LOG_LEVEL` / `INSTANTDB_DEBUG` so you can
flip both layers together while debugging.

To tail logs from Terminal:

```bash
log stream --level debug --predicate 'subsystem == "SharingInstant"'
```

## Troubleshooting

### Linked entities resolve to `nil` after refresh (e.g. “Unknown Author”)

If a linked entity shows up correctly in the optimistic UI but later resolves to `nil` after a
server refresh, the most common cause is broken link schema metadata on the backend:

- The link attribute exists but is typed as `blob` instead of `ref`, or
- The link is a `ref` but is missing `reverse-identity`.

#### Why this happens

SharingInstant (and the underlying Swift SDK) perform client-side joins when decoding linked
entities. `reverse-identity` tells the client which namespace + label represent the “other side”
of a link. Without that metadata, the client cannot reliably resolve the relationship.

#### Fix strategy

1. Prefer fixing the schema definition (TypeScript or Swift DSL) and pushing it so the server
   persists correct `ref` metadata.
2. Treat any “lazy repair” behavior in clients as a safety net, not the primary migration path.

## Integration Testing

Some integration tests create fresh backend apps and validate behavior across real round trips.
These tests are skipped by default and must be explicitly enabled:

```bash
INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS=1 \
  swift test --package-path sharing-instant --filter EphemeralMicroblogRoundTripTests
```

## See Also

- <doc:PreparingInstant>
- <doc:Syncing>
- <doc:Querying>

