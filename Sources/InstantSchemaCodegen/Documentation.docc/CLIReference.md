# CLI Reference

Complete reference for the `instant-schema` command-line tool.

## Overview

The `instant-schema` CLI provides manual control over schema operations. While the SPM plugin handles most use cases automatically, the CLI is useful for:

- Pulling schemas from InstantDB
- Validating schemas before deployment
- Generating code manually
- Debugging schema issues

## Installation

The CLI is included in the sharing-instant package:

```bash
# Run directly with swift
swift run instant-schema --help

# Or build and use the binary
swift build -c release
.build/release/instant-schema --help
```

## Commands

### generate

Generate Swift code from a TypeScript schema or InstantDB API.

```bash
# From local file
instant-schema generate --from instant.schema.ts --to Sources/Generated/

# From InstantDB API
instant-schema generate \
  --app-id YOUR_APP_ID \
  --admin-token YOUR_TOKEN \
  --to Sources/Generated/
```

**Options:**
- `--from, -f <file>`: Input TypeScript schema file
- `--to, -t <dir>`: Output directory (default: `Sources/Generated/`)
- `--app-id, -a <id>`: InstantDB app ID
- `--admin-token <token>`: Admin token for API access

### pull

Fetch the deployed schema from InstantDB.

```bash
# Output as TypeScript
instant-schema pull \
  --app-id YOUR_APP_ID \
  --admin-token YOUR_TOKEN

# Save to file
instant-schema pull \
  --app-id YOUR_APP_ID \
  --admin-token YOUR_TOKEN \
  --output instant.schema.ts

# Output as raw JSON
instant-schema pull \
  --app-id YOUR_APP_ID \
  --admin-token YOUR_TOKEN \
  --json
```

**Options:**
- `--app-id, -a <id>`: InstantDB app ID (required)
- `--admin-token <token>`: Admin token (required)
- `--output, -o <file>`: Output file (prints to stdout if not specified)
- `--format <format>`: Output format: `typescript` (default) or `json`
- `--json`: Shorthand for `--format json`

### verify

Verify that your local schema matches the deployed schema.

```bash
instant-schema verify \
  --app-id YOUR_APP_ID \
  --admin-token YOUR_TOKEN \
  --local instant.schema.ts

# Fail with exit code 1 if schemas differ
instant-schema verify \
  --app-id YOUR_APP_ID \
  --admin-token YOUR_TOKEN \
  --local instant.schema.ts \
  --strict
```

**Options:**
- `--app-id, -a <id>`: InstantDB app ID (required)
- `--admin-token <token>`: Admin token (required)
- `--local, -l <file>`: Local schema file (required)
- `--strict`: Exit with error code 1 if schemas differ

**Output Example:**
```
🔍 Verifying schema...
   App ID: b9319949-2f2d-410b-8f8a-6990177c1d44
   Local:  instant.schema.ts

📖 Local schema: 5 entities, 3 links
📡 Deployed schema: 4 entities, 2 links

⚠️  Schema differences detected!

➕ New entities (not in deployed schema):
   - comments

➕ New fields (not in deployed schema):
   - todos.priority

➕ New links (not in deployed schema):
   - userComments

To resolve:
  • Run `npx instant-cli@latest push schema` to deploy local changes
  • Or run `instant-schema pull --app-id ... -o instant.schema.ts` to update local
```

### diff

Show differences between local and deployed schemas.

```bash
instant-schema diff \
  --app-id YOUR_APP_ID \
  --admin-token YOUR_TOKEN \
  --local instant.schema.ts
```

Same output as `verify` but without the resolution guidance.

### parse

Parse a schema file and display its structure.

```bash
instant-schema parse instant.schema.ts
```

**Output Example:**
```
Schema from instant.schema.ts:

Entities:
  todos (Todo)
    /// A todo item
    - title: String
    - done: Bool
    - createdAt: Date

Links:
  userTodos:
    forward: users.todos (has many)
    reverse: todos.owner (has one)
```

### print

Parse a schema and output it back as TypeScript (round-trip test).

```bash
instant-schema print instant.schema.ts
```

## Environment Variables

All commands support these environment variables:

| Variable | Description |
|----------|-------------|
| `INSTANT_APP_ID` | Default app ID for all commands |
| `INSTANT_ADMIN_TOKEN` | Admin token for API access |
| `INSTANT_SCHEMA_PATH` | Custom path to schema file |

**Example:**
```bash
export INSTANT_APP_ID="b9319949-2f2d-410b-8f8a-6990177c1d44"
export INSTANT_ADMIN_TOKEN="10c2aaea-5942-4e64-b105-3db598c14409"

# Now you can omit --app-id and --admin-token
instant-schema pull
instant-schema verify --local instant.schema.ts
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error (schema mismatch with --strict, parse error, etc.) |

## CI/CD Integration

### GitHub Actions

```yaml
- name: Verify Schema
  env:
    INSTANT_APP_ID: ${{ secrets.INSTANT_APP_ID }}
    INSTANT_ADMIN_TOKEN: ${{ secrets.INSTANT_ADMIN_TOKEN }}
  run: |
    swift run instant-schema verify --local instant.schema.ts --strict
```

### Pre-commit Hook

```bash
#!/bin/bash
# .git/hooks/pre-commit

if git diff --cached --name-only | grep -q "instant.schema.ts"; then
  echo "Schema changed - verifying..."
  swift run instant-schema verify \
    --app-id $INSTANT_APP_ID \
    --admin-token $INSTANT_ADMIN_TOKEN \
    --local instant.schema.ts \
    --strict
fi
```



