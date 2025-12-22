# Project Rules

## Integration Testing
- **Use Generated Entities**: Integration tests must use the auto-generated schema entities (e.g., via `instant-schema generate`). Do not manually define structs (like `private struct Board`) that mirror the schema in test files. This ensures tests validate the actual generated code used in the application.
