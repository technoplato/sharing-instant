// GenericTypeCodegenTests.swift
// InstantSchemaCodegenTests
//
// ═══════════════════════════════════════════════════════════════════════════════
// TESTS FOR GENERIC TYPE SWIFT CODE GENERATION
// ═══════════════════════════════════════════════════════════════════════════════
//
// These tests verify Swift code generation from parsed generic types:
// - Enums for string unions
// - Structs for JSON objects
// - Arrays with proper typing
//
// ## TDD Approach
//
// These tests are written FIRST (before implementation) to define expected behavior.
// They will fail until the code generation is implemented.

import Foundation
import XCTest
import SnapshotTesting
@testable import InstantSchemaCodegen

final class GenericTypeCodegenTests: XCTestCase {

  // Enable recording mode to update snapshots
  // To record new snapshots, uncomment this method and run tests
  // override func invokeTest() {
  //   withSnapshotTesting(record: .all) {
  //     super.invokeTest()
  //   }
  // }

  // MARK: - Enum Generation Tests
  
  /// Test generating Swift enum from inline string union
  func testGenerateEnumFromInlineStringUnion() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    const _schema = i.schema({
      entities: {
        tasks: i.entity({
          status: i.string<"pending" | "active" | "completed">(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    // Should generate a Types.swift or include enum in Entities.swift
    let entitiesFile = files.first { $0.name == "Entities.swift" }!
    
    // Should contain enum definition
    XCTAssertTrue(entitiesFile.content.contains("enum TaskStatus: String, Codable, Sendable"),
                  "Should generate TaskStatus enum")
    XCTAssertTrue(entitiesFile.content.contains("case pending"))
    XCTAssertTrue(entitiesFile.content.contains("case active"))
    XCTAssertTrue(entitiesFile.content.contains("case completed"))
    
    // Entity should use the enum type
    XCTAssertTrue(entitiesFile.content.contains("var status: TaskStatus"))
  }
  
  /// Test generating Swift enum with snake_case conversion
  func testGenerateEnumWithSnakeCaseConversion() throws {
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
    
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    let entitiesFile = files.first { $0.name == "Entities.swift" }!
    
    // Swift cases should be camelCase with raw values for snake_case
    XCTAssertTrue(entitiesFile.content.contains("case inProgress = \"in_progress\""))
    XCTAssertTrue(entitiesFile.content.contains("case notStarted = \"not_started\""))
    XCTAssertTrue(entitiesFile.content.contains("case onHold = \"on_hold\""))
  }
  
  /// Test generating enum from type alias
  func testGenerateEnumFromTypeAlias() throws {
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
    
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    let entitiesFile = files.first { $0.name == "Entities.swift" }!
    
    // Should use the type alias name for the enum
    XCTAssertTrue(entitiesFile.content.contains("enum MediaType: String, Codable, Sendable"))
    XCTAssertTrue(entitiesFile.content.contains("var mediaType: MediaType"))
  }
  
  // MARK: - Struct Generation Tests
  
  /// Test generating Swift struct from inline JSON object
  func testGenerateStructFromInlineJsonObject() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    const _schema = i.schema({
      entities: {
        tasks: i.entity({
          metadata: i.json<{ createdBy: string, version: number, isActive: boolean }>(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    let entitiesFile = files.first { $0.name == "Entities.swift" }!
    
    // Should generate struct for the metadata type
    XCTAssertTrue(entitiesFile.content.contains("struct TaskMetadata: Codable, Sendable, Equatable"))
    XCTAssertTrue(entitiesFile.content.contains("var createdBy: String"))
    XCTAssertTrue(entitiesFile.content.contains("var version: Double"))
    XCTAssertTrue(entitiesFile.content.contains("var isActive: Bool"))
    
    // Entity should use the struct type
    XCTAssertTrue(entitiesFile.content.contains("var metadata: TaskMetadata"))
  }
  
  /// Test generating Swift struct from type alias
  func testGenerateStructFromTypeAlias() throws {
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
    
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    let entitiesFile = files.first { $0.name == "Entities.swift" }!
    
    // Should use the type alias name for the struct
    XCTAssertTrue(entitiesFile.content.contains("struct Timestamp: Codable, Sendable, Equatable"))
    XCTAssertTrue(entitiesFile.content.contains("var start: Double"))
    XCTAssertTrue(entitiesFile.content.contains("var end: Double"))
    
    // Entity should use the struct type
    XCTAssertTrue(entitiesFile.content.contains("var timestamp: Timestamp"))
  }
  
  /// Test generating struct with optional fields
  func testGenerateStructWithOptionalFields() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    const _schema = i.schema({
      entities: {
        tasks: i.entity({
          speaker: i.json<{ id: string, name: string, confidence?: number }>(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    let entitiesFile = files.first { $0.name == "Entities.swift" }!
    
    // Optional field should be Swift optional
    XCTAssertTrue(entitiesFile.content.contains("var confidence: Double?"))
    // Required fields should not be optional
    XCTAssertTrue(entitiesFile.content.contains("var id: String"))
    XCTAssertTrue(entitiesFile.content.contains("var name: String"))
  }
  
  // MARK: - Array Generation Tests
  
  /// Test generating array type from Type[] syntax
  func testGenerateArrayFromBracketSyntax() throws {
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
    
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    let entitiesFile = files.first { $0.name == "Entities.swift" }!
    
    // Should generate Word struct
    XCTAssertTrue(entitiesFile.content.contains("struct Word: Codable, Sendable, Equatable"))
    
    // Entity should use array type
    XCTAssertTrue(entitiesFile.content.contains("var words: [Word]"))
  }
  
  /// Test generating array type from Array<T> syntax
  func testGenerateArrayFromGenericSyntax() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    type Speaker = { id: string, name: string };
    
    const _schema = i.schema({
      entities: {
        recordings: i.entity({
          speakers: i.json<Array<Speaker>>(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    let entitiesFile = files.first { $0.name == "Entities.swift" }!
    
    // Should generate Speaker struct
    XCTAssertTrue(entitiesFile.content.contains("struct Speaker: Codable, Sendable, Equatable"))
    
    // Entity should use array type
    XCTAssertTrue(entitiesFile.content.contains("var speakers: [Speaker]"))
  }
  
  /// Test generating optional array
  func testGenerateOptionalArray() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    type Tag = { name: string };
    
    const _schema = i.schema({
      entities: {
        posts: i.entity({
          tags: i.json<Tag[]>().optional(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    let entitiesFile = files.first { $0.name == "Entities.swift" }!
    
    // Optional array should be [Type]?
    XCTAssertTrue(entitiesFile.content.contains("var tags: [Tag]?"))
  }
  
  // MARK: - Nested Type Generation Tests
  
  /// Test generating nested struct types
  func testGenerateNestedStructs() throws {
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
    
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    let entitiesFile = files.first { $0.name == "Entities.swift" }!
    
    // Should generate nested struct
    XCTAssertTrue(entitiesFile.content.contains("struct TranscriptionMetadata"))
    XCTAssertTrue(entitiesFile.content.contains("struct TranscriptionMetadataTimestamps") ||
                  entitiesFile.content.contains("struct Timestamps"))
  }
  
  // MARK: - Snapshot Tests
  
  /// Snapshot test for GenericTypesSchema.ts generated code
  func testSwiftGenerationGenericTypesSchemaSnapshot() throws {
    let schema = try parseFixture("GenericTypesSchema.ts")
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    // Snapshot test each generated file
    for file in files {
      let stableContent = removeTimestamp(from: file.content)
      assertSnapshot(of: stableContent, as: .lines, named: "GenericTypes-\(file.name)")
    }
  }
  
  // MARK: - Deduplication Tests
  
  /// Test that identical types are not duplicated
  func testDeduplicateIdenticalTypes() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    type Timestamp = { start: number, end: number };
    
    const _schema = i.schema({
      entities: {
        segments: i.entity({
          timestamp: i.json<Timestamp>(),
        }),
        markers: i.entity({
          timestamp: i.json<Timestamp>(),
        }),
      },
      links: {},
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    let entitiesFile = files.first { $0.name == "Entities.swift" }!
    
    // Timestamp struct should only appear once
    let matches = entitiesFile.content.components(separatedBy: "struct Timestamp:").count - 1
    XCTAssertEqual(matches, 1, "Timestamp struct should only be defined once")
  }
  
  // MARK: - Helpers
  
  private func parseFixture(_ name: String) throws -> SchemaIR {
    let fixtureURL = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    guard let url = fixtureURL else {
      throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture not found: \(name)"])
    }
    
    let content = try String(contentsOf: url, encoding: .utf8)
    let parser = TypeScriptSchemaParser()
    return try parser.parse(content: content, sourceFile: url.path)
  }
  
  private func removeTimestamp(from content: String) -> String {
    let lines = content.components(separatedBy: "\n")
    return lines.filter { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.contains("// 20") { return false }
      if trimmed.hasPrefix("/// Generated:") { return false }
      if trimmed.hasPrefix("/// Machine:") { return false }
      if trimmed.hasPrefix("/// Generator:") { return false }
      if trimmed.hasPrefix("/// Source Schema:") { return false }
      if trimmed.hasPrefix("/// HEAD Commit:") { return false }
      if trimmed.hasPrefix("/// Schema File Last Modified:") { return false }
      if trimmed.hasPrefix("///   SHA:") { return false }
      if trimmed.hasPrefix("///   Date:") { return false }
      if trimmed.hasPrefix("///   Author:") { return false }
      if trimmed.hasPrefix("///   Message:") { return false }
      if trimmed.hasPrefix("/* To regenerate") { return false }
      if trimmed.hasPrefix("swift run instant-schema") { return false }
      if trimmed.hasPrefix("--from") { return false }
      if trimmed.hasPrefix("--to") { return false }
      return true
    }.joined(separator: "\n")
  }
}






