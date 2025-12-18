# InstantDB Schema Codegen

Generate type-safe Swift code from your InstantDB schema automatically.

## Overview

InstantDB Schema Codegen provides bidirectional schema conversion between TypeScript and Swift, with automatic code generation on every build.

### Key Features

- **Bidirectional Parsing**: TypeScript ↔ Swift with comment preservation
- **API Integration**: Fetch deployed schemas directly from InstantDB
- **Schema Validation**: Verify local schema matches production
- **SPM Build Plugin**: Zero-config automatic codegen
- **CLI Tool**: Manual schema operations

## Quick Start

### 1. Add the Dependency

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/instantdb/sharing-instant", from: "1.0.0"),
]
```

### 2. Add the Plugin to Your Target

```swift
.target(
  name: "MyApp",
  dependencies: ["SharingInstant"],
  plugins: [
    .plugin(name: "InstantSchemaPlugin", package: "sharing-instant")
  ]
)
```

### 3. Create Your Schema

Create `instant.schema.ts` in your project root:

```typescript
import { i } from "@instantdb/core";

const _schema = i.schema({
  entities: {
    todos: i.entity({
      title: i.string(),
      done: i.boolean(),
      createdAt: i.date(),
    }),
  },
});

export type Schema = typeof _schema;
```

### 4. Build

Run `swift build` - the plugin automatically generates:

- `Schema.swift` - Namespace with EntityKey instances
- `Todo.swift` - Codable struct for the todos entity

## Topics

### Getting Started
- <doc:Installation>
- <doc:QuickStart>
- <doc:SchemaFormat>

### CLI Commands
- <doc:CLIPull>
- <doc:CLIGenerate>
- <doc:CLIVerify>

### Build Plugin
- <doc:PluginSetup>
- <doc:PluginConfiguration>

### Advanced
- <doc:BidirectionalCodegen>
- <doc:SchemaValidation>
- <doc:CustomPaths>



