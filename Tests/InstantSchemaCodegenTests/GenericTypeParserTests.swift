// GenericTypeParserTests.swift
// InstantSchemaCodegenTests
//
// ═══════════════════════════════════════════════════════════════════════════════
// TESTS FOR GENERIC TYPE PARSING
// ═══════════════════════════════════════════════════════════════════════════════
//
// These tests verify parsing of TypeScript generics in InstantDB schemas:
// - String unions: i.string<"a" | "b" | "c">()
// - Type aliases: type Status = "a" | "b"; i.string<Status>()
// - Imports: import { Type } from "./file"; i.string<Type>()
// - JSON objects: i.json<{ field: type }>()
// - Arrays: i.json<Type[]>() and i.json<Array<Type>>()
//
// ## TDD Approach
//
// These tests are written FIRST (before implementation) to define expected behavior.
// They will fail until the generic type parsing is implemented.

import Foundation
import XCTest
import SnapshotTesting
@testable import InstantSchemaCodegen

final class GenericTypeParserTests: XCTestCase {
  
  // MARK: - Inline String Union Tests
  
  /// Test parsing inline string union: i.string<"pending" | "active" | "done">()
  func testParseInlineStringUnion() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    const _schema = i.schema({
      entities: {
        tasks: i.entity({
          status: i.string<"pending" | "active" | "done">(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let tasks = schema.entities.first { $0.name == "tasks" }!
    let statusField = tasks.fields.first { $0.name == "status" }!
    
    // Should have a string union generic type
    XCTAssertEqual(statusField.type, .string)
    XCTAssertNotNil(statusField.genericType, "Should have generic type information")
    
    guard case .stringUnion(let cases) = statusField.genericType else {
      XCTFail("Expected string union generic type")
      return
    }
    
    XCTAssertEqual(cases.sorted(), ["active", "done", "pending"])
  }
  
  /// Test parsing string union with snake_case values
  func testParseStringUnionWithSnakeCase() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    const _schema = i.schema({
      entities: {
        tasks: i.entity({
          status: i.string<"in_progress" | "not_started" | "on_hold">(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let tasks = schema.entities.first { $0.name == "tasks" }!
    let statusField = tasks.fields.first { $0.name == "status" }!
    
    guard case .stringUnion(let cases) = statusField.genericType else {
      XCTFail("Expected string union generic type")
      return
    }
    
    XCTAssertEqual(cases.sorted(), ["in_progress", "not_started", "on_hold"])
  }
  
  // MARK: - Type Alias Tests (Same File)
  
  /// Test parsing type alias defined in same file
  func testParseTypeAliasFromSameFile() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    type TaskStatus = "pending" | "in_progress" | "completed";
    
    const _schema = i.schema({
      entities: {
        tasks: i.entity({
          status: i.string<TaskStatus>(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let tasks = schema.entities.first { $0.name == "tasks" }!
    let statusField = tasks.fields.first { $0.name == "status" }!
    
    // Type alias should be resolved to string union (unwrap the typeAlias wrapper)
    guard case .stringUnion(let cases) = statusField.genericType?.unwrapped else {
      XCTFail("Expected string union generic type (resolved from alias)")
      return
    }
    
    XCTAssertEqual(cases.sorted(), ["completed", "in_progress", "pending"])
  }
  
  /// Test parsing exported type alias
  func testParseExportedTypeAlias() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    export type MediaType = "audio" | "video" | "text";
    
    const _schema = i.schema({
      entities: {
        media: i.entity({
          mediaType: i.string<MediaType>(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let media = schema.entities.first { $0.name == "media" }!
    let mediaTypeField = media.fields.first { $0.name == "mediaType" }!
    
    guard case .stringUnion(let cases) = mediaTypeField.genericType?.unwrapped else {
      XCTFail("Expected string union generic type")
      return
    }
    
    XCTAssertEqual(cases.sorted(), ["audio", "text", "video"])
  }
  
  // MARK: - Import Resolution Tests
  
  /// Test parsing type alias imported from another file
  func testParseImportedTypeAlias() throws {
    // This test requires the ImportedTypes.ts fixture to exist
    let schema = try parseFixture("GenericTypesSchema.ts")
    
    let tasks = schema.entities.first { $0.name == "tasks" }!
    let priorityField = tasks.fields.first { $0.name == "priority" }!
    
    // Should resolve TaskPriority from ImportedTypes.ts (unwrap the typeAlias wrapper)
    guard case .stringUnion(let cases) = priorityField.genericType?.unwrapped else {
      XCTFail("Expected string union generic type (resolved from import)")
      return
    }
    
    XCTAssertEqual(cases.sorted(), ["high", "low", "medium", "urgent"])
  }
  
  // MARK: - Inline JSON Object Tests
  
  /// Test parsing inline JSON object type
  func testParseInlineJsonObject() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    const _schema = i.schema({
      entities: {
        tasks: i.entity({
          metadata: i.json<{ createdBy: string, version: number }>(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let tasks = schema.entities.first { $0.name == "tasks" }!
    let metadataField = tasks.fields.first { $0.name == "metadata" }!
    
    XCTAssertEqual(metadataField.type, .json)
    
    guard case .object(let fields) = metadataField.genericType else {
      XCTFail("Expected object generic type")
      return
    }
    
    XCTAssertEqual(fields.count, 2)
    XCTAssertTrue(fields.contains { $0.name == "createdBy" && $0.type == .string })
    XCTAssertTrue(fields.contains { $0.name == "version" && $0.type == .number })
  }
  
  /// Test parsing JSON object with optional fields
  func testParseJsonObjectWithOptionalFields() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    const _schema = i.schema({
      entities: {
        tasks: i.entity({
          speaker: i.json<{ id: string, name: string, confidence?: number }>().optional(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let tasks = schema.entities.first { $0.name == "tasks" }!
    let speakerField = tasks.fields.first { $0.name == "speaker" }!
    
    XCTAssertTrue(speakerField.isOptional)
    
    guard case .object(let fields) = speakerField.genericType else {
      XCTFail("Expected object generic type")
      return
    }
    
    XCTAssertEqual(fields.count, 3)
    
    let confidenceField = fields.first { $0.name == "confidence" }!
    XCTAssertTrue(confidenceField.isOptional)
  }
  
  // MARK: - JSON Object Type Alias Tests
  
  /// Test parsing JSON object from type alias
  func testParseJsonObjectTypeAlias() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    type Timestamp = {
      start: number;
      end: number;
    };
    
    const _schema = i.schema({
      entities: {
        segments: i.entity({
          timestamp: i.json<Timestamp>(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let segments = schema.entities.first { $0.name == "segments" }!
    let timestampField = segments.fields.first { $0.name == "timestamp" }!
    
    // Unwrap the typeAlias wrapper to get the underlying object type
    guard case .object(let fields) = timestampField.genericType?.unwrapped else {
      XCTFail("Expected object generic type (resolved from alias)")
      return
    }
    
    XCTAssertEqual(fields.count, 2)
    XCTAssertTrue(fields.contains { $0.name == "start" && $0.type == .number })
    XCTAssertTrue(fields.contains { $0.name == "end" && $0.type == .number })
  }
  
  // MARK: - Array Type Tests
  
  /// Test parsing array with bracket syntax: Type[]
  func testParseArrayBracketSyntax() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    type Word = { text: string, start: number, end: number };
    
    const _schema = i.schema({
      entities: {
        transcriptions: i.entity({
          words: i.json<Word[]>(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let transcriptions = schema.entities.first { $0.name == "transcriptions" }!
    let wordsField = transcriptions.fields.first { $0.name == "words" }!
    
    guard case .array(let elementType) = wordsField.genericType else {
      XCTFail("Expected array generic type")
      return
    }
    
    // Unwrap the typeAlias wrapper to get the underlying object type
    guard case .object(let fields) = elementType.unwrapped else {
      XCTFail("Expected object element type")
      return
    }
    
    XCTAssertEqual(fields.count, 3)
  }
  
  /// Test parsing array with Array<T> syntax
  func testParseArrayGenericSyntax() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    type Word = { text: string, start: number, end: number };
    
    const _schema = i.schema({
      entities: {
        transcriptions: i.entity({
          words: i.json<Array<Word>>(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let transcriptions = schema.entities.first { $0.name == "transcriptions" }!
    let wordsField = transcriptions.fields.first { $0.name == "words" }!
    
    guard case .array(let elementType) = wordsField.genericType else {
      XCTFail("Expected array generic type")
      return
    }
    
    // Unwrap the typeAlias wrapper to get the underlying object type
    guard case .object(let fields) = elementType.unwrapped else {
      XCTFail("Expected object element type")
      return
    }
    
    XCTAssertEqual(fields.count, 3)
  }
  
  /// Test parsing inline array of objects
  func testParseInlineArrayOfObjects() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    const _schema = i.schema({
      entities: {
        transcriptions: i.entity({
          timestamps: i.json<{ start: number, end: number }[]>(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let transcriptions = schema.entities.first { $0.name == "transcriptions" }!
    let timestampsField = transcriptions.fields.first { $0.name == "timestamps" }!
    
    guard case .array(let elementType) = timestampsField.genericType else {
      XCTFail("Expected array generic type")
      return
    }
    
    guard case .object(let fields) = elementType else {
      XCTFail("Expected object element type")
      return
    }
    
    XCTAssertEqual(fields.count, 2)
  }
  
  // MARK: - Nested Object Tests
  
  /// Test parsing nested object types
  func testParseNestedObjects() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    const _schema = i.schema({
      entities: {
        transcriptions: i.entity({
          metadata: i.json<{
            source: string,
            timestamps: { start: number, end: number }
          }>(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let transcriptions = schema.entities.first { $0.name == "transcriptions" }!
    let metadataField = transcriptions.fields.first { $0.name == "metadata" }!
    
    guard case .object(let fields) = metadataField.genericType else {
      XCTFail("Expected object generic type")
      return
    }
    
    XCTAssertEqual(fields.count, 2)
    
    let timestampsField = fields.first { $0.name == "timestamps" }!
    guard case .object(let nestedFields) = timestampsField.genericType else {
      XCTFail("Expected nested object type")
      return
    }
    
    XCTAssertEqual(nestedFields.count, 2)
  }
  
  // MARK: - Error Handling Tests
  
  /// Test error for unresolved type reference
  func testErrorOnUnresolvedTypeReference() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    const _schema = i.schema({
      entities: {
        tasks: i.entity({
          status: i.string<NonExistentType>(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    
    XCTAssertThrowsError(try parser.parse(content: schemaContent)) { error in
      let description = error.localizedDescription
      XCTAssertTrue(description.contains("NonExistentType"), "Error should mention the unresolved type")
      XCTAssertTrue(description.contains("status"), "Error should mention the field name")
    }
  }
  
  /// Test error for intersection types (unsupported)
  func testErrorOnIntersectionType() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    type TypeA = { a: string };
    type TypeB = { b: number };
    type Combined = TypeA & TypeB;
    
    const _schema = i.schema({
      entities: {
        items: i.entity({
          data: i.json<Combined>(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    
    XCTAssertThrowsError(try parser.parse(content: schemaContent)) { error in
      let description = error.localizedDescription
      XCTAssertTrue(description.contains("intersection") || description.contains("&"),
                    "Error should mention intersection types are unsupported")
    }
  }
  
  // MARK: - Snapshot Tests
  
  /// Snapshot test for GenericTypesSchema.ts parsed result
  func testParseGenericTypesSchemaIRSnapshot() throws {
    let schema = try parseFixture("GenericTypesSchema.ts")
    assertSnapshot(of: schema, as: .dump)
  }
  
  // MARK: - Helpers
  
  private func parseFixture(_ name: String) throws -> SchemaIR {
    let fixtureURL = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    guard let url = fixtureURL else {
      throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture not found: \(name)"])
    }
    
    let content = try String(contentsOf: url, encoding: .utf8)
    let parser = TypeScriptSchemaParser()
    
    // For import resolution, we need to provide the source file path
    return try parser.parse(content: content, sourceFile: url.path)
  }
}






