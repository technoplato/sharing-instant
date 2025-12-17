# Schema Code Generation

Generate Swift types from your InstantDB schema.

## Overview

SharingInstant supports multiple approaches for keeping your Swift types in sync with your InstantDB schema:

1. **Manual Definition**: Define Swift types manually and ensure they match your schema
2. **Swift-First Generation**: Generate `instant.schema.json` from Swift types (existing)
3. **TypeScript-First Generation**: Generate Swift types from `instant.schema.ts` (planned)

## Current: Swift-First Approach

The `instant-ios-sdk` includes tools for generating InstantDB schema from Swift:

```bash
# Generate instant.schema.json from Swift schema file
swift package generate-schema
```

This uses the `@InstantEntity` macro or `InstantSchema` DSL:

```swift
// instant.schema.swift
import InstantDB

let schema = InstantSchema {
  Entity("todos")
    .field("title", .string)
    .field("done", .boolean)
    .field("createdAt", .date)
  
  Entity("users")
    .field("email", .string, .unique, .indexed)
    .field("name", .string)
}
```

## Planned: TypeScript-First Approach

For teams using `instant.schema.ts` as their source of truth, we plan to support generating Swift types automatically.

### instant.schema.ts Format

The canonical InstantDB schema format:

```typescript
// instant.schema.ts
import { i } from '@instantdb/react';

const _schema = i.schema({
  entities: {
    todos: i.entity({
      title: i.string(),
      done: i.boolean(),
      createdAt: i.date(),
    }),
    users: i.entity({
      email: i.string().unique().indexed(),
      name: i.string(),
    }),
  },
  links: {
    todoAuthor: {
      forward: { on: 'todos', has: 'one', label: 'author' },
      reverse: { on: 'users', has: 'many', label: 'todos' },
    },
  },
});
```

### Generated Swift Types

The code generator would produce:

```swift
// Generated from instant.schema.ts
// DO NOT EDIT - Regenerate with: npx instant-swift-codegen

import SharingInstant

struct Todo: EntityIdentifiable, Codable, Sendable {
  static var namespace: String { "todos" }
  
  var id: String
  var title: String
  var done: Bool
  var createdAt: Date
  
  // Link accessor
  var author: User?
}

struct User: EntityIdentifiable, Codable, Sendable {
  static var namespace: String { "users" }
  
  var id: String
  var email: String
  var name: String
  
  // Reverse link accessor
  var todos: [Todo]
}
```

## Implementation Options

### Option 1: Swift Package Plugin

A Swift Package Plugin that reads `instant.schema.ts` and generates Swift code:

```bash
swift package instant-codegen
```

**Pros:**
- Native Swift tooling
- Integrates with Xcode build process
- No Node.js dependency at build time

**Cons:**
- Need to parse TypeScript in Swift
- More complex implementation

### Option 2: Node.js CLI Tool

A Node.js tool that generates Swift from TypeScript:

```bash
npx instant-swift-codegen --input instant.schema.ts --output Sources/Models/
```

**Pros:**
- Can reuse existing TypeScript parser from InstantDB
- Easier to maintain alongside TypeScript SDK
- Full access to TypeScript type information

**Cons:**
- Requires Node.js installed
- Separate build step

### Option 3: Build Script Integration

A build script that runs during Xcode build:

```bash
# Run Phase Script
if [ -f "instant.schema.ts" ]; then
  npx instant-swift-codegen
fi
```

**Pros:**
- Automatic regeneration on schema changes
- Catches mismatches at build time

**Cons:**
- Slower builds
- Requires network for npx

## Type Mapping

| InstantDB Type | Swift Type |
|---------------|------------|
| `i.string()` | `String` |
| `i.number()` | `Double` |
| `i.boolean()` | `Bool` |
| `i.date()` | `Date` |
| `i.json()` | `[String: Any]` or custom Codable |
| `i.any()` | `AnyCodable` |
| `.optional()` | `Type?` |

## Link Generation

Links would generate relationship accessors:

```swift
// Forward link: todos -> author (has: one)
var author: User?

// Reverse link: users -> todos (has: many)  
var todos: [Todo]

// Many-to-many: posts <-> tags
var tags: [Tag]
```

## Schema Validation

The generated types would include runtime validation:

```swift
extension Todo {
  static func validateSchema(attributes: [Attribute]) -> Bool {
    SchemaValidation.validateNamespace(namespace, swiftType: "Todo", attributes: attributes)
    && SchemaValidation.validateAttribute("title", namespace: namespace, swiftType: "Todo", attributes: attributes)
    && SchemaValidation.validateAttribute("done", namespace: namespace, swiftType: "Todo", attributes: attributes)
    && SchemaValidation.validateAttribute("createdAt", namespace: namespace, swiftType: "Todo", attributes: attributes)
  }
}
```

## See Also

- <doc:Syncing>
- ``EntityIdentifiable``
- ``SchemaValidation``

