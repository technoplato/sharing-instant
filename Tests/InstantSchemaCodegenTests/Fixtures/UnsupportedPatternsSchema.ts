/**
 * Unsupported Patterns Schema
 * 
 * Test fixture demonstrating UNSUPPORTED generic type patterns.
 * The parser should detect these and provide helpful error messages.
 * 
 * This file is intentionally invalid - used to test error handling.
 */

import { i } from "@instantdb/core";

// =========================================================================
// UNSUPPORTED TYPE PATTERNS
// =========================================================================

// Intersection type - NOT SUPPORTED
type CombinedType = { a: string } & { b: number };

// Conditional type - NOT SUPPORTED
type ConditionalType<T> = T extends string ? "string" : "other";

// Mapped type - NOT SUPPORTED
type MappedType<T> = { [K in keyof T]: string };

// Template literal type - NOT SUPPORTED
type TemplateLiteralType = `prefix-${"a" | "b"}`;

// Generic with constraint - NOT SUPPORTED
type ConstrainedGeneric<T extends object> = T;

// =========================================================================
// SCHEMA WITH UNSUPPORTED PATTERNS
// =========================================================================

const _schema = i.schema({
  entities: {
    /**
     * Entity with unsupported type patterns.
     * Each field should trigger a specific error message.
     */
    unsupportedEntity: i.entity({
      /** Intersection type - should error */
      intersectionField: i.json<CombinedType>(),
      
      /** Unresolved type reference - should error */
      unresolvedType: i.string<NonExistentType>(),
    }),
  },
  links: {},
});

export type Schema = typeof _schema;


