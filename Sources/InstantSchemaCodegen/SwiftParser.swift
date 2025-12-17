// SwiftParser.swift
// InstantSchemaCodegen
//
// Parses Swift schema files (structs with InstantEntity conformance) into SchemaIR.

import Foundation

// MARK: - Swift Schema Parser

/// Parses Swift schema files into SchemaIR.
///
/// ## Supported Syntax
///
/// ```swift
/// /// A todo item
/// struct Todo: InstantEntity, Codable {
///   static var namespace: String { "todos" }
///   
///   var id: String
///   /// The title of the todo
///   var title: String
///   var done: Bool
///   var createdAt: Date
///   
///   // Links
///   var owner: User?
/// }
/// ```
///
/// ## Usage
///
/// ```swift
/// let parser = SwiftSchemaParser()
/// let schema = try parser.parse(fileAt: "Schema.swift")
/// ```
public struct SwiftSchemaParser {
  
  public init() {}
  
  /// Parse a Swift schema file
  public func parse(fileAt path: String) throws -> SchemaIR {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    return try parse(content: content, sourceFile: path)
  }
  
  /// Parse multiple Swift files in a directory
  public func parseDirectory(at path: String) throws -> SchemaIR {
    let fileManager = FileManager.default
    var combinedSchema = SchemaIR()
    
    let contents = try fileManager.contentsOfDirectory(atPath: path)
    for file in contents where file.hasSuffix(".swift") {
      let filePath = (path as NSString).appendingPathComponent(file)
      let fileSchema = try parse(fileAt: filePath)
      combinedSchema.entities.append(contentsOf: fileSchema.entities)
      combinedSchema.links.append(contentsOf: fileSchema.links)
    }
    
    try combinedSchema.validate()
    return combinedSchema
  }
  
  /// Parse Swift schema content
  public func parse(content: String, sourceFile: String? = nil) throws -> SchemaIR {
    var schema = SchemaIR(sourceFile: sourceFile)
    
    // Parse entities (structs conforming to InstantEntity)
    schema.entities = try parseEntities(from: content)
    
    // Parse links from @Link attributes or link definitions
    schema.links = try parseLinks(from: content, entities: schema.entities)
    
    return schema
  }
  
  // MARK: - Entity Parsing
  
  private func parseEntities(from content: String) throws -> [EntityIR] {
    var entities: [EntityIR] = []
    
    // Pattern to match struct definitions with InstantEntity conformance
    // Handles: struct Name: InstantEntity, Codable { ... }
    let structPattern = #"((?:///[^\n]*\n)*)?\s*(?:public\s+)?struct\s+(\w+)\s*:\s*[^{]*InstantEntity[^{]*\{"#
    
    guard let regex = try? NSRegularExpression(pattern: structPattern, options: .dotMatchesLineSeparators) else {
      return entities
    }
    
    let nsContent = content as NSString
    let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
    
    for match in matches {
      guard match.numberOfRanges >= 3 else { continue }
      
      // Extract documentation (group 1)
      var documentation: String? = nil
      if match.range(at: 1).location != NSNotFound {
        let docRange = match.range(at: 1)
        let rawDoc = nsContent.substring(with: docRange)
        documentation = cleanSwiftDocumentation(rawDoc)
      }
      
      // Extract struct name (group 2)
      let nameRange = match.range(at: 2)
      let structName = nsContent.substring(with: nameRange)
      
      // Find the struct body
      let structStart = match.range.location + match.range.length - 1
      let blockStartIndex = content.index(content.startIndex, offsetBy: structStart)
      
      guard let blockEndIndex = findMatchingBrace(in: content, from: blockStartIndex) else {
        throw SwiftParseError.unmatchedBrace(structName)
      }
      
      let structBody = String(content[blockStartIndex...blockEndIndex])
      
      // Extract namespace from static var namespace
      guard let namespace = extractNamespace(from: structBody) else {
        throw SwiftParseError.missingNamespace(structName)
      }
      
      // Parse fields
      let fields = try parseFields(from: structBody, structName: structName)
      
      entities.append(EntityIR(
        name: namespace,
        fields: fields,
        documentation: documentation
      ))
    }
    
    return entities
  }
  
  private func extractNamespace(from structBody: String) -> String? {
    // Pattern: static var namespace: String { "value" }
    // Or: static let namespace = "value"
    let patterns = [
      #"static\s+var\s+namespace\s*:\s*String\s*\{\s*"(\w+)"\s*\}"#,
      #"static\s+let\s+namespace\s*=\s*"(\w+)""#,
      #"static\s+var\s+namespace\s*=\s*"(\w+)""#
    ]
    
    for pattern in patterns {
      if let regex = try? NSRegularExpression(pattern: pattern),
         let match = regex.firstMatch(in: structBody, range: NSRange(location: 0, length: structBody.utf16.count)),
         match.numberOfRanges >= 2 {
        let nsBody = structBody as NSString
        return nsBody.substring(with: match.range(at: 1))
      }
    }
    
    return nil
  }
  
  // MARK: - Field Parsing
  
  private func parseFields(from body: String, structName: String) throws -> [FieldIR] {
    var fields: [FieldIR] = []
    
    // Pattern to match var/let declarations
    // Handles: var name: Type, var name: Type?, let name: Type = default
    let fieldPattern = #"((?:///[^\n]*\n)*)\s*(?:public\s+)?(?:var|let)\s+(\w+)\s*:\s*(\[?\w+\]?)(\?)?"#
    
    guard let regex = try? NSRegularExpression(pattern: fieldPattern, options: .dotMatchesLineSeparators) else {
      return fields
    }
    
    let nsBody = body as NSString
    let matches = regex.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
    
    for match in matches {
      guard match.numberOfRanges >= 4 else { continue }
      
      let nameRange = match.range(at: 2)
      let typeRange = match.range(at: 3)
      let fieldName = nsBody.substring(with: nameRange)
      let typeName = nsBody.substring(with: typeRange)
      
      // Skip 'id' field (implicit) and 'namespace' (static)
      if fieldName == "id" || fieldName == "namespace" { continue }
      
      // Skip link fields (they reference other entities)
      // We'll handle these separately
      if isLinkType(typeName) { continue }
      
      // Check for optional
      let isOptional = match.numberOfRanges > 4 && match.range(at: 4).location != NSNotFound
      
      // Map Swift type to FieldType
      guard let fieldType = mapSwiftType(typeName) else {
        // Skip unknown types (might be links or custom types)
        continue
      }
      
      // Extract documentation
      var documentation: String? = nil
      if match.range(at: 1).location != NSNotFound {
        let docRange = match.range(at: 1)
        let rawDoc = nsBody.substring(with: docRange)
        documentation = cleanSwiftDocumentation(rawDoc)
      }
      
      fields.append(FieldIR(
        name: fieldName,
        type: fieldType,
        isOptional: isOptional,
        documentation: documentation
      ))
    }
    
    return fields
  }
  
  private func mapSwiftType(_ typeName: String) -> FieldType? {
    // Handle array types - treat as JSON for now
    if typeName.hasPrefix("[") && typeName.hasSuffix("]") {
      return .json
    }
    
    switch typeName {
    case "String": return .string
    case "Double", "Float", "CGFloat": return .number
    case "Int", "Int64", "Int32": return .integer
    case "Bool": return .boolean
    case "Date": return .date
    case "AnyCodable", "Any": return .json
    default: return nil
    }
  }
  
  private func isLinkType(_ typeName: String) -> Bool {
    // Check if this looks like a link to another entity
    // Links are typically: OtherEntity?, [OtherEntity]?, [OtherEntity]
    let baseType = typeName
      .replacingOccurrences(of: "[", with: "")
      .replacingOccurrences(of: "]", with: "")
      .replacingOccurrences(of: "?", with: "")
    
    // If it's not a known Swift type, it's probably a link
    return mapSwiftType(baseType) == nil && !baseType.isEmpty
  }
  
  // MARK: - Link Parsing
  
  private func parseLinks(from content: String, entities: [EntityIR]) throws -> [LinkIR] {
    var links: [LinkIR] = []
    
    // Look for link definitions in a Links enum or similar
    // Pattern: static let linkName = Link(...)
    let linkPattern = #"static\s+let\s+(\w+)\s*=\s*Link\s*\("#
    
    guard let regex = try? NSRegularExpression(pattern: linkPattern) else {
      return links
    }
    
    let nsContent = content as NSString
    let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
    
    for match in matches {
      guard match.numberOfRanges >= 2 else { continue }
      
      let nameRange = match.range(at: 1)
      let linkName = nsContent.substring(with: nameRange)
      
      // Find the Link(...) call
      let linkStart = match.range.location + match.range.length - 1
      let parenStartIndex = content.index(content.startIndex, offsetBy: linkStart)
      
      guard let parenEndIndex = findMatchingParen(in: content, from: parenStartIndex) else {
        continue
      }
      
      let linkCall = String(content[parenStartIndex...parenEndIndex])
      
      // Parse the link definition
      if let link = try parseLinkDefinition(name: linkName, from: linkCall) {
        links.append(link)
      }
    }
    
    // Also infer links from entity fields that reference other entities
    links.append(contentsOf: try inferLinksFromEntities(entities, in: content))
    
    return links
  }
  
  private func parseLinkDefinition(name: String, from call: String) throws -> LinkIR? {
    // Pattern for Link(name: "...", from: Type.self, fromLabel: "...", ...)
    // This is a simplified parser - a full implementation would use SwiftSyntax
    
    // Extract from entity
    let fromPattern = #"from\s*:\s*(\w+)\.self"#
    let toPattern = #"to\s*:\s*(\w+)\.self"#
    let fromLabelPattern = #"fromLabel\s*:\s*"(\w+)""#
    let toLabelPattern = #"toLabel\s*:\s*"(\w+)""#
    let fromCardPattern = #"fromCardinality\s*:\s*\.(\w+)"#
    let toCardPattern = #"toCardinality\s*:\s*\.(\w+)"#
    
    guard let fromEntity = extractMatch(pattern: fromPattern, from: call),
          let toEntity = extractMatch(pattern: toPattern, from: call),
          let fromLabel = extractMatch(pattern: fromLabelPattern, from: call),
          let toLabel = extractMatch(pattern: toLabelPattern, from: call) else {
      return nil
    }
    
    let fromCard = extractMatch(pattern: fromCardPattern, from: call) ?? "many"
    let toCard = extractMatch(pattern: toCardPattern, from: call) ?? "one"
    
    // Convert struct names to namespace names (Todo -> todos)
    let fromNamespace = structNameToNamespace(fromEntity)
    let toNamespace = structNameToNamespace(toEntity)
    
    return LinkIR(
      name: name,
      forward: LinkSide(
        entityName: fromNamespace,
        cardinality: Cardinality(rawValue: fromCard) ?? .many,
        label: fromLabel
      ),
      reverse: LinkSide(
        entityName: toNamespace,
        cardinality: Cardinality(rawValue: toCard) ?? .one,
        label: toLabel
      )
    )
  }
  
  private func inferLinksFromEntities(_ entities: [EntityIR], in content: String) throws -> [LinkIR] {
    // This would analyze entity fields to infer links
    // For now, return empty - links should be explicitly defined
    return []
  }
  
  private func extractMatch(pattern: String, from text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
          match.numberOfRanges >= 2 else {
      return nil
    }
    return (text as NSString).substring(with: match.range(at: 1))
  }
  
  private func structNameToNamespace(_ structName: String) -> String {
    // Todo -> todos, User -> users
    let lowercased = structName.prefix(1).lowercased() + structName.dropFirst()
    return lowercased + "s"
  }
  
  // MARK: - Helpers
  
  private func findMatchingBrace(in content: String, from startIndex: String.Index) -> String.Index? {
    var depth = 0
    var index = startIndex
    
    while index < content.endIndex {
      let char = content[index]
      if char == "{" {
        depth += 1
      } else if char == "}" {
        depth -= 1
        if depth == 0 {
          return index
        }
      }
      index = content.index(after: index)
    }
    
    return nil
  }
  
  private func findMatchingParen(in content: String, from startIndex: String.Index) -> String.Index? {
    var depth = 0
    var index = startIndex
    
    while index < content.endIndex {
      let char = content[index]
      if char == "(" {
        depth += 1
      } else if char == ")" {
        depth -= 1
        if depth == 0 {
          return index
        }
      }
      index = content.index(after: index)
    }
    
    return nil
  }
  
  private func cleanSwiftDocumentation(_ raw: String) -> String? {
    let cleaned = raw
      .components(separatedBy: .newlines)
      .map { line in
        line.trimmingCharacters(in: .whitespaces)
          .replacingOccurrences(of: "///", with: "")
          .trimmingCharacters(in: .whitespaces)
      }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    
    return cleaned.isEmpty ? nil : cleaned
  }
}

// MARK: - Parse Errors

/// Errors that can occur when parsing Swift schemas
public enum SwiftParseError: Error, LocalizedError {
  case unmatchedBrace(String)
  case missingNamespace(String)
  case invalidLinkDefinition(String)
  
  public var errorDescription: String? {
    switch self {
    case .unmatchedBrace(let context):
      return "Unmatched brace in '\(context)'"
    case .missingNamespace(let structName):
      return "Struct '\(structName)' is missing 'static var namespace: String' property"
    case .invalidLinkDefinition(let linkName):
      return "Invalid link definition for '\(linkName)'"
    }
  }
}

