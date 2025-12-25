# Sharing-Instant Test Report (2025-12-24)

This report summarizes the current test health for the `sharing-instant` project, with an emphasis on **high-signal, backend-validated checks**.

## Executive Summary

- ✅ `swift test` passes with no failures (unit + deterministic suites).
- ✅ `INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS=1 swift test` passes with no failures (includes backend tests that create fresh ephemeral apps).
- ✅ `INSTANT_RUN_INTEGRATION_TESTS=1 swift test` passes with no failures (shared-app integration suites).
- ✅ Admin SDK “ground truth” scripts now support `--assert` + `--json` and are executed from Swift tests to validate backend behavior independently of Swift client decoding/caching.
- ⚠️ Some backend tests remain intentionally skipped unless `INSTANT_RUN_INTEGRATION_TESTS=1` is set (they hit a shared, non-ephemeral test app).

## Source Of Truth: Admin SDK Ground Truth Scripts

The ground truth scripts live in `instantdb/scripts/` and query InstantDB directly using the JavaScript Admin SDK (`@instantdb/admin`).

High-signal improvements added:

- `--assert` exits non-zero when integrity checks fail (ordering, duplicates, missing links, grid holes, broadcast failures).
- `--json` emits a single machine-readable JSON object to stdout (logs go to stderr).
- `--settle-timeout-ms` / `--settle-interval-ms` poll until the backend is hydrated and checks pass.

These are now invoked from Swift tests in:

- `sharing-instant/Tests/SharingInstantTests/AdminSDKGroundTruthScriptTests.swift`

## Commands Run (Local)

From `sharing-instant/`:

1. Default (fast / deterministic)
   - `swift test -c debug`
   - Result: **0 failures**, **231 tests**, **48 skipped**

2. Ephemeral backend integration mode
   - `INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS=1 swift test -c debug`
   - Result: **0 failures**, **231 tests**, **24 skipped**

3. Shared-app integration mode
   - `INSTANT_RUN_INTEGRATION_TESTS=1 swift test -c debug`
   - Result: **0 failures**, **231 tests**, **25 skipped**

## High-Signal Changes Made

- **Deterministic auth for ephemeral apps**
  - Added `sharing-instant/Tests/SharingInstantTests/InstantTestAuth.swift` to make guest auth + reconnect explicit.
  - This avoids “connected but never init-ok” hangs when running against a brand-new ephemeral app ID.
- **Offline mode tests made deterministic**
  - `OfflineModeIntegrationTests` now signs in (guest) and reconnects before asserting on `.authenticated` / schema persistence.
  - Removed non-essential reconnect + cleanup work from `testQueryOnceFailsOfflineAndCarriesLastKnownResultWhenAvailable` to keep the test focused on the offline error contract.
- **Nested filtering test validates the server path**
  - `NestedFilteringIntegrationTests` now waits for an initial server emission and then validates the backend result via `queryOnce` (checking raw row IDs) to ensure the nested filter is applied server-side.
- **Stress tests no longer depend on `prepareDependencies`**
  - `EphemeralCaseStudiesStressTests` now scopes dependencies per test via `withDependencies`, which prevents cross-suite contamination and makes the stress suite stable when running the full test matrix.

## What “High Signal” Means Here

The high-signal strategy is:

1. **Admin SDK validates backend ground truth**
   - The Admin SDK runs the same logical queries, but through a separate implementation.
   - Failures here are strong evidence of backend/query ordering/broadcast issues.

2. **Swift tests validate client behavior**
   - Swift tests verify `@Shared` integration, hydration into the `TripleStore`, reverse-link decoding, multi-client propagation, offline mode, etc.

3. **Ephemeral isolation**
   - Tests that mutate data run against fresh ephemeral apps to eliminate cross-test pollution and flakiness from shared app IDs.

## Notable Observations

- Some tests are still skipped unless `INSTANT_RUN_INTEGRATION_TESTS=1` is set (see `sharing-instant/Tests/SharingInstantTests/IntegrationTestGate.swift`).
  - These are valuable “real backend on a shared app” checks, but they are not the default because shared state can reduce determinism.
- During the `AdminSDKGroundTruthScriptTests` run, the test process printed some CoreData/XPC warnings (e.g. “Failed to create NSXPCConnection”).
  - The tests still passed; this looks like an environmental log from the XCTest runner rather than a failing assertion.
- Several ephemeral suites require an authenticated WebSocket session. To keep them high-signal and deterministic, the tests now use a shared helper:
  - `sharing-instant/Tests/SharingInstantTests/InstantTestAuth.swift`
  - This signs in as a guest and forces a reconnect so the `init` message is sent with a refresh token before the test asserts on backend state.

## Follow-Ups (Optional, If You Want Even More Signal)

- Convert more `INSTANT_RUN_INTEGRATION_TESTS` suites to ephemeral apps where feasible to reduce skipped coverage and improve determinism.
- Replace fixed `Task.sleep(...)` waits in shared-app integration tests with “eventually” polling on concrete invariants (server-observed mutations, stable ordering, etc.).
- Consider a single `make verify` target that runs:
  - Admin SDK ground truth scripts (ephemeral + `--assert`)
  - Swift tests in ephemeral mode
