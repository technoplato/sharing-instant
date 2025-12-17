// SwiftGenerator.swift
// InstantSchemaCodegen
//
// Generates Swift code from SchemaIR.

import Foundation

// MARK: - Swift Code Generator

/// Generates Swift code from SchemaIR.
///
/// ## Generated Files
///
/// 1. **Entities.swift** - Entity structs conforming to InstantEntity
/// 2. **Schema.swift** - Type-safe Schema namespace with EntityKeys
/// 3. **Links.swift** - Link metadata and query builders
///
/// ## Usage
///
/// ```swift
/// let generator = SwiftCodeGenerator()
/// let files = generator.generate(from: schema)
/// for file in files {
///   try file.content.write(toFile: file.name, atomically: true, encoding: .utf8)
/// }
/// ```
public struct SwiftCodeGenerator {
  
  /// Configuration for code generation
  public struct Configuration {
    /// Whether to generate public or internal access
    public var accessLevel: AccessLevel
    
    /// Whether to include documentation comments
    public var includeDocumentation: Bool
    
    /// Whether to generate Sendable conformance
    public var generateSendable: Bool
    
    /// The module name for imports
    public var moduleName: String?
    
    /// Whether to generate SharedKey extensions
    public var generateSharedKeys: Bool
    
    public init(
      accessLevel: AccessLevel = .public,
      includeDocumentation: Bool = true,
      generateSendable: Bool = true,
      moduleName: String? = nil,
      generateSharedKeys: Bool = true
    ) {
      self.accessLevel = accessLevel
      self.includeDocumentation = includeDocumentation
      self.generateSendable = generateSendable
      self.moduleName = moduleName
      self.generateSharedKeys = generateSharedKeys
    }
    
    public enum AccessLevel: String {
      case `public` = "public"
      case `internal` = "internal"
      case `private` = "private"
    }
  }
  
  public let configuration: Configuration
  
  public init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
  }
  
  /// A generated file
  public struct GeneratedFile {
    public let name: String
    public let content: String
  }
  
  /// Generate all Swift files from a schema
  public func generate(from schema: SchemaIR) -> [GeneratedFile] {
    var files: [GeneratedFile] = []
    
    // Generate entities file
    files.append(GeneratedFile(
      name: "Entities.swift",
      content: generateEntities(from: schema)
    ))
    
    // Generate schema namespace file
    files.append(GeneratedFile(
      name: "Schema.swift",
      content: generateSchema(from: schema)
    ))
    
    // Generate links file if there are links
    if !schema.links.isEmpty {
      files.append(GeneratedFile(
        name: "Links.swift",
        content: generateLinks(from: schema)
      ))
    }
    
    return files
  }
  
  // MARK: - Entity Generation
  
  private func generateEntities(from schema: SchemaIR) -> String {
    var output = fileHeader("Entities.swift")
    
    output += """
    import Foundation
    import SharingInstant
    
    
    """
    
    for entity in schema.entities {
      output += generateEntity(entity, schema: schema)
      output += "\n\n"
    }
    
    return output
  }
  
  private func generateEntity(_ entity: EntityIR, schema: SchemaIR) -> String {
    let access = configuration.accessLevel.rawValue
    let sendable = configuration.generateSendable ? ", Sendable" : ""
    
    var output = ""
    
    // Documentation
    if configuration.includeDocumentation, let doc = entity.documentation {
      output += formatDocumentation(doc)
    }
    
    // Struct declaration
    output += """
    \(access) struct \(entity.swiftTypeName): EntityIdentifiable, Codable\(sendable) {
      \(access) static var namespace: String { "\(entity.name)" }
      
      // MARK: - Fields
      
      /// The unique identifier for this entity
      \(access) var id: String
    
    """
    
    // Fields
    for field in entity.fields {
      output += generateField(field)
    }
    
    // Links (as optional properties)
    let forwardLinks = schema.links.filter { $0.forward.entityName == entity.name }
    let reverseLinks = schema.links.filter { $0.reverse.entityName == entity.name }
    
    if !forwardLinks.isEmpty || !reverseLinks.isEmpty {
      output += "\n  // MARK: - Links\n"
      output += "  // Populated when queried with .with(...)\n\n"
      
      for link in forwardLinks {
        output += generateLinkProperty(
          label: link.forward.label,
          targetEntity: schema.entity(named: link.reverse.entityName),
          cardinality: link.forward.cardinality,
          documentation: "Link to \(link.reverse.entityName) via '\(link.name)'"
        )
      }
      
      for link in reverseLinks {
        output += generateLinkProperty(
          label: link.reverse.label,
          targetEntity: schema.entity(named: link.forward.entityName),
          cardinality: link.reverse.cardinality,
          documentation: "Link to \(link.forward.entityName) via '\(link.name)'"
        )
      }
    }
    
    // Initializer
    output += generateInitializer(entity, schema: schema)
    
    output += "}\n"
    
    return output
  }
  
  private func generateField(_ field: FieldIR) -> String {
    let access = configuration.accessLevel.rawValue
    var output = ""
    
    // Documentation
    if configuration.includeDocumentation, let doc = field.documentation {
      output += "  " + formatDocumentation(doc, indent: "  ")
    }
    
    // Property declaration
    let optionalMark = field.isOptional ? "?" : ""
    output += "  \(access) var \(field.name): \(field.type.swiftType)\(optionalMark)\n"
    
    return output
  }
  
  private func generateLinkProperty(
    label: String,
    targetEntity: EntityIR?,
    cardinality: Cardinality,
    documentation: String
  ) -> String {
    let access = configuration.accessLevel.rawValue
    guard let target = targetEntity else { return "" }
    
    var output = ""
    
    if configuration.includeDocumentation {
      output += "  /// \(documentation)\n"
      output += "  /// - Note: Only populated when queried with `.with(\\.\(label))`\n"
    }
    
    let type: String
    switch cardinality {
    case .one:
      type = "\(target.swiftTypeName)?"
    case .many:
      type = "[\(target.swiftTypeName)]?"
    }
    
    output += "  \(access) var \(label): \(type)\n\n"
    
    return output
  }
  
  private func generateInitializer(_ entity: EntityIR, schema: SchemaIR) -> String {
    let access = configuration.accessLevel.rawValue
    var output = "\n  // MARK: - Initializer\n\n"
    
    // Collect all properties
    var params: [(name: String, type: String, defaultValue: String?)] = []
    
    // ID
    params.append((name: "id", type: "String", defaultValue: "UUID().uuidString"))
    
    // Fields
    for field in entity.fields {
      let type = field.type.swiftType + (field.isOptional ? "?" : "")
      let defaultValue = field.isOptional ? "nil" : field.defaultValue
      params.append((name: field.name, type: type, defaultValue: defaultValue))
    }
    
    // Links (all optional with nil default)
    let forwardLinks = schema.links.filter { $0.forward.entityName == entity.name }
    let reverseLinks = schema.links.filter { $0.reverse.entityName == entity.name }
    
    for link in forwardLinks {
      if let target = schema.entity(named: link.reverse.entityName) {
        let type = link.forward.cardinality == .one ? "\(target.swiftTypeName)?" : "[\(target.swiftTypeName)]?"
        params.append((name: link.forward.label, type: type, defaultValue: "nil"))
      }
    }
    
    for link in reverseLinks {
      if let target = schema.entity(named: link.forward.entityName) {
        let type = link.reverse.cardinality == .one ? "\(target.swiftTypeName)?" : "[\(target.swiftTypeName)]?"
        params.append((name: link.reverse.label, type: type, defaultValue: "nil"))
      }
    }
    
    // Generate initializer
    output += "  \(access) init(\n"
    for (index, param) in params.enumerated() {
      let comma = index < params.count - 1 ? "," : ""
      if let defaultValue = param.defaultValue {
        output += "    \(param.name): \(param.type) = \(defaultValue)\(comma)\n"
      } else {
        output += "    \(param.name): \(param.type)\(comma)\n"
      }
    }
    output += "  ) {\n"
    
    for param in params {
      output += "    self.\(param.name) = \(param.name)\n"
    }
    
    output += "  }\n"
    
    return output
  }
  
  // MARK: - Schema Generation
  
  private func generateSchema(from schema: SchemaIR) -> String {
    var output = fileHeader("Schema.swift")
    
    output += """
    import Foundation
    import InstantDB
    import IdentifiedCollections
    import SharingInstant
    
    // MARK: - Schema Namespace
    
    /// Type-safe schema namespace with auto-derived SharedKeys.
    ///
    /// Use these static properties to create type-safe queries:
    ///
    /// ```swift
    /// // Basic sync
    /// @Shared(Schema.\(schema.entities.first?.name ?? "entities"))
    /// private var items: IdentifiedArrayOf<\(schema.entities.first?.swiftTypeName ?? "Entity")> = []
    ///
    /// // With ordering
    /// @Shared(Schema.\(schema.entities.first?.name ?? "entities").orderBy(\\.\(schema.entities.first?.fields.first?.name ?? "field"), .desc))
    /// private var items: IdentifiedArrayOf<\(schema.entities.first?.swiftTypeName ?? "Entity")> = []
    /// ```
    \(configuration.accessLevel.rawValue) enum Schema {
    
    """
    
    for entity in schema.entities {
      output += generateSchemaProperty(for: entity)
    }
    
    output += "}\n"
    
    return output
  }
  
  private func generateSchemaProperty(for entity: EntityIR) -> String {
    let access = configuration.accessLevel.rawValue
    var output = ""
    
    if configuration.includeDocumentation {
      output += "  /// \(entity.swiftTypeName) entity - bidirectional sync\n"
      if let doc = entity.documentation {
        output += "  ///\n"
        output += "  /// \(doc.replacingOccurrences(of: "\n", with: "\n  /// "))\n"
      }
    }
    
    output += "  \(access) static let \(entity.name) = EntityKey<\(entity.swiftTypeName)>(namespace: \"\(entity.name)\")\n\n"
    
    return output
  }
  
  
  // MARK: - Links Generation
  
  private func generateLinks(from schema: SchemaIR) -> String {
    var output = fileHeader("Links.swift")
    
    output += """
    import Foundation
    import SharingInstant
    
    // MARK: - Link Definitions
    
    /// Metadata about all links in the schema.
    ///
    /// These are used for advanced link operations and query building.
    \(configuration.accessLevel.rawValue) enum SchemaLinks {
    
    """
    
    for link in schema.links {
      output += generateLinkDefinition(link, schema: schema)
    }
    
    output += "}\n\n"
    
    // Generate Link struct
    output += generateLinkStruct()
    
    return output
  }
  
  private func generateLinkDefinition(_ link: LinkIR, schema: SchemaIR) -> String {
    let access = configuration.accessLevel.rawValue
    var output = ""
    
    if configuration.includeDocumentation {
      output += "  /// \(link.forward.entityName) ↔ \(link.reverse.entityName) relationship\n"
      if let doc = link.documentation {
        output += "  /// \(doc)\n"
      }
    }
    
    let fromEntity = schema.entity(named: link.forward.entityName)?.swiftTypeName ?? "Unknown"
    let toEntity = schema.entity(named: link.reverse.entityName)?.swiftTypeName ?? "Unknown"
    
    output += """
      \(access) static let \(link.name) = Link(
        name: "\(link.name)",
        from: \(fromEntity).self, fromLabel: "\(link.forward.label)", fromCardinality: .\(link.forward.cardinality.rawValue),
        to: \(toEntity).self, toLabel: "\(link.reverse.label)", toCardinality: .\(link.reverse.cardinality.rawValue)
      )
    
    
    """
    
    return output
  }
  
  private func generateLinkStruct() -> String {
    let access = configuration.accessLevel.rawValue
    
    return """
    // MARK: - Link Type
    
    /// Represents a bidirectional link between two entities.
    \(access) struct Link<From: InstantEntity, To: InstantEntity>: Sendable {
      \(access) let name: String
      \(access) let fromLabel: String
      \(access) let fromCardinality: LinkCardinality
      \(access) let toLabel: String
      \(access) let toCardinality: LinkCardinality
      
      \(access) init(
        name: String,
        from: From.Type,
        fromLabel: String,
        fromCardinality: LinkCardinality,
        to: To.Type,
        toLabel: String,
        toCardinality: LinkCardinality
      ) {
        self.name = name
        self.fromLabel = fromLabel
        self.fromCardinality = fromCardinality
        self.toLabel = toLabel
        self.toCardinality = toCardinality
      }
    }
    
    /// The cardinality of one side of a link.
    \(access) enum LinkCardinality: String, Sendable {
      case one
      case many
    }
    
    """
  }
  
  // MARK: - Helpers
  
  private func fileHeader(_ filename: String) -> String {
    let date = ISO8601DateFormatter().string(from: Date())
    return """
    // \(filename)
    // Generated by InstantSchemaCodegen
    // \(date)
    //
    // DO NOT EDIT - This file is generated from your InstantDB schema.
    // Any changes will be overwritten on the next codegen run.
    
    
    """
  }
  
  private func formatDocumentation(_ doc: String, indent: String = "") -> String {
    let lines = doc.components(separatedBy: .newlines)
    return lines.map { "\(indent)/// \($0)" }.joined(separator: "\n") + "\n"
  }
}

