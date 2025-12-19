// ParserUnitTests.swift
// InstantSchemaCodegenTests
//
// ═══════════════════════════════════════════════════════════════════════════════
// UNIT TESTS FOR PRIMITIVE PARSERS
// ═══════════════════════════════════════════════════════════════════════════════
//
// These tests verify each primitive parser in isolation. They serve as:
// 1. Documentation of expected parser behavior
// 2. Regression tests for parser correctness
// 3. Examples of how to use each parser
//
// ## Test Organization
//
// Tests are grouped by parser type:
// - Whitespace parsers (HorizontalWhitespace, OptionalWhitespace, RequiredWhitespace)
// - Comment parsers (SingleLineComment, MultiLineComment, JSDocComment, AnyComment)
// - String parsers (DoubleQuotedString, SingleQuotedString, StringLiteral)
// - Identifier parser
// - Number parser
// - Boolean parser
// - Punctuation parsers (Comma, Colon)
//
// ## Test Naming Convention
//
// test<ParserName>_<scenario>_<expectedResult>
//
// Examples:
// - testIdentifier_validSimple_parsesCorrectly
// - testDoubleQuotedString_withEscapes_handlesEscapes
// - testSingleLineComment_atEndOfFile_noNewline

import Foundation
import XCTest
@testable import InstantSchemaCodegen

final class ParserUnitTests: XCTestCase {
  
  // MARK: - Whitespace Parser Tests
  
  func testHorizontalWhitespace_spacesAndTabs_consumed() throws {
    var input: Substring = "   \t  hello"
    try HorizontalWhitespace().parse(&input)
    XCTAssertEqual(input, "hello")
  }
  
  func testHorizontalWhitespace_noWhitespace_succeeds() throws {
    var input: Substring = "hello"
    try HorizontalWhitespace().parse(&input)
    XCTAssertEqual(input, "hello")
  }
  
  func testHorizontalWhitespace_stopsAtNewline() throws {
    var input: Substring = "  \nhello"
    try HorizontalWhitespace().parse(&input)
    XCTAssertEqual(input, "\nhello")
  }
  
  func testOptionalWhitespace_allTypes_consumed() throws {
    var input: Substring = "  \n\t  \n  hello"
    try OptionalWhitespace().parse(&input)
    XCTAssertEqual(input, "hello")
  }
  
  func testOptionalWhitespace_noWhitespace_succeeds() throws {
    var input: Substring = "hello"
    try OptionalWhitespace().parse(&input)
    XCTAssertEqual(input, "hello")
  }
  
  func testRequiredWhitespace_present_succeeds() throws {
    var input: Substring = "  hello"
    try RequiredWhitespace().parse(&input)
    XCTAssertEqual(input, "hello")
  }
  
  func testRequiredWhitespace_missing_fails() throws {
    var input: Substring = "hello"
    XCTAssertThrowsError(try RequiredWhitespace().parse(&input))
  }
  
  // MARK: - Comment Parser Tests
  
  func testSingleLineComment_simple_parsesContent() throws {
    var input: Substring = "// This is a comment\nnext line"
    let result = try SingleLineComment().parse(&input)
    XCTAssertEqual(result, " This is a comment")
    XCTAssertEqual(input, "next line")
  }
  
  func testSingleLineComment_atEndOfFile_noNewline() throws {
    var input: Substring = "// Comment at end"
    let result = try SingleLineComment().parse(&input)
    XCTAssertEqual(result, " Comment at end")
    XCTAssertTrue(input.isEmpty)
  }
  
  func testSingleLineComment_empty_returnsEmpty() throws {
    var input: Substring = "//\nnext"
    let result = try SingleLineComment().parse(&input)
    XCTAssertEqual(result, "")
    XCTAssertEqual(input, "next")
  }
  
  func testSingleLineComment_withSpecialChars_preserved() throws {
    var input: Substring = "// @param {string} name - The name\n"
    let result = try SingleLineComment().parse(&input)
    XCTAssertEqual(result, " @param {string} name - The name")
  }
  
  func testMultiLineComment_singleLine_parsesContent() throws {
    var input: Substring = "/* Hello world */next"
    let result = try MultiLineComment().parse(&input)
    XCTAssertEqual(result, " Hello world ")
    XCTAssertEqual(input, "next")
  }
  
  func testMultiLineComment_multipleLines_preservesNewlines() throws {
    var input: Substring = "/*\n * Line 1\n * Line 2\n */next"
    let result = try MultiLineComment().parse(&input)
    XCTAssertTrue(result.contains("Line 1"))
    XCTAssertTrue(result.contains("Line 2"))
    XCTAssertEqual(input, "next")
  }
  
  func testMultiLineComment_unterminated_fails() throws {
    var input: Substring = "/* No end"
    XCTAssertThrowsError(try MultiLineComment().parse(&input))
  }
  
  func testJSDocComment_singleLine_cleans() throws {
    var input: Substring = "/** A todo item */next"
    let result = try JSDocComment().parse(&input)
    XCTAssertEqual(result, "A todo item")
    XCTAssertEqual(input, "next")
  }
  
  func testJSDocComment_multiLine_cleansAsterisks() throws {
    var input: Substring = """
    /**
     * A todo item with title and completion status.
     * @see https://example.com
     */next
    """
    let result = try JSDocComment().parse(&input)
    XCTAssertTrue(result.contains("A todo item"))
    XCTAssertTrue(result.contains("@see"))
    XCTAssertFalse(result.contains("/**"))
    XCTAssertFalse(result.contains("*/"))
    XCTAssertEqual(input, "next")
  }
  
  func testAnyComment_singleLine_parses() throws {
    var input: Substring = "// Single\nnext"
    let result = try AnyComment().parse(&input)
    XCTAssertEqual(result, " Single")
  }
  
  func testAnyComment_multiLine_parses() throws {
    var input: Substring = "/* Multi */next"
    let result = try AnyComment().parse(&input)
    XCTAssertEqual(result, " Multi ")
  }
  
  func testAnyComment_jsDoc_parses() throws {
    var input: Substring = "/** Doc */next"
    let result = try AnyComment().parse(&input)
    XCTAssertEqual(result, "Doc")
  }
  
  func testSkipWhitespaceAndComments_mixed_skipsAll() throws {
    var input: Substring = """
      // Comment 1
      /* Comment 2 */
      
      hello
    """
    try SkipWhitespaceAndComments().parse(&input)
    XCTAssertTrue(input.hasPrefix("hello"))
  }
  
  func testSkipWhitespaceAndComments_noContent_succeeds() throws {
    var input: Substring = "hello"
    try SkipWhitespaceAndComments().parse(&input)
    XCTAssertEqual(input, "hello")
  }
  
  // MARK: - String Literal Parser Tests
  
  func testDoubleQuotedString_simple_parsesContent() throws {
    var input: Substring = "\"hello world\"next"
    let result = try DoubleQuotedString().parse(&input)
    XCTAssertEqual(result, "hello world")
    XCTAssertEqual(input, "next")
  }
  
  func testDoubleQuotedString_empty_returnsEmpty() throws {
    var input: Substring = "\"\"next"
    let result = try DoubleQuotedString().parse(&input)
    XCTAssertEqual(result, "")
    XCTAssertEqual(input, "next")
  }
  
  func testDoubleQuotedString_escapedQuote_handled() throws {
    var input: Substring = "\"say \\\"hello\\\"\"next"
    let result = try DoubleQuotedString().parse(&input)
    XCTAssertEqual(result, "say \"hello\"")
  }
  
  func testDoubleQuotedString_escapedBackslash_handled() throws {
    var input: Substring = "\"path\\\\to\\\\file\"next"
    let result = try DoubleQuotedString().parse(&input)
    XCTAssertEqual(result, "path\\to\\file")
  }
  
  func testDoubleQuotedString_escapedNewline_handled() throws {
    var input: Substring = "\"line1\\nline2\"next"
    let result = try DoubleQuotedString().parse(&input)
    XCTAssertEqual(result, "line1\nline2")
  }
  
  func testDoubleQuotedString_unterminated_fails() throws {
    var input: Substring = "\"no end"
    XCTAssertThrowsError(try DoubleQuotedString().parse(&input))
  }
  
  func testSingleQuotedString_simple_parsesContent() throws {
    var input: Substring = "'hello world'next"
    let result = try SingleQuotedString().parse(&input)
    XCTAssertEqual(result, "hello world")
    XCTAssertEqual(input, "next")
  }
  
  func testSingleQuotedString_escapedQuote_handled() throws {
    var input: Substring = "'it\\'s working'next"
    let result = try SingleQuotedString().parse(&input)
    XCTAssertEqual(result, "it's working")
  }
  
  func testStringLiteral_doubleQuoted_parses() throws {
    var input: Substring = "\"double\"next"
    let result = try StringLiteral().parse(&input)
    XCTAssertEqual(result, "double")
  }
  
  func testStringLiteral_singleQuoted_parses() throws {
    var input: Substring = "'single'next"
    let result = try StringLiteral().parse(&input)
    XCTAssertEqual(result, "single")
  }
  
  func testStringLiteral_noQuotes_fails() throws {
    var input: Substring = "noquotes"
    XCTAssertThrowsError(try StringLiteral().parse(&input))
  }
  
  // MARK: - Identifier Parser Tests
  
  func testIdentifier_simple_parses() throws {
    var input: Substring = "myVariable next"
    let result = try Identifier().parse(&input)
    XCTAssertEqual(result, "myVariable")
    XCTAssertEqual(input, " next")
  }
  
  func testIdentifier_withUnderscore_parses() throws {
    var input: Substring = "_private"
    let result = try Identifier().parse(&input)
    XCTAssertEqual(result, "_private")
  }
  
  func testIdentifier_withDollarSign_parses() throws {
    var input: Substring = "$users next"
    let result = try Identifier().parse(&input)
    XCTAssertEqual(result, "$users")
  }
  
  func testIdentifier_withNumbers_parses() throws {
    var input: Substring = "camelCase123 next"
    let result = try Identifier().parse(&input)
    XCTAssertEqual(result, "camelCase123")
  }
  
  func testIdentifier_startsWithNumber_fails() throws {
    var input: Substring = "123start"
    XCTAssertThrowsError(try Identifier().parse(&input))
  }
  
  func testIdentifier_startsWithHyphen_fails() throws {
    var input: Substring = "-dash"
    XCTAssertThrowsError(try Identifier().parse(&input))
  }
  
  func testIdentifier_stopsAtHyphen() throws {
    var input: Substring = "my-var"
    let result = try Identifier().parse(&input)
    XCTAssertEqual(result, "my")
    XCTAssertEqual(input, "-var")
  }
  
  // MARK: - Number Parser Tests
  
  func testNumberLiteral_integer_parses() throws {
    var input: Substring = "42 next"
    let result = try NumberLiteral().parse(&input)
    XCTAssertEqual(result, 42.0)
    XCTAssertEqual(input, " next")
  }
  
  func testNumberLiteral_negative_parses() throws {
    var input: Substring = "-17 next"
    let result = try NumberLiteral().parse(&input)
    XCTAssertEqual(result, -17.0)
  }
  
  func testNumberLiteral_decimal_parses() throws {
    var input: Substring = "3.14 next"
    let result = try NumberLiteral().parse(&input)
    XCTAssertEqual(result, 3.14, accuracy: 0.001)
  }
  
  func testNumberLiteral_negativeDecimal_parses() throws {
    var input: Substring = "-0.5 next"
    let result = try NumberLiteral().parse(&input)
    XCTAssertEqual(result, -0.5, accuracy: 0.001)
  }
  
  func testNumberLiteral_noNumber_fails() throws {
    var input: Substring = "abc"
    XCTAssertThrowsError(try NumberLiteral().parse(&input))
  }
  
  // MARK: - Boolean Parser Tests
  
  func testBooleanLiteral_true_parses() throws {
    var input: Substring = "true next"
    let result = try BooleanLiteral().parse(&input)
    XCTAssertTrue(result)
    XCTAssertEqual(input, " next")
  }
  
  func testBooleanLiteral_false_parses() throws {
    var input: Substring = "false next"
    let result = try BooleanLiteral().parse(&input)
    XCTAssertFalse(result)
    XCTAssertEqual(input, " next")
  }
  
  func testBooleanLiteral_invalid_fails() throws {
    var input: Substring = "yes"
    XCTAssertThrowsError(try BooleanLiteral().parse(&input))
  }
  
  // MARK: - Punctuation Parser Tests
  
  func testComma_simple_parses() throws {
    var input: Substring = ", next"
    try Comma().parse(&input)
    XCTAssertEqual(input, "next")
  }
  
  func testComma_withWhitespace_parses() throws {
    var input: Substring = "  ,  next"
    try Comma().parse(&input)
    XCTAssertEqual(input, "next")
  }
  
  func testComma_missing_fails() throws {
    var input: Substring = "next"
    XCTAssertThrowsError(try Comma().parse(&input))
  }
  
  func testColon_simple_parses() throws {
    var input: Substring = ": value"
    try Colon().parse(&input)
    XCTAssertEqual(input, "value")
  }
  
  func testColon_withWhitespace_parses() throws {
    var input: Substring = "  :  value"
    try Colon().parse(&input)
    XCTAssertEqual(input, "value")
  }
  
  func testColon_missing_fails() throws {
    var input: Substring = "value"
    XCTAssertThrowsError(try Colon().parse(&input))
  }
  
  // MARK: - Field Type Parser Tests
  
  func testFieldTypeParser_string_parses() throws {
    var input: Substring = "i.string() next"
    let result = try FieldTypeParser().parse(&input)
    XCTAssertEqual(result, .string)
    XCTAssertEqual(input, " next")
  }
  
  func testFieldTypeParser_number_parses() throws {
    var input: Substring = "i.number()"
    let result = try FieldTypeParser().parse(&input)
    XCTAssertEqual(result, .number)
  }
  
  func testFieldTypeParser_boolean_parses() throws {
    var input: Substring = "i.boolean()"
    let result = try FieldTypeParser().parse(&input)
    XCTAssertEqual(result, .boolean)
  }
  
  func testFieldTypeParser_date_parses() throws {
    var input: Substring = "i.date()"
    let result = try FieldTypeParser().parse(&input)
    XCTAssertEqual(result, .date)
  }
  
  func testFieldTypeParser_json_parses() throws {
    var input: Substring = "i.json()"
    let result = try FieldTypeParser().parse(&input)
    XCTAssertEqual(result, .json)
  }
  
  func testFieldTypeParser_unknownType_fails() throws {
    var input: Substring = "i.unknown()"
    XCTAssertThrowsError(try FieldTypeParser().parse(&input))
  }
  
  // MARK: - Field Parser Tests
  
  func testFieldParser_simple_parses() throws {
    var input: Substring = "title: i.string() next"
    let result = try FieldParser().parse(&input)
    XCTAssertEqual(result.name, "title")
    XCTAssertEqual(result.type, .string)
    XCTAssertFalse(result.isOptional)
  }
  
  func testFieldParser_optional_parses() throws {
    var input: Substring = "bio: i.string().optional()"
    let result = try FieldParser().parse(&input)
    XCTAssertEqual(result.name, "bio")
    XCTAssertEqual(result.type, .string)
    XCTAssertTrue(result.isOptional)
  }
  
  func testFieldParser_withIndexed_parses() throws {
    var input: Substring = "email: i.string().indexed()"
    let result = try FieldParser().parse(&input)
    XCTAssertEqual(result.name, "email")
    XCTAssertEqual(result.type, .string)
    XCTAssertFalse(result.isOptional)
  }
  
  func testFieldParser_withMultipleModifiers_parses() throws {
    var input: Substring = "email: i.string().unique().indexed().optional()"
    let result = try FieldParser().parse(&input)
    XCTAssertEqual(result.name, "email")
    XCTAssertEqual(result.type, .string)
    XCTAssertTrue(result.isOptional, "Field with .optional() after other modifiers should be optional")
  }
  
  func testFieldParser_optionalInMiddle_parses() throws {
    var input: Substring = "path: i.string().indexed().optional()"
    let result = try FieldParser().parse(&input)
    XCTAssertEqual(result.name, "path")
    XCTAssertTrue(result.isOptional, "Field with .optional() should be optional")
  }
  
  // MARK: - Entity Parser Tests
  
  func testEntityParser_simple_parses() throws {
    var input: Substring = """
    todos: i.entity({
      title: i.string(),
      done: i.boolean(),
    })
    """
    let result = try EntityParser().parse(&input)
    XCTAssertEqual(result.name, "todos")
    XCTAssertEqual(result.fields.count, 2)
    XCTAssertEqual(result.fields[0].name, "title")
    XCTAssertEqual(result.fields[1].name, "done")
  }
  
  func testEntityParser_systemEntity_parses() throws {
    var input: Substring = """
    $users: i.entity({
      email: i.string(),
    })
    """
    let result = try EntityParser().parse(&input)
    XCTAssertEqual(result.name, "$users")
    XCTAssertTrue(result.isSystemEntity)
  }
  
  func testEntityParser_empty_parses() throws {
    var input: Substring = "empty: i.entity({})"
    let result = try EntityParser().parse(&input)
    XCTAssertEqual(result.name, "empty")
    XCTAssertTrue(result.fields.isEmpty)
  }
  
  // MARK: - Link Parser Tests
  
  func testLinkSideParser_simple_parses() throws {
    var input: Substring = """
    { on: "users", has: "many", label: "todos" }
    """
    let result = try LinkSideParser().parse(&input)
    XCTAssertEqual(result.entityName, "users")
    XCTAssertEqual(result.cardinality, .many)
    XCTAssertEqual(result.label, "todos")
  }
  
  func testLinkSideParser_one_parses() throws {
    var input: Substring = """
    { on: "todos", has: "one", label: "owner" }
    """
    let result = try LinkSideParser().parse(&input)
    XCTAssertEqual(result.cardinality, .one)
  }
  
  func testLinkParser_simple_parses() throws {
    var input: Substring = """
    userTodos: {
      forward: { on: "users", has: "many", label: "todos" },
      reverse: { on: "todos", has: "one", label: "owner" },
    }
    """
    let result = try LinkParser().parse(&input)
    XCTAssertEqual(result.name, "userTodos")
    XCTAssertEqual(result.forward.entityName, "users")
    XCTAssertEqual(result.forward.cardinality, .many)
    XCTAssertEqual(result.reverse.entityName, "todos")
    XCTAssertEqual(result.reverse.cardinality, .one)
  }
  
  // MARK: - Room Parser Tests
  
  func testRoomParser_withPresence_parses() throws {
    var input: Substring = """
    chat: {
      presence: i.entity({
        name: i.string(),
        isTyping: i.boolean(),
      }),
    }
    """
    let result = try RoomParser().parse(&input)
    XCTAssertEqual(result.name, "chat")
    XCTAssertNotNil(result.presence)
    XCTAssertEqual(result.presence?.fields.count, 2)
    XCTAssertTrue(result.topics.isEmpty)
  }
  
  func testRoomParser_withTopics_parses() throws {
    var input: Substring = """
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
    }
    """
    let result = try RoomParser().parse(&input)
    XCTAssertEqual(result.name, "reactions")
    XCTAssertNotNil(result.presence)
    XCTAssertEqual(result.topics.count, 1)
    XCTAssertEqual(result.topics[0].name, "emoji")
    XCTAssertEqual(result.topics[0].roomName, "reactions")
    XCTAssertEqual(result.topics[0].payload.fields.count, 2)
  }
  
  // MARK: - Full Schema Parser Tests
  
  func testSwiftParsingSchemaParser_simpleSchema_parses() throws {
    let content = """
    import { i } from "@instantdb/core";
    
    const _schema = i.schema({
      entities: {
        /** A todo item */
        todos: i.entity({
          title: i.string(),
          done: i.boolean(),
          priority: i.number().optional(),
        }),
        users: i.entity({
          name: i.string(),
          email: i.string(),
        }),
      },
      links: {
        userTodos: {
          forward: { on: "users", has: "many", label: "todos" },
          reverse: { on: "todos", has: "one", label: "owner" },
        },
      },
    });
    
    export type Schema = typeof _schema;
    """
    
    let parser = SwiftParsingSchemaParser()
    let schema = try parser.parse(content: content)
    
    // Verify entities
    XCTAssertEqual(schema.entities.count, 2)
    XCTAssertEqual(schema.entities.map(\.name).sorted(), ["todos", "users"])
    
    // Verify todos entity
    let todos = schema.entities.first { $0.name == "todos" }!
    XCTAssertEqual(todos.fields.count, 3)
    // Note: Documentation extraction is a stretch goal - the parser captures structure first
    
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
  
  func testSwiftParsingSchemaParser_withRooms_parses() throws {
    let content = """
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
            }),
          },
        },
      },
    });
    """
    
    let parser = SwiftParsingSchemaParser()
    let schema = try parser.parse(content: content)
    
    // Verify rooms
    XCTAssertEqual(schema.rooms.count, 1)
    let chat = schema.rooms[0]
    XCTAssertEqual(chat.name, "chat")
    XCTAssertNotNil(chat.presence)
    XCTAssertEqual(chat.presence?.fields.count, 2)
    XCTAssertEqual(chat.topics.count, 1)
    XCTAssertEqual(chat.topics[0].name, "emoji")
  }
  
  func testSwiftParsingSchemaParser_systemEntities_parses() throws {
    let content = """
    import { i } from "@instantdb/core";
    
    const _schema = i.schema({
      entities: {
        $users: i.entity({
          email: i.string(),
        }),
        $files: i.entity({
          path: i.string(),
        }),
      },
      links: {},
    });
    """
    
    let parser = SwiftParsingSchemaParser()
    let schema = try parser.parse(content: content)
    
    XCTAssertEqual(schema.entities.count, 2)
    XCTAssertTrue(schema.entities.allSatisfy { $0.isSystemEntity })
    XCTAssertEqual(schema.entities.map(\.name).sorted(), ["$files", "$users"])
  }
  
  func testSwiftParsingSchemaParser_noSchema_fails() throws {
    let content = """
    // Just some TypeScript code
    const x = 5;
    """
    
    let parser = SwiftParsingSchemaParser()
    XCTAssertThrowsError(try parser.parse(content: content)) { error in
      XCTAssertTrue(error.localizedDescription.contains("SCHEMA NOT FOUND"))
    }
  }
  
  // MARK: - Error Message Tests
  
  func testSourceLocation_fromIndex_calculatesCorrectly() throws {
    let content = """
    line1
    line2
    line3
    """
    
    // "line2" starts at index 6 (after "line1\n")
    let index = content.index(content.startIndex, offsetBy: 6)
    let location = SourceLocation.from(index: index, in: content)
    
    XCTAssertEqual(location.line, 2)
    XCTAssertEqual(location.column, 1)
    XCTAssertEqual(location.offset, 6)
  }
  
  func testExtractContext_showsSurroundingLines() throws {
    let content = """
    line1
    line2
    line3
    line4
    line5
    """
    
    // Error on line 3 (offset ~12)
    let context = extractContext(around: 12, in: content, radius: 1)
    
    XCTAssertTrue(context.contains("line2"))
    XCTAssertTrue(context.contains("line3"))
    XCTAssertTrue(context.contains("line4"))
    XCTAssertTrue(context.contains("ERROR HERE"))
  }
  
  func testDetailedParseError_formatsNicely() throws {
    let error = DetailedParseError(
      message: "Unknown field type 'i.text()'",
      location: SourceLocation(line: 15, column: 23, offset: 456),
      context: "  15 | description: i.text(),  // <-- ERROR HERE",
      suggestion: "Did you mean 'i.string()'?",
      sourceFile: "test.schema.ts"
    )
    
    let description = error.errorDescription!
    
    XCTAssertTrue(description.contains("PARSE ERROR"))
    XCTAssertTrue(description.contains("line 15"))
    XCTAssertTrue(description.contains("column 23"))
    XCTAssertTrue(description.contains("test.schema.ts"))
    XCTAssertTrue(description.contains("Unknown field type"))
    XCTAssertTrue(description.contains("Context:"))
    XCTAssertTrue(description.contains("Suggestion:"))
  }
  
  func testParseErrors_unknownFieldType_includesSuggestion() throws {
    let error = ParseErrors.unknownFieldType("text")
    let description = error.errorDescription!
    
    XCTAssertTrue(description.contains("i.text()"))
    XCTAssertTrue(description.contains("i.string()"))
    XCTAssertTrue(description.contains("i.number()"))
    XCTAssertTrue(description.contains("i.boolean()"))
  }
}

