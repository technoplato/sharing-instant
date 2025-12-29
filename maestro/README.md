# Maestro Tests for SharingInstant

This directory contains Maestro UI tests for the SharingInstant CaseStudies app.

## Prerequisites

1. **Maestro CLI** - Install via:
   ```bash
   curl -Ls "https://get.maestro.mobile.dev" | bash
   ```

2. **Java 17+** - Required by Maestro

3. **InstantDB Admin Token** - Get from the InstantDB dashboard

4. **iPhone Simulator or Device** - iOS 26.x recommended

## Running Tests

### Simple Sync Test

This test reproduces the bidirectional sync bug:

```bash
cd /Users/mlustig/Development/personal/instantdb/sharing-instant/maestro

# Run with admin token
maestro test --env INSTANT_ADMIN_TOKEN=<your-token> flows/simple-sync-test.yaml
```

### Full Bidirectional Sync Test

```bash
maestro test --env INSTANT_ADMIN_TOKEN=<your-token> flows/bidirectional-sync-test.yaml
```

## Test Flow

1. **Launch app** - Opens CaseStudies app
2. **Navigate** - Goes to "Observable Model" demo
3. **Local mutation** - Taps a todo to toggle its done status
4. **Server mutation** - Uses Admin API to toggle a DIFFERENT todo
5. **Verify** - Checks if UI updates (the bug: it doesn't)

## Debug Logs

Tests send debug logs to:
- **Endpoint**: `http://127.0.0.1:7243/ingest/b61a72ba-9985-415b-9c60-d4184ed05385`
- **Log file**: `/Users/mlustig/Development/personal/instantdb/.cursor/debug.log`

## Screenshots

Screenshots are saved to:
- `01_initial_state.png` - Before any mutations
- `02_after_local_toggle.png` - After tapping a todo
- `03_after_server_mutation.png` - After server-side toggle

## The Bug

The bug being tested:
1. User opens Observable Model demo
2. User taps a todo (local mutation works, UI updates)
3. External client (dashboard/Admin API) toggles a different todo
4. **BUG**: iPhone UI does NOT update to reflect the server change

## Hypotheses

- **K**: WebSocket connection issue after local mutation
- **L**: Optimistic update conflict resolution filtering server data
- **M**: `withMutation` not triggering SwiftUI observation for `@Observable` + `@ObservationIgnored`
- **N**: `_PersistentReference` callback pointing to stale instance

## Files

```
maestro/
├── config.yaml              # Maestro configuration
├── flows/
│   ├── simple-sync-test.yaml       # Simple reproduction test
│   └── bidirectional-sync-test.yaml # Full test flow
├── helpers/
│   ├── instant-admin.js     # InstantDB Admin SDK helpers
│   ├── log-state.js         # Debug logging helper
│   ├── server-mutation.js   # Server-side mutation script
│   └── bidirectional-sync-test.js  # Full test logic
└── README.md                # This file
```
