# Storage

Upload, delete, and generate download links for files stored in InstantDB.

## Overview

InstantDB supports file storage in the special `$files` system namespace. The core Swift SDK
(`instant-ios-sdk`) exposes the raw HTTP endpoints on `InstantClient.storage`.

SharingInstant adds ``InstantStorage`` as an ergonomic, SwiftUI-friendly coordinator that:

- Exposes mutation-style state you can switch on (idle / in-flight / success / failure)
- Provides async APIs for structured concurrency
- Provides callback-style APIs for synchronous contexts (e.g. SwiftUI `Button` actions)

## Permissions (`$files`)

Storage is gated by permissions. If your app has no `$files` rules, the server denies access
by default.

A common pattern is to scope file access to the signed-in user's prefix:

```ts
// instant.perms.ts
export default {
  "$files": {
    allow: {
      view: "isOwner",
      create: "isOwner",
      delete: "isOwner",
    },
    bind: [
      "isOwner",
      "auth.id != null && data.path.startsWith(auth.id + '/')",
    ],
  },
} satisfies InstantRules;
```

## Basic Usage (SwiftUI)

```swift
import SharingInstant
import SwiftUI

struct AvatarUploader: View {
  @StateObject private var auth = InstantAuth()
  @StateObject private var storage = InstantStorage()

  let pngData: Data

  var body: some View {
    VStack(spacing: 12) {
      switch storage.uploadState {
      case .idle:
        Text("Ready")
      case .inFlight:
        ProgressView("Uploading…")
      case .success(let uploaded, _):
        Text("Uploaded: \(uploaded.path)")
      case .failure(let error, _):
        Text("Upload failed: \(error.localizedDescription)")
      }

      Button("Upload Avatar") {
        guard let userId = auth.user?.id else { return }
        let path = "\(userId)/avatars/me.png"

        storage.uploadFile(
          path: path,
          data: pngData,
          options: .init(contentType: "image/png")
        ) { _ in }
      }
    }
    .instantAuth(auth)
    .instantStorage(storage)
  }
}
```

## File Handles

If you prefer to bind a storage path once, use a file handle:

```swift
let avatar = storage.file("\(user.id)/avatars/me.png")
try await avatar.upload(data: pngData, options: .init(contentType: "image/png"))
let url = try await avatar.link()
try await avatar.delete()
```

