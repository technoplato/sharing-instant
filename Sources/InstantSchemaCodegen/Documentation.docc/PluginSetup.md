# SPM Build Plugin Setup

Configure automatic schema codegen on every build.

## Overview

The `InstantSchemaPlugin` is an SPM build tool plugin that automatically generates Swift types from your InstantDB schema. It runs **before** compilation, ensuring your types are always in sync.

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│                    Build Process                         │
├─────────────────────────────────────────────────────────┤
│  1. SPM starts build                                     │
│  2. InstantSchemaPlugin runs (pre-build)                │
│     ├─ Finds instant.schema.ts                          │
│     ├─ Runs instant-schema generate                     │
│     └─ Outputs Swift files to .build/plugins/           │
│  3. Swift compiler runs                                  │
│     └─ Includes generated files automatically           │
│  4. Build completes with type-safe schema!              │
└─────────────────────────────────────────────────────────┘
```

## Installation

### Step 1: Add Package Dependency

```swift
// Package.swift
let package = Package(
  name: "MyApp",
  dependencies: [
    .package(url: "https://github.com/instantdb/sharing-instant", from: "1.0.0"),
  ],
  // ...
)
```

### Step 2: Add Plugin to Target

```swift
.target(
  name: "MyApp",
  dependencies: [
    .product(name: "SharingInstant", package: "sharing-instant"),
  ],
  plugins: [
    .plugin(name: "InstantSchemaPlugin", package: "sharing-instant")
  ]
)
```

### Step 3: Create Schema File

Create `instant.schema.ts` in one of these locations:
- Project root: `./instant.schema.ts`
- Sources directory: `./Sources/instant.schema.ts`
- Target directory: `./Sources/MyApp/instant.schema.ts`

### Step 4: Build!

```bash
swift build
```

The plugin will:
1. Find your schema file
2. Generate Swift types
3. Include them in the build

## Configuration

### Custom Schema Path

Set the `INSTANT_SCHEMA_PATH` environment variable:

```bash
INSTANT_SCHEMA_PATH=./db/schema.ts swift build
```

### Xcode Projects

For Xcode projects (not SPM), the plugin also works:

1. Add the package to your Xcode project
2. Select your target → Build Phases → Run Build Tool Plug-ins
3. Add `InstantSchemaPlugin`

## Generated Files

The plugin generates files in `.build/plugins/outputs/`:

```
.build/plugins/outputs/MyApp/InstantSchemaPlugin/GeneratedSources/
├── Schema.swift       # Namespace with EntityKey instances
├── Todo.swift         # Entity struct
├── User.swift         # Entity struct
└── ...
```

These files are automatically included in compilation.

## Troubleshooting

### Plugin Doesn't Run

1. **Check schema file exists**: The plugin silently skips if no schema is found
2. **Check file location**: Must be in root, Sources/, or target directory
3. **Clean and rebuild**: `swift package clean && swift build`

### Generated Types Not Found

1. **Check build output**: Look for "InstantDB: Generating Swift types"
2. **Verify plugin is added**: Check your Package.swift
3. **Import the module**: Generated types are in your target's module

### Schema Changes Not Reflected

The plugin only regenerates when the schema file changes. To force:

```bash
rm -rf .build/plugins
swift build
```

## Best Practices

### 1. Commit Generated Files?

**No** - Generated files are in `.build/` which is gitignored. Every developer regenerates on build.

### 2. CI/CD

The plugin works automatically in CI. Just ensure:
- `instant.schema.ts` is committed
- No special configuration needed

### 3. Multiple Targets

Each target can have its own schema:

```
Sources/
├── App/
│   ├── instant.schema.ts  # App schema
│   └── ...
├── Admin/
│   ├── instant.schema.ts  # Admin schema (can be different)
│   └── ...
```

### 4. Monorepo Setup

For monorepos, use `INSTANT_SCHEMA_PATH`:

```swift
// In your CI script
export INSTANT_SCHEMA_PATH="../shared/instant.schema.ts"
swift build
```






