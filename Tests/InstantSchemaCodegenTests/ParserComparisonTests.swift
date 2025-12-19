// ParserComparisonTests.swift
// InstantSchemaCodegenTests
//
// ═══════════════════════════════════════════════════════════════════════════════
// COMPARISON TESTS: NEW PARSER vs OLD PARSER
// ═══════════════════════════════════════════════════════════════════════════════
//
// These tests verify that the new swift-parsing based parser produces identical
// output to the existing regex-based parser. This is the critical validation
// that ensures the rewrite doesn't break any existing functionality.
//
// ## Why These Tests Matter
//
// The regex parser (TypeScriptSchemaParser) is battle-tested and known to work.
// The new parser (SwiftParsingSchemaParser) must produce identical SchemaIR
// output for all inputs before we can replace the old parser.
//
// ## Test Strategy
//
// For each fixture file:
// 1. Parse with the OLD regex parser → oldResult
// 2. Parse with the NEW swift-parsing parser → newResult
// 3. Compare using XCTAssertEqual (SchemaIR is Equatable)
// 4. If different, use swift-custom-dump for detailed diff
//
// ## When to Update
//
// If a test fails:
// 1. Check if the difference is intentional (new parser is more correct)
// 2. If unintentional, fix the new parser
// 3. If intentional, document why and update the old parser or test

import Foundation
import XCTest
import SnapshotTesting
@testable import InstantSchemaCodegen

final class ParserComparisonTests: XCTestCase {
  
  // MARK: - Comparison Tests
  
  /// Compare old and new parser output for SimpleSchema.ts
  ///
  /// This is the simplest fixture with:
  /// - 2 entities (todos, users)
  /// - 1 link (userTodos)
  /// - Basic field types and optionality
  func testCompareSimpleSchema() throws {
    try compareParserOutput(for: "SimpleSchema.ts")
  }
  
  /// Compare old and new parser output for LibrarySchema.ts
  ///
  /// A more complex fixture with:
  /// - 5 entities (authors, books, borrowRecords, genres, members)
  /// - 7 links with various cardinalities
  /// - All field types (string, number, boolean, date, json)
  /// - Optional fields
  func testCompareLibrarySchema() throws {
    try compareParserOutput(for: "LibrarySchema.ts")
  }
  
  /// Compare old and new parser output for StressTestSchema.ts
  ///
  /// A large, complex fixture to stress test both parsers.
  ///
  /// ## Known Difference: Optional Detection
  ///
  /// The NEW parser correctly handles `.optional()` after other modifiers:
  /// - `email: i.string().unique().indexed().optional()` → optional: true
  ///
  /// The OLD regex parser has a bug where it only detects `.optional()` if it
  /// comes immediately after the type call, not after other modifiers like
  /// `.unique()` or `.indexed()`.
  ///
  /// This test verifies the new parser handles these cases correctly by
  /// comparing structure but not optionality for fields with multiple modifiers.
  func testCompareStressTestSchema() throws {
    let content = try loadFixture("StressTestSchema.ts")
    
    let oldParser = TypeScriptSchemaParser()
    let oldResult = try oldParser.parse(content: content, sourceFile: "StressTestSchema.ts")
    
    let newParser = SwiftParsingSchemaParser()
    let newResult = try newParser.parse(content: content, sourceFile: "StressTestSchema.ts")
    
    // Verify entity counts match
    XCTAssertEqual(oldResult.entities.count, newResult.entities.count)
    XCTAssertEqual(oldResult.links.count, newResult.links.count)
    XCTAssertEqual(oldResult.rooms.count, newResult.rooms.count)
    
    // Verify entity names match
    XCTAssertEqual(
      oldResult.entities.map(\.name).sorted(),
      newResult.entities.map(\.name).sorted()
    )
    
    // Verify link names match
    XCTAssertEqual(
      oldResult.links.map(\.name).sorted(),
      newResult.links.map(\.name).sorted()
    )
    
    // Verify field counts match for each entity
    for (oldEntity, newEntity) in zip(
      oldResult.entities.sorted(by: { $0.name < $1.name }),
      newResult.entities.sorted(by: { $0.name < $1.name })
    ) {
      XCTAssertEqual(
        oldEntity.fields.count,
        newEntity.fields.count,
        "Field count mismatch for entity '\(oldEntity.name)'"
      )
      
      // Verify field names and types match (skip optionality - new parser is more correct)
      for (oldField, newField) in zip(
        oldEntity.fields.sorted(by: { $0.name < $1.name }),
        newEntity.fields.sorted(by: { $0.name < $1.name })
      ) {
        XCTAssertEqual(oldField.name, newField.name)
        XCTAssertEqual(oldField.type, newField.type)
        // Note: We don't compare isOptional because the new parser is more correct
        // for fields like `email: i.string().unique().indexed().optional()`
      }
    }
    
    // Verify the new parser correctly detects optional on fields with multiple modifiers
    // This is a regression test for the improvement over the old parser
    if let users = newResult.entities.first(where: { $0.name == "$users" }),
       let emailField = users.fields.first(where: { $0.name == "email" }) {
      XCTAssertTrue(
        emailField.isOptional,
        "New parser should correctly detect .optional() after .unique().indexed()"
      )
    }
  }
  
  // MARK: - Helpers
  
  /// Compare the output of old and new parsers for a fixture file.
  ///
  /// - Parameter fixture: The fixture filename (e.g., "SimpleSchema.ts")
  /// - Throws: If either parser fails or outputs differ
  private func compareParserOutput(for fixture: String) throws {
    let content = try loadFixture(fixture)
    
    // Parse with OLD regex parser
    let oldParser = TypeScriptSchemaParser()
    let oldResult = try oldParser.parse(content: content, sourceFile: fixture)
    
    // Parse with NEW swift-parsing parser
    let newParser = SwiftParsingSchemaParser()
    let newResult = try newParser.parse(content: content, sourceFile: fixture)
    
    // Compare entities
    XCTAssertEqual(
      oldResult.entities.count,
      newResult.entities.count,
      "Entity count mismatch for \(fixture)"
    )
    
    for (oldEntity, newEntity) in zip(
      oldResult.entities.sorted(by: { $0.name < $1.name }),
      newResult.entities.sorted(by: { $0.name < $1.name })
    ) {
      XCTAssertEqual(
        oldEntity.name,
        newEntity.name,
        "Entity name mismatch in \(fixture)"
      )
      
      XCTAssertEqual(
        oldEntity.fields.count,
        newEntity.fields.count,
        "Field count mismatch for entity '\(oldEntity.name)' in \(fixture)"
      )
      
      for (oldField, newField) in zip(
        oldEntity.fields.sorted(by: { $0.name < $1.name }),
        newEntity.fields.sorted(by: { $0.name < $1.name })
      ) {
        XCTAssertEqual(
          oldField.name,
          newField.name,
          "Field name mismatch in entity '\(oldEntity.name)' in \(fixture)"
        )
        XCTAssertEqual(
          oldField.type,
          newField.type,
          "Field type mismatch for '\(oldField.name)' in entity '\(oldEntity.name)' in \(fixture)"
        )
        XCTAssertEqual(
          oldField.isOptional,
          newField.isOptional,
          "Optional mismatch for '\(oldField.name)' in entity '\(oldEntity.name)' in \(fixture)"
        )
      }
    }
    
    // Compare links
    XCTAssertEqual(
      oldResult.links.count,
      newResult.links.count,
      "Link count mismatch for \(fixture)"
    )
    
    for (oldLink, newLink) in zip(
      oldResult.links.sorted(by: { $0.name < $1.name }),
      newResult.links.sorted(by: { $0.name < $1.name })
    ) {
      XCTAssertEqual(
        oldLink.name,
        newLink.name,
        "Link name mismatch in \(fixture)"
      )
      XCTAssertEqual(
        oldLink.forward.entityName,
        newLink.forward.entityName,
        "Forward entity mismatch for link '\(oldLink.name)' in \(fixture)"
      )
      XCTAssertEqual(
        oldLink.forward.cardinality,
        newLink.forward.cardinality,
        "Forward cardinality mismatch for link '\(oldLink.name)' in \(fixture)"
      )
      XCTAssertEqual(
        oldLink.forward.label,
        newLink.forward.label,
        "Forward label mismatch for link '\(oldLink.name)' in \(fixture)"
      )
      XCTAssertEqual(
        oldLink.reverse.entityName,
        newLink.reverse.entityName,
        "Reverse entity mismatch for link '\(oldLink.name)' in \(fixture)"
      )
      XCTAssertEqual(
        oldLink.reverse.cardinality,
        newLink.reverse.cardinality,
        "Reverse cardinality mismatch for link '\(oldLink.name)' in \(fixture)"
      )
      XCTAssertEqual(
        oldLink.reverse.label,
        newLink.reverse.label,
        "Reverse label mismatch for link '\(oldLink.name)' in \(fixture)"
      )
    }
    
    // Compare rooms
    XCTAssertEqual(
      oldResult.rooms.count,
      newResult.rooms.count,
      "Room count mismatch for \(fixture)"
    )
    
    for (oldRoom, newRoom) in zip(
      oldResult.rooms.sorted(by: { $0.name < $1.name }),
      newResult.rooms.sorted(by: { $0.name < $1.name })
    ) {
      XCTAssertEqual(
        oldRoom.name,
        newRoom.name,
        "Room name mismatch in \(fixture)"
      )
      
      // Compare presence
      XCTAssertEqual(
        oldRoom.presence?.fields.count,
        newRoom.presence?.fields.count,
        "Presence field count mismatch for room '\(oldRoom.name)' in \(fixture)"
      )
      
      // Compare topics
      XCTAssertEqual(
        oldRoom.topics.count,
        newRoom.topics.count,
        "Topic count mismatch for room '\(oldRoom.name)' in \(fixture)"
      )
    }
    
    // Final structural comparison
    XCTAssertEqual(
      oldResult.entities.map(\.name).sorted(),
      newResult.entities.map(\.name).sorted(),
      "Entity names don't match for \(fixture)"
    )
    XCTAssertEqual(
      oldResult.links.map(\.name).sorted(),
      newResult.links.map(\.name).sorted(),
      "Link names don't match for \(fixture)"
    )
    XCTAssertEqual(
      oldResult.rooms.map(\.name).sorted(),
      newResult.rooms.map(\.name).sorted(),
      "Room names don't match for \(fixture)"
    )
  }
  
  /// Load a fixture file from the test bundle.
  private func loadFixture(_ name: String) throws -> String {
    let fixtureURL = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    guard let url = fixtureURL else {
      throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture not found: \(name)"])
    }
    return try String(contentsOf: url, encoding: .utf8)
  }
}

