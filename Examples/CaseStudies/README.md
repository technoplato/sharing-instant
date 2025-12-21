# SharingInstant Case Studies

A collection of examples demonstrating SharingInstant features.

## Running the Examples

1. Open the `Examples.xcodeproj` in Xcode
2. Select the CaseStudies target
3. Run on a simulator or device

The examples use a test InstantDB app (`b9319949-2f2d-410b-8f8a-6990177c1d44`) for demonstration purposes.

## Examples

### Query Demo

Demonstrates read-only queries using `@SharedReader` with `.instantQuery`. Shows how to:
- Fetch data from InstantDB
- Automatically receive real-time updates
- Display data in SwiftUI views

### Sync Demo

Demonstrates bidirectional sync using `@Shared` with `.instantSync`. Shows how to:
- Add, edit, and delete items
- Apply optimistic updates
- Handle real-time sync across devices

### Observable Model Demo

Demonstrates using SharingInstant with `@Observable` models. Shows how to:
- Use `@ObservationIgnored @Shared` pattern
- Encapsulate business logic in view models
- Combine observation with real-time sync

## Test App Details

- **App ID**: `b9319949-2f2d-410b-8f8a-6990177c1d44`
- **App Name**: `test_sharing-instant`
- **Dashboard**: https://www.instantdb.com/dash?app=b9319949-2f2d-410b-8f8a-6990177c1d44






