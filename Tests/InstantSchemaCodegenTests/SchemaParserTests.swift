// SchemaParserTests.swift
// InstantSchemaCodegenTests

import Foundation
import XCTest
import SnapshotTesting
@testable import InstantSchemaCodegen

final class SchemaParserTests: XCTestCase {
  
  // Enable recording mode to update snapshots
  // override func invokeTest() {
  //   isRecording = true
  //   super.invokeTest()
  // }
  
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
  
  // MARK: - Swift Generation Snapshot Tests
  
  func testSwiftGenerationSnapshot() throws {
    let schema = try parseFixture("SimpleSchema.ts")
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    // Should generate files
    XCTAssertGreaterThan(files.count, 0)
    
    // Verify expected files exist
    let schemaFile = files.first { $0.name == "Schema.swift" }
    XCTAssertNotNil(schemaFile, "Should generate Schema.swift")
    
    let entitiesFile = files.first { $0.name == "Entities.swift" }
    XCTAssertNotNil(entitiesFile, "Should generate Entities.swift")
    
    // Snapshot test each generated file (without timestamp)
    for file in files {
      // Remove the timestamp line for stable snapshots
      let stableContent = removeTimestamp(from: file.content)
      assertSnapshot(of: stableContent, as: .lines, named: file.name)
    }
  }
  
  func testSwiftGenerationLibrarySchemaSnapshot() throws {
    let schema = try parseFixture("LibrarySchema.ts")
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    // Snapshot test each generated file
    for file in files {
      let stableContent = removeTimestamp(from: file.content)
      assertSnapshot(of: stableContent, as: .lines, named: file.name)
    }
  }
  
  func testTypeScriptRoundTripSnapshot() throws {
    let original = try parseFixture("SimpleSchema.ts")
    let printer = TypeScriptSchemaPrinter()
    let output = printer.print(original)
    
    assertSnapshot(of: output, as: .lines)
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
    XCTAssertEqual(EntityIR(name: "categories").swiftTypeName, "Category")
    XCTAssertEqual(EntityIR(name: "data").swiftTypeName, "Data")
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
  
  // MARK: - Room Parsing Tests
  
  func testParseSchemaWithRooms() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    const _schema = i.schema({
      entities: {
        todos: i.entity({
          title: i.string(),
        }),
      },
      links: {},
      rooms: {
        chat: {
          presence: i.entity({
            name: i.string(),
            isTyping: i.boolean(),
          }),
        },
        cursors: {
          presence: i.entity({
            x: i.number(),
            y: i.number(),
          }),
        },
        reactions: {
          presence: i.entity({
            name: i.string(),
          }),
          topics: {
            emoji: i.entity({
              name: i.string(),
              angle: i.number(),
            }),
          },
        },
      },
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    // Verify rooms were parsed
    XCTAssertEqual(schema.rooms.count, 3)
    
    // Verify room names
    let roomNames = schema.rooms.map(\.name).sorted()
    XCTAssertEqual(roomNames, ["chat", "cursors", "reactions"])
    
    // Verify chat room presence
    let chatRoom = schema.rooms.first { $0.name == "chat" }!
    XCTAssertNotNil(chatRoom.presence)
    XCTAssertEqual(chatRoom.presence?.fields.count, 2)
    XCTAssertTrue(chatRoom.topics.isEmpty)
    
    // Verify cursors room presence
    let cursorsRoom = schema.rooms.first { $0.name == "cursors" }!
    XCTAssertNotNil(cursorsRoom.presence)
    XCTAssertEqual(cursorsRoom.presence?.fields.count, 2)
    
    // Verify reactions room with topics
    let reactionsRoom = schema.rooms.first { $0.name == "reactions" }!
    XCTAssertNotNil(reactionsRoom.presence)
    XCTAssertEqual(reactionsRoom.topics.count, 1)
    
    let emojiTopic = reactionsRoom.topics.first!
    XCTAssertEqual(emojiTopic.name, "emoji")
    XCTAssertEqual(emojiTopic.roomName, "reactions")
    XCTAssertEqual(emojiTopic.payload.fields.count, 2)
  }
  
  func testRoomPresenceTypeName() {
    let room = RoomIR(
      name: "chat",
      presence: EntityIR(name: "chatPresence", fields: []),
      topics: []
    )
    
    XCTAssertEqual(room.presenceTypeName, "ChatPresence")
  }
  
  func testTopicPayloadTypeName() {
    let topic = TopicIR(
      name: "emoji",
      payload: EntityIR(name: "emoji", fields: []),
      roomName: "reactions"
    )
    
    XCTAssertEqual(topic.payloadTypeName, "EmojiTopic")
  }
  
  func testSwiftGenerationWithRooms() throws {
    let schemaContent = """
    import { i } from "@instantdb/core";
    
    const _schema = i.schema({
      entities: {
        todos: i.entity({
          title: i.string(),
        }),
      },
      links: {},
      rooms: {
        chat: {
          presence: i.entity({
            name: i.string(),
            isTyping: i.boolean(),
          }),
          topics: {
            emoji: i.entity({
              name: i.string(),
              angle: i.number(),
            }),
          },
        },
      },
    });
    """
    
    let parser = TypeScriptSchemaParser()
    let schema = try parser.parse(content: schemaContent)
    
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    // Should generate Rooms.swift
    let roomsFile = files.first { $0.name == "Rooms.swift" }
    XCTAssertNotNil(roomsFile, "Should generate Rooms.swift")
    
    // Verify content includes presence type
    XCTAssertTrue(roomsFile?.content.contains("ChatPresence") ?? false)
    XCTAssertTrue(roomsFile?.content.contains("var name: String") ?? false)
    XCTAssertTrue(roomsFile?.content.contains("var isTyping: Bool") ?? false)
    
    // Verify content includes topic type
    XCTAssertTrue(roomsFile?.content.contains("EmojiTopic") ?? false)
    
    // Verify content includes room key
    XCTAssertTrue(roomsFile?.content.contains("Schema.Rooms") ?? false)
    XCTAssertTrue(roomsFile?.content.contains("RoomKey<ChatPresence>") ?? false)
    
    // Verify content includes topic key
    XCTAssertTrue(roomsFile?.content.contains("Schema.Topics") ?? false)
    XCTAssertTrue(roomsFile?.content.contains("TopicKey<EmojiTopic>") ?? false)
  }
  
  func testValidationRejectsDuplicateRooms() throws {
    var schema = SchemaIR()
    schema.rooms = [
      RoomIR(name: "chat", presence: nil, topics: []),
      RoomIR(name: "chat", presence: nil, topics: []),
    ]
    
    XCTAssertThrowsError(try schema.validate()) { error in
      XCTAssertTrue(error.localizedDescription.contains("Duplicate"))
    }
  }
  
  func testValidationRejectsDuplicateTopics() throws {
    var schema = SchemaIR()
    schema.rooms = [
      RoomIR(
        name: "reactions",
        presence: nil,
        topics: [
          TopicIR(name: "emoji", payload: EntityIR(name: "emoji", fields: []), roomName: "reactions"),
          TopicIR(name: "emoji", payload: EntityIR(name: "emoji", fields: []), roomName: "reactions"),
        ]
      ),
    ]
    
    XCTAssertThrowsError(try schema.validate()) { error in
      XCTAssertTrue(error.localizedDescription.contains("Duplicate"))
    }
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
  
  /// Remove timestamp from generated code for stable snapshots
  private func removeTimestamp(from content: String) -> String {
    let lines = content.components(separatedBy: "\n")
    return lines.filter { line in
      // Skip lines that look like timestamps
      !line.contains("// 20") // Matches "// 2025-12-17T..."
    }.joined(separator: "\n")
  }
}
