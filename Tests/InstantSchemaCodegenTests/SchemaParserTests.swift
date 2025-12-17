// SchemaParserTests.swift
// InstantSchemaCodegenTests

import Foundation
import XCTest
@testable import InstantSchemaCodegen

final class SchemaParserTests: XCTestCase {
  
  // MARK: - Parse Tests
  
  func testParseSimpleSchema() throws {
    let schema = try parseFixture("SimpleSchema.ts")
    
    // Verify entities
    XCTAssertEqual(schema.entities.count, 2)
    XCTAssertEqual(schema.entities.map(\.name).sorted(), ["todos", "users"])
    
    // Verify todos fields
    let todos = schema.entities.first { $0.name == "todos" }!
    XCTAssertEqual(todos.fields.count, 3)
    XCTAssertEqual(todos.fields.map(\.name).sorted(), ["done", "priority", "title"])
    
    // Verify field types
    let titleField = todos.fields.first { $0.name == "title" }!
    XCTAssertEqual(titleField.type, .string)
    XCTAssertFalse(titleField.isOptional)
    
    let priorityField = todos.fields.first { $0.name == "priority" }!
    XCTAssertEqual(priorityField.type, .number)
    XCTAssertTrue(priorityField.isOptional)
    
    // Verify links
    XCTAssertEqual(schema.links.count, 1)
    let link = schema.links[0]
    XCTAssertEqual(link.name, "userTodos")
    XCTAssertEqual(link.forward.entityName, "users")
    XCTAssertEqual(link.forward.cardinality, .many)
    XCTAssertEqual(link.reverse.entityName, "todos")
    XCTAssertEqual(link.reverse.cardinality, .one)
  }
  
  func testParseLibrarySchema() throws {
    let schema = try parseFixture("LibrarySchema.ts")
    
    // Verify all entities
    let entityNames = schema.entities.map(\.name).sorted()
    XCTAssertEqual(entityNames, ["authors", "books", "borrowRecords", "genres", "members"])
    
    // Verify all links
    let linkNames = schema.links.map(\.name).sorted()
    XCTAssertEqual(linkNames, [
      "authorBooks",
      "bookBorrower",
      "bookGenres",
      "borrowRecordBook",
      "borrowRecordMember",
      "memberFavoriteAuthor",
      "memberGenreInterests"
    ])
    
    // Verify members entity has all fields
    let members = schema.entities.first { $0.name == "members" }!
    XCTAssertEqual(members.fields.count, 7)
    
    // Verify field types
    let fieldTypes = Dictionary(uniqueKeysWithValues: members.fields.map { ($0.name, $0.type) })
    XCTAssertEqual(fieldTypes["name"], .string)
    XCTAssertEqual(fieldTypes["email"], .string)
    XCTAssertEqual(fieldTypes["memberSince"], .date)
    XCTAssertEqual(fieldTypes["isActive"], .boolean)
    XCTAssertEqual(fieldTypes["currentBorrowCount"], .number)
    XCTAssertEqual(fieldTypes["preferences"], .json)
    
    // Verify optional fields
    let optionalFields = members.fields.filter(\.isOptional).map(\.name).sorted()
    XCTAssertEqual(optionalFields, ["phoneNumber", "preferences"])
  }
  
  func testParseStressTestSchema() throws {
    let schema = try parseFixture("StressTestSchema.ts")
    
    // Should have many entities
    XCTAssertGreaterThan(schema.entities.count, 5, "Stress test should have many entities")
    
    // Verify it parses without errors
    try schema.validate()
    
    // Print summary for manual verification
    print("Parsed stress test schema:")
    print("  Entities: \(schema.entities.count)")
    print("  Links: \(schema.links.count)")
    print("  Entity names: \(schema.entities.map(\.name).sorted().joined(separator: ", "))")
  }
  
  // MARK: - Documentation Preservation Tests
  
  func testDocumentationExtraction() throws {
    let schema = try parseFixture("SimpleSchema.ts")
    
    // Entity documentation
    let todos = schema.entities.first { $0.name == "todos" }!
    XCTAssertNotNil(todos.documentation)
    XCTAssertTrue(todos.documentation?.contains("todo item") ?? false)
  }
  
  // MARK: - Round-Trip Tests
  
  func testRoundTrip() throws {
    let original = try parseFixture("SimpleSchema.ts")
    
    // Print to TypeScript
    let printer = TypeScriptSchemaPrinter()
    let output = printer.print(original)
    
    // Parse again
    let parser = TypeScriptSchemaParser()
    let reparsed = try parser.parse(content: output)
    
    // Verify structure matches
    XCTAssertEqual(original.entities.count, reparsed.entities.count)
    XCTAssertEqual(original.links.count, reparsed.links.count)
    
    for (e1, e2) in zip(original.entities.sorted(by: { $0.name < $1.name }),
                        reparsed.entities.sorted(by: { $0.name < $1.name })) {
      XCTAssertEqual(e1.name, e2.name, "Entity names should match")
      XCTAssertEqual(e1.fields.count, e2.fields.count, "Field counts should match for \(e1.name)")
      
      for (f1, f2) in zip(e1.fields.sorted(by: { $0.name < $1.name }),
                          e2.fields.sorted(by: { $0.name < $1.name })) {
        XCTAssertEqual(f1.name, f2.name, "Field names should match")
        XCTAssertEqual(f1.type, f2.type, "Field types should match for \(f1.name)")
        XCTAssertEqual(f1.isOptional, f2.isOptional, "Optional flag should match for \(f1.name)")
      }
    }
    
    for (l1, l2) in zip(original.links.sorted(by: { $0.name < $1.name }),
                        reparsed.links.sorted(by: { $0.name < $1.name })) {
      XCTAssertEqual(l1.name, l2.name, "Link names should match")
      XCTAssertEqual(l1.forward.entityName, l2.forward.entityName)
      XCTAssertEqual(l1.forward.cardinality, l2.forward.cardinality)
      XCTAssertEqual(l1.reverse.entityName, l2.reverse.entityName)
      XCTAssertEqual(l1.reverse.cardinality, l2.reverse.cardinality)
    }
  }
  
  func testRoundTripLibrarySchema() throws {
    let original = try parseFixture("LibrarySchema.ts")
    
    let printer = TypeScriptSchemaPrinter()
    let output = printer.print(original)
    
    let parser = TypeScriptSchemaParser()
    let reparsed = try parser.parse(content: output)
    
    XCTAssertEqual(original.entities.count, reparsed.entities.count)
    XCTAssertEqual(original.links.count, reparsed.links.count)
  }
  
  // MARK: - Swift Generation Tests
  
  func testSwiftGeneration() throws {
    let schema = try parseFixture("SimpleSchema.ts")
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    // Should generate files
    XCTAssertGreaterThan(files.count, 0)
    
    // Print generated code for review
    for file in files {
      print("=== \(file.name) ===")
      print(file.content.prefix(500))
      print("...")
    }
    
    // Verify Schema.swift exists
    let schemaFile = files.first { $0.name == "Schema.swift" }
    XCTAssertNotNil(schemaFile, "Should generate Schema.swift")
    
    // Verify entity files exist
    let todoFile = files.first { $0.name == "Todo.swift" }
    XCTAssertNotNil(todoFile, "Should generate Todo.swift")
    
    let userFile = files.first { $0.name == "User.swift" }
    XCTAssertNotNil(userFile, "Should generate User.swift")
  }
  
  // MARK: - Validation Tests
  
  func testValidationRejectsDuplicateEntities() throws {
    var schema = SchemaIR()
    schema.entities = [
      EntityIR(name: "todos", fields: []),
      EntityIR(name: "todos", fields: []),
    ]
    
    XCTAssertThrowsError(try schema.validate()) { error in
      XCTAssertTrue(error.localizedDescription.contains("Duplicate"))
    }
  }
  
  func testValidationRejectsUnknownEntityInLink() throws {
    var schema = SchemaIR()
    schema.entities = [
      EntityIR(name: "todos", fields: []),
    ]
    schema.links = [
      LinkIR(
        name: "userTodos",
        forward: LinkSide(entityName: "users", cardinality: .many, label: "todos"),
        reverse: LinkSide(entityName: "todos", cardinality: .one, label: "owner")
      ),
    ]
    
    XCTAssertThrowsError(try schema.validate()) { error in
      XCTAssertTrue(error.localizedDescription.contains("unknown entity"))
    }
  }
  
  // MARK: - Type Mapping Tests
  
  func testSwiftTypeName() {
    XCTAssertEqual(EntityIR(name: "todos").swiftTypeName, "Todo")
    XCTAssertEqual(EntityIR(name: "users").swiftTypeName, "User")
    XCTAssertEqual(EntityIR(name: "borrowRecords").swiftTypeName, "BorrowRecord")
    XCTAssertEqual(EntityIR(name: "genre").swiftTypeName, "Genre")
    XCTAssertEqual(EntityIR(name: "people").swiftTypeName, "Person")
    XCTAssertEqual(EntityIR(name: "media").swiftTypeName, "Media")
  }
  
  func testFieldTypeMapping() {
    // Swift types
    XCTAssertEqual(FieldType.string.swiftType, "String")
    XCTAssertEqual(FieldType.number.swiftType, "Double")
    XCTAssertEqual(FieldType.boolean.swiftType, "Bool")
    XCTAssertEqual(FieldType.date.swiftType, "Date")
    XCTAssertEqual(FieldType.json.swiftType, "AnyCodable")
    
    // TypeScript types
    XCTAssertEqual(FieldType.string.typeScriptType, "string")
    XCTAssertEqual(FieldType.number.typeScriptType, "number")
    XCTAssertEqual(FieldType.boolean.typeScriptType, "boolean")
    XCTAssertEqual(FieldType.date.typeScriptType, "Date")
    XCTAssertEqual(FieldType.json.typeScriptType, "any")
    
    // InstantDB builders
    XCTAssertEqual(FieldType.string.instantDBBuilder, "i.string()")
    XCTAssertEqual(FieldType.number.instantDBBuilder, "i.number()")
    XCTAssertEqual(FieldType.boolean.instantDBBuilder, "i.boolean()")
    XCTAssertEqual(FieldType.date.instantDBBuilder, "i.date()")
    XCTAssertEqual(FieldType.json.instantDBBuilder, "i.json()")
  }
  
  // MARK: - Helpers
  
  private func parseFixture(_ name: String) throws -> SchemaIR {
    let fixtureURL = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    guard let url = fixtureURL else {
      throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture not found: \(name)"])
    }
    
    let content = try String(contentsOf: url, encoding: .utf8)
    let parser = TypeScriptSchemaParser()
    return try parser.parse(content: content, sourceFile: name)
  }
}
