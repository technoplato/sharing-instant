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
  
  /// Generation context for including metadata in headers (optional for backwards compatibility)
  private var context: GenerationContext?
  
  /// Generate all Swift files from a schema
  public func generate(from schema: SchemaIR, context: GenerationContext? = nil) -> [GeneratedFile] {
    // Store context for use in header generation
    var generator = self
    generator.context = context
    
    var files: [GeneratedFile] = []
    
    // Generate entities file
    files.append(GeneratedFile(
      name: "Entities.swift",
      content: generator.generateEntities(from: schema)
    ))
    
    // Generate schema namespace file
    files.append(GeneratedFile(
      name: "Schema.swift",
      content: generator.generateSchema(from: schema)
    ))
    
    // Generate links file if there are links
    if !schema.links.isEmpty {
      files.append(GeneratedFile(
        name: "Links.swift",
        content: generator.generateLinks(from: schema)
      ))
    }
    
    // Generate rooms file if there are rooms
    if !schema.rooms.isEmpty {
      files.append(GeneratedFile(
        name: "Rooms.swift",
        content: generator.generateRooms(from: schema)
      ))
    }
    
    return files
  }
  
  // MARK: - Entity Generation
  
  private func generateEntities(from schema: SchemaIR) -> String {
    // Pick a good example entity (prefer one without $ prefix)
    let exampleEntity = schema.entities.first { !$0.name.hasPrefix("$") } ?? schema.entities.first
    let entityName = exampleEntity?.swiftTypeName ?? "Entity"
    let schemaName = exampleEntity?.name ?? "entities"
    
    // Build the fields for the example initializer
    var exampleFields = ""
    if let entity = exampleEntity {
      for field in entity.fields {
        if !field.isOptional {
          let value: String
          switch field.type {
          case .string: value = "\"\(field.name.capitalized) value\""
          case .number, .integer, .date: value = "Date().timeIntervalSince1970"
          case .boolean: value = "false"
          case .json: value = "nil"
          }
          exampleFields += "\n      \(field.name): \(value),"
        }
      }
      // Remove trailing comma
      if exampleFields.hasSuffix(",") {
        exampleFields = String(exampleFields.dropLast())
      }
    }
    
    let fileDescription = """
    This file contains Swift structs for each entity in your InstantDB schema.
    These structs conform to `EntityIdentifiable`, `Codable`, and `Sendable`,
    making them ready for use with `@Shared` and `@SharedReader`.

    Each entity has:
    • An `id` field (auto-generated UUID by default)
    • All fields from your schema with proper Swift types
    • Optional link properties (populated when using `.with()` queries)
    • A memberwise initializer with sensible defaults
    """
    
    let howToUse = """
    Create entities using the generated initializers, then add them to
    synced collections using `$collection.withLock { }`.

    • Create: `let item = \(entityName)(...)`
    • Add: `$items.withLock { $0.append(item) }`
    • Update: `$items.withLock { $0[index].field = newValue }`
    • Delete: `$items.withLock { $0.remove(id: item.id) }`
    """
    
    let quickStart = """
    import SwiftUI
    import SharingInstant
    import IdentifiedCollections

    struct \(entityName)ListContentView: View {
      @Shared(Schema.\(schemaName))
      private var items: IdentifiedArrayOf<\(entityName)> = []

      var body: some View {
        List {
          ForEach(items) { item in
            Text("\\(item.id)")
          }
        }
      }

      private func addItem() {
        let item = \(entityName)(\(exampleFields)
        )
        $items.withLock { $0.append(item) }
      }

      private func deleteItem(_ item: \(entityName)) {
        $items.withLock { $0.remove(id: item.id) }
      }
    }
    """
    
    // Build available entities listing
    var availableItems = ""
    for entity in schema.entities {
      availableItems += formatEntityListing(entity, schema: schema) + "\n///\n"
    }
    
    var output = fileHeader(
      "Entities.swift",
      schema: schema,
      fileDescription: fileDescription,
      howToUse: howToUse,
      quickStart: quickStart,
      availableItems: availableItems
    )
    
    output += """
    import Foundation
    import InstantDB
    import SharingInstant
    
    
    """
    
    // Collect all generic types that need to be generated
    var generatedTypes: Set<String> = []
    
    // Helper function to collect types recursively from a generic type
    func collectAndGenerateTypes(from genericType: GenericTypeIR, fieldName: String, entityName: String) {
      switch genericType {
      case .stringUnion, .object:
        // Generate type from field name
        let typeName = swiftTypeForGeneric(genericType, fieldName: fieldName, entityName: entityName)
        if !generatedTypes.contains(typeName) {
          generatedTypes.insert(typeName)
          output += generateTypeFromGeneric(genericType, typeName: typeName)
          output += "\n"
        }
        
      case .array(let elementType):
        // Recursively collect the element type
        collectAndGenerateTypes(from: elementType, fieldName: fieldName, entityName: entityName)
        
      case .typeAlias(let name, let definition):
        // Use the alias name and generate the definition
        if !generatedTypes.contains(name) {
          generatedTypes.insert(name)
          output += generateTypeFromGeneric(definition, typeName: name)
          output += "\n"
        }
        
      case .unresolved:
        // Unresolved types shouldn't reach code generation
        break
      }
    }
    
    // Generate enums and structs from generic types
    for entity in schema.entities {
      for field in entity.fields {
        if let genericType = field.genericType {
          collectAndGenerateTypes(from: genericType, fieldName: field.name, entityName: entity.swiftTypeName)
        }
      }
    }

    let indirectLinkLabelsByEntityName = indirectLinkLabelsByEntityName(for: schema)
    
    for entity in schema.entities {
      let indirectLabels = indirectLinkLabelsByEntityName[entity.name] ?? []
      output += generateEntity(entity, schema: schema, indirectLinkLabels: indirectLabels)
      output += "\n\n"
    }
    
    return output
  }
  
  private func generateEntity(_ entity: EntityIR, schema: SchemaIR, indirectLinkLabels: Set<String>) -> String {
    let access = configuration.accessLevel.rawValue
    let sendable = configuration.generateSendable ? ", Sendable" : ""
    
    var output = ""
    
    // Documentation
    if configuration.includeDocumentation, let doc = entity.documentation {
      output += formatDocumentation(doc)
    }
    
    // Struct declaration
    // Equatable is needed for SwiftUI's .onChange(of:) modifier to work with entity collections
    output += """
    \(access) struct \(entity.swiftTypeName): EntityIdentifiable, Codable\(sendable), Equatable {
      \(access) static var namespace: String { "\(entity.name)" }
      
      // MARK: - Fields
      
      /// The unique identifier for this entity
      \(access) var id: String
    
    """
    
    // Fields
    for field in entity.fields {
      output += generateField(field, entityTypeName: entity.swiftTypeName)
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
          documentation: "Link to \(link.reverse.entityName) via '\(link.name)'",
          usesIndirectLink: indirectLinkLabels.contains(link.forward.label)
        )
      }
      
      for link in reverseLinks {
        output += generateLinkProperty(
          label: link.reverse.label,
          targetEntity: schema.entity(named: link.forward.entityName),
          cardinality: link.reverse.cardinality,
          documentation: "Link to \(link.forward.entityName) via '\(link.name)'",
          usesIndirectLink: indirectLinkLabels.contains(link.reverse.label)
        )
      }
    }
    
    // Initializer
    output += generateInitializer(entity, schema: schema)
    
    output += "}\n"
    
    return output
  }
  
  private func generateField(_ field: FieldIR, entityTypeName: String) -> String {
    let access = configuration.accessLevel.rawValue
    var output = ""
    
    // Documentation
    if configuration.includeDocumentation, let doc = field.documentation {
      output += "  " + formatDocumentation(doc, indent: "  ")
    }
    
    // Determine the Swift type based on generic type info
    let swiftType = swiftTypeForField(field, entityTypeName: entityTypeName)
    
    // Property declaration
    let optionalMark = field.isOptional ? "?" : ""
    output += "  \(access) var \(field.name): \(swiftType)\(optionalMark)\n"
    
    return output
  }
  
  /// Determine the Swift type for a field, considering generic type info
  private func swiftTypeForField(_ field: FieldIR, entityTypeName: String) -> String {
    guard let genericType = field.genericType else {
      return field.type.swiftType
    }
    
    return swiftTypeForGeneric(genericType, fieldName: field.name, entityName: entityTypeName)
  }
  
  /// Determine the Swift type for a generic type
  /// 
  /// For inline types (stringUnion, object), generates a name from the entity and field names.
  /// For type aliases, uses the preserved alias name.
  private func swiftTypeForGeneric(_ genericType: GenericTypeIR, fieldName: String, entityName: String) -> String {
    switch genericType {
    case .stringUnion:
      // Generate enum name from entity name + field name for inline types
      // e.g., tasks.status → TaskStatus
      if !entityName.isEmpty {
        let fieldPart = fieldName.prefix(1).uppercased() + fieldName.dropFirst()
        return entityName + fieldPart
      }
      return fieldName.prefix(1).uppercased() + fieldName.dropFirst()
      
    case .object:
      // Generate struct name from entity name + field name for inline types
      // e.g., tasks.metadata → TaskMetadata
      if !entityName.isEmpty {
        let fieldPart = fieldName.prefix(1).uppercased() + fieldName.dropFirst()
        return entityName + fieldPart
      }
      return fieldName.prefix(1).uppercased() + fieldName.dropFirst()
      
    case .array(let elementType):
      let elementSwiftType = swiftTypeForGeneric(elementType, fieldName: fieldName, entityName: entityName)
      return "[\(elementSwiftType)]"
      
    case .unresolved(let typeName):
      return typeName
      
    case .typeAlias(let name, _):
      // Use the preserved type alias name
      return name
    }
  }
  
  /// Generate Swift type (enum or struct) from a generic type
  private func generateTypeFromGeneric(_ genericType: GenericTypeIR, typeName: String) -> String {
    let access = configuration.accessLevel.rawValue
    let sendable = configuration.generateSendable ? ", Sendable" : ""
    
    switch genericType {
    case .stringUnion(let cases):
      return generateEnumFromStringUnion(cases, typeName: typeName, access: access, sendable: sendable)
      
    case .object(let fields):
      return generateStructFromObject(fields, typeName: typeName, access: access, sendable: sendable)
      
    case .array:
      // Arrays don't generate new types - they wrap existing types
      return ""
      
    case .unresolved:
      // Unresolved types shouldn't reach code generation
      return ""
      
    case .typeAlias(let name, let definition):
      // Generate the type with the alias name
      return generateTypeFromGeneric(definition, typeName: name)
    }
  }
  
  /// Generate a Swift enum from a string union
  private func generateEnumFromStringUnion(_ cases: [String], typeName: String, access: String, sendable: String) -> String {
    var output = "/// Generated enum for string union type\n"
    output += "\(access) enum \(typeName): String, Codable\(sendable), Equatable {\n"
    
    for caseName in cases {
      // Convert snake_case to camelCase for Swift
      let swiftCaseName = snakeToCamelCase(caseName)
      
      // If the case name differs from the raw value, include the raw value
      if swiftCaseName != caseName {
        output += "  case \(swiftCaseName) = \"\(caseName)\"\n"
      } else {
        output += "  case \(swiftCaseName)\n"
      }
    }
    
    output += "}\n"
    return output
  }
  
  /// Generate a Swift struct from an object type
  private func generateStructFromObject(_ fields: [ObjectFieldIR], typeName: String, access: String, sendable: String) -> String {
    var output = "/// Generated struct for JSON object type\n"
    output += "\(access) struct \(typeName): Codable\(sendable), Equatable {\n"
    
    // Generate properties
    for field in fields {
      let swiftType = swiftTypeForObjectField(field)
      let optionalMark = field.isOptional ? "?" : ""
      output += "  \(access) var \(field.name): \(swiftType)\(optionalMark)\n"
    }
    
    // Generate initializer
    output += "\n  \(access) init(\n"
    for (index, field) in fields.enumerated() {
      let swiftType = swiftTypeForObjectField(field)
      let optionalMark = field.isOptional ? "?" : ""
      let defaultValue = field.isOptional ? " = nil" : ""
      let comma = index < fields.count - 1 ? "," : ""
      output += "    \(field.name): \(swiftType)\(optionalMark)\(defaultValue)\(comma)\n"
    }
    output += "  ) {\n"
    for field in fields {
      output += "    self.\(field.name) = \(field.name)\n"
    }
    output += "  }\n"
    
    output += "}\n"
    return output
  }
  
  /// Get Swift type for an object field
  private func swiftTypeForObjectField(_ field: ObjectFieldIR) -> String {
    if let nestedType = field.genericType {
      return swiftTypeForGeneric(nestedType, fieldName: field.name, entityName: "")
    }
    return field.type.swiftType
  }
  
  /// Convert snake_case to camelCase
  private func snakeToCamelCase(_ input: String) -> String {
    let parts = input.split(separator: "_")
    guard let first = parts.first else { return input }
    
    let rest = parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }
    return String(first) + rest.joined()
  }
  
  private func generateLinkProperty(
    label: String,
    targetEntity: EntityIR?,
    cardinality: Cardinality,
    documentation: String,
    usesIndirectLink: Bool
  ) -> String {
    let access = configuration.accessLevel.rawValue
    guard let target = targetEntity else { return "" }
    
    var output = ""
    
    if configuration.includeDocumentation {
      output += "  /// \(documentation)\n"
      output += "  /// - Note: Only populated when queried with `.with(\\.\(label))`\n"
    }

    if usesIndirectLink {
      output += "  @IndirectLink\n"
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

  // MARK: - Recursive Link Detection

  /// Returns a map of `entityName -> link labels` that must be stored indirectly to avoid
  /// recursive value-type cycles in generated entity structs.
  ///
  /// Swift `struct`s cannot contain themselves (directly or indirectly) through `Optional`,
  /// because `Optional` stores its payload inline. A schema with a has-one cycle like:
  /// - `Segment.parent -> Segment`, or
  /// - `A.oneB -> B.oneA`
  ///
  /// will fail to compile unless at least one has-one link in the cycle is made indirect.
  ///
  /// InstantSchemaCodegen resolves this by applying `@IndirectLink` to has-one link
  /// properties that participate in a cycle in the has-one graph.
  private func indirectLinkLabelsByEntityName(for schema: SchemaIR) -> [String: Set<String>] {
    struct HasOneEdge: Hashable {
      var fromEntityName: String
      var toEntityName: String
      var label: String
    }

    var edges: [HasOneEdge] = []
    edges.reserveCapacity(schema.links.count * 2)

    for link in schema.links {
      if link.forward.cardinality == .one {
        edges.append(
          HasOneEdge(
            fromEntityName: link.forward.entityName,
            toEntityName: link.reverse.entityName,
            label: link.forward.label
          )
        )
      }

      if link.reverse.cardinality == .one {
        edges.append(
          HasOneEdge(
            fromEntityName: link.reverse.entityName,
            toEntityName: link.forward.entityName,
            label: link.reverse.label
          )
        )
      }
    }

    var adjacency: [String: [HasOneEdge]] = [:]
    for edge in edges {
      adjacency[edge.fromEntityName, default: []].append(edge)
    }

    let allNodes = Set(schema.entities.map(\.name))
      .union(edges.map(\.fromEntityName))
      .union(edges.map(\.toEntityName))

    var index = 0
    var indices: [String: Int] = [:]
    var lowlinks: [String: Int] = [:]
    var stack: [String] = []
    var onStack: Set<String> = []
    var stronglyConnectedComponents: [[String]] = []

    func strongConnect(_ node: String) {
      indices[node] = index
      lowlinks[node] = index
      index += 1

      stack.append(node)
      onStack.insert(node)

      for edge in adjacency[node] ?? [] {
        let neighbor = edge.toEntityName

        if indices[neighbor] == nil {
          strongConnect(neighbor)
          lowlinks[node] = min(lowlinks[node] ?? 0, lowlinks[neighbor] ?? 0)
        } else if onStack.contains(neighbor) {
          lowlinks[node] = min(lowlinks[node] ?? 0, indices[neighbor] ?? 0)
        }
      }

      guard lowlinks[node] == indices[node] else { return }

      var component: [String] = []
      while let last = stack.popLast() {
        onStack.remove(last)
        component.append(last)

        if last == node {
          break
        }
      }

      stronglyConnectedComponents.append(component)
    }

    for node in allNodes.sorted() {
      if indices[node] == nil {
        strongConnect(node)
      }
    }

    var labelsByEntityName: [String: Set<String>] = [:]

    for component in stronglyConnectedComponents {
      let componentSet = Set(component)

      if component.count > 1 {
        for edge in edges where componentSet.contains(edge.fromEntityName) && componentSet.contains(edge.toEntityName) {
          labelsByEntityName[edge.fromEntityName, default: []].insert(edge.label)
        }
        continue
      }

      guard let onlyNode = component.first else { continue }

      for edge in edges where edge.fromEntityName == onlyNode && edge.toEntityName == onlyNode {
        labelsByEntityName[edge.fromEntityName, default: []].insert(edge.label)
      }
    }

    return labelsByEntityName
  }
  
  private func generateInitializer(_ entity: EntityIR, schema: SchemaIR) -> String {
    let access = configuration.accessLevel.rawValue
    var output = "\n  // MARK: - Initializer\n\n"
    
    // Collect all properties
    var params: [(name: String, type: String, defaultValue: String?)] = []
    
    // ID
    params.append((name: "id", type: "String", defaultValue: "UUID().uuidString.lowercased()"))
    
    // Fields
    for field in entity.fields {
      let type = swiftTypeForField(field, entityTypeName: entity.swiftTypeName) + (field.isOptional ? "?" : "")
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
    
    // Generate custom Codable implementation if entity has Bool or Double fields
    // InstantDB sometimes returns numbers as bools and vice versa
    let hasBoolField = entity.fields.contains { $0.type == .boolean }
    let hasNumberField = entity.fields.contains { $0.type == .number }
    
    if hasBoolField || hasNumberField {
      output += generateCustomCodable(entity, schema: schema, forwardLinks: forwardLinks, reverseLinks: reverseLinks)
    }
    
    return output
  }
  
  /// Generates custom Codable implementation to handle InstantDB's type quirks.
  ///
  /// InstantDB's server sometimes returns:
  /// - Numbers (0/1) for boolean fields instead of true/false
  /// - Booleans (false) for numeric fields instead of 0
  ///
  /// This generates a custom decoder that uses FlexibleBool and FlexibleDouble
  /// to handle these cases transparently.
  private func generateCustomCodable(_ entity: EntityIR, schema: SchemaIR, forwardLinks: [LinkIR], reverseLinks: [LinkIR]) -> String {
    let access = configuration.accessLevel.rawValue
    var output = "\n  // MARK: - Custom Codable (handles InstantDB type quirks)\n\n"
    
    // CodingKeys enum
    output += "  private enum CodingKeys: String, CodingKey {\n"
    output += "    case id"
    for field in entity.fields {
      output += ", \(field.name)"
    }
    for link in forwardLinks {
      output += ", \(link.forward.label)"
    }
    for link in reverseLinks {
      output += ", \(link.reverse.label)"
    }
    output += "\n  }\n\n"
    
    // Custom init(from decoder:)
    output += "  \(access) init(from decoder: Decoder) throws {\n"
    output += "    let container = try decoder.container(keyedBy: CodingKeys.self)\n"
    output += "    self.id = try container.decode(String.self, forKey: .id)\n"
    
    for field in entity.fields {
      let fieldName = field.name
      if field.isOptional {
        switch field.type {
        case .boolean:
          output += "    if let flexValue = try container.decodeIfPresent(FlexibleBool.self, forKey: .\(fieldName)) {\n"
          output += "      self.\(fieldName) = flexValue.wrappedValue\n"
          output += "    } else {\n"
          output += "      self.\(fieldName) = nil\n"
          output += "    }\n"
        case .number:
          output += "    if let flexValue = try container.decodeIfPresent(FlexibleDouble.self, forKey: .\(fieldName)) {\n"
          output += "      self.\(fieldName) = flexValue.wrappedValue\n"
          output += "    } else {\n"
          output += "      self.\(fieldName) = nil\n"
          output += "    }\n"
        default:
          output += "    self.\(fieldName) = try container.decodeIfPresent(\(field.type.swiftType).self, forKey: .\(fieldName))\n"
        }
      } else {
        switch field.type {
        case .boolean:
          output += "    self.\(fieldName) = try container.decode(FlexibleBool.self, forKey: .\(fieldName)).wrappedValue\n"
        case .number:
          output += "    self.\(fieldName) = try container.decode(FlexibleDouble.self, forKey: .\(fieldName)).wrappedValue\n"
        default:
          output += "    self.\(fieldName) = try container.decode(\(field.type.swiftType).self, forKey: .\(fieldName))\n"
        }
      }
    }
    
    // Decode links
    for link in forwardLinks {
      if let target = schema.entity(named: link.reverse.entityName) {
        let label = link.forward.label
        if link.forward.cardinality == .one {
          output += "    self.\(label) = try container.decodeIfPresent(\(target.swiftTypeName).self, forKey: .\(label))\n"
        } else {
          output += "    self.\(label) = try container.decodeIfPresent([\(target.swiftTypeName)].self, forKey: .\(label))\n"
        }
      }
    }
    
    for link in reverseLinks {
      if let target = schema.entity(named: link.forward.entityName) {
        let label = link.reverse.label
        if link.reverse.cardinality == .one {
          output += "    self.\(label) = try container.decodeIfPresent(\(target.swiftTypeName).self, forKey: .\(label))\n"
        } else {
          output += "    self.\(label) = try container.decodeIfPresent([\(target.swiftTypeName)].self, forKey: .\(label))\n"
        }
      }
    }
    
    output += "  }\n"
    
    return output
  }
  
  // MARK: - Schema Generation
  
  private func generateSchema(from schema: SchemaIR) -> String {
    // Pick a good example entity (prefer one without $ prefix)
    let exampleEntity = schema.entities.first { !$0.name.hasPrefix("$") } ?? schema.entities.first
    let entityName = exampleEntity?.swiftTypeName ?? "Entity"
    let schemaName = exampleEntity?.name ?? "entities"
    let firstField = exampleEntity?.fields.first?.name ?? "field"
    
    let fileDescription = """
    This file defines the `Schema` namespace containing type-safe `EntityKey`
    instances for each entity in your InstantDB schema. EntityKeys enable:

    • Compile-time type safety - no string literals for namespace names
    • Autocomplete support - `Schema.` shows all available entities
    • Chainable query modifiers - `.orderBy()`, `.where()`, `.limit()`
    • Bidirectional sync with `@Shared` or read-only queries with `@SharedReader`
    """
    
    let howToUse = """
    Use `Schema.<entityName>` with `@Shared` for bidirectional sync:

      @Shared(Schema.\(schemaName))
      private var items: IdentifiedArrayOf<\(entityName)> = []

    Chain modifiers for ordering, filtering, and limiting:

      Schema.\(schemaName).orderBy(\\.\(firstField), .desc)
      Schema.\(schemaName).where(\\.\(firstField), .eq("value"))
      Schema.\(schemaName).limit(10)
    """
    
    let quickStart = """
    import SwiftUI
    import SharingInstant
    import IdentifiedCollections

    struct \(entityName)ContentView: View {
      /// Bidirectional sync with InstantDB - changes sync automatically!
      @Shared(Schema.\(schemaName).orderBy(\\.\(firstField), .desc))
      private var items: IdentifiedArrayOf<\(entityName)> = []

      @State private var newValue = ""

      var body: some View {
        NavigationStack {
          List {
            Section("Add New") {
              HStack {
                TextField("Enter value", text: $newValue)
                Button("Add") { addItem() }
                  .disabled(newValue.isEmpty)
              }
            }

            Section("Items (\\(items.count))") {
              ForEach(items) { item in
                Text("\\(item.id)")
              }
              .onDelete { indexSet in
                $items.withLock { items in
                  for index in indexSet {
                    items.remove(at: index)
                  }
                }
              }
            }
          }
          .navigationTitle("\(entityName)s")
        }
      }

      private func addItem() {
        // Create and add - syncs automatically!
        let item = \(entityName)(/* ... */)
        $items.withLock { $0.append(item) }
        newValue = ""
      }
    }
    """
    
    // Build available entities listing with Schema. prefix
    var availableItems = ""
    for entity in schema.entities {
      availableItems += "/// Schema.\(entity.swiftPropertyName) → \(entity.swiftTypeName) {\n"
      availableItems += "///   id: String\n"
      for field in entity.fields {
        let optionalMark = field.isOptional ? "?" : ""
        availableItems += "///   \(field.name): \(field.type.swiftType)\(optionalMark)\n"
      }
      if entity.isSystemEntity {
        availableItems += "///   // Note: InstantDB system entity\n"
      }
      availableItems += "/// }\n///\n"
    }
    
    var output = fileHeader(
      "Schema.swift",
      schema: schema,
      fileDescription: fileDescription,
      howToUse: howToUse,
      quickStart: quickStart,
      availableItems: availableItems
    )
    
    output += """
    import Foundation
    import InstantDB
    import IdentifiedCollections
    import SharingInstant
    
    // MARK: - Schema Namespace
    
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
      if entity.isSystemEntity {
        output += "  /// - Note: This is an InstantDB system entity.\n"
      }
      if let doc = entity.documentation {
        output += "  ///\n"
        output += "  /// \(doc.replacingOccurrences(of: "\n", with: "\n  /// "))\n"
      }
    }
    
    output += "  \(access) static let \(entity.swiftPropertyName) = EntityKey<\(entity.swiftTypeName)>(namespace: \"\(entity.name)\")\n\n"
    
    return output
  }
  
  
  // MARK: - Links Generation
  
  private func generateLinks(from schema: SchemaIR) -> String {
    // Find a good example link (prefer one not involving system entities)
    let exampleLink = schema.links.first { !$0.involvesSystemEntity } ?? schema.links.first
    let fromEntity = exampleLink.flatMap { schema.entity(named: $0.forward.entityName) }
    let fromName = fromEntity?.swiftTypeName ?? "Entity"
    let fromSchemaName = fromEntity?.swiftPropertyName ?? "entities"
    let linkLabel = exampleLink?.forward.label ?? "related"
    
    let fileDescription = """
    This file defines link metadata for relationships between entities. Links in
    InstantDB are bidirectional - when you link A to B, B is automatically linked
    back to A.

    Links enable:
    • Type-safe relationship traversal with `.with(\\.<linkName>)`
    • Automatic foreign key management
    • Cascade delete behavior (when configured)
    """
    
    let howToUse = """
    Include linked entities in your queries using the `.with()` modifier:

      Schema.\(fromSchemaName).with(\\.\(linkLabel))

    Chain multiple links:

      Schema.\(fromSchemaName).with(\\.\(linkLabel)).with(\\.otherLink)

    The compiler ensures you only request links that actually exist!
    """
    
    // Build type safety example
    var typeSafetyExample = """
    /// TYPE SAFETY EXAMPLES
    ///
    /// The link system is fully type-safe. The compiler catches errors at build time:
    ///
    """
    
    if let link = exampleLink, let from = fromEntity {
      typeSafetyExample += """
      
      /// ✅ COMPILES - \(link.forward.label) exists on \(from.swiftTypeName):
      ///    Schema.\(from.swiftPropertyName).with(\\.\(link.forward.label))
      ///
      /// ❌ COMPILE ERROR - "nonexistent" is not a link on \(from.swiftTypeName):
      ///    Schema.\(from.swiftPropertyName).with(\\.nonexistent)
      ///    // Error: Type '\(from.swiftTypeName)' has no member 'nonexistent'
      ///
      """
    }
    
    let quickStart = """
    import SwiftUI
    import SharingInstant
    import IdentifiedCollections

    struct \(fromName)WithLinksView: View {
      /// Query \(fromName.lowercased())s and include their linked \(linkLabel)
      @Shared(Schema.\(fromSchemaName).with(\\.\(linkLabel)))
      private var items: IdentifiedArrayOf<\(fromName)> = []

      var body: some View {
        List(items) { item in
          VStack(alignment: .leading, spacing: 8) {
            Text("\\(item.id)")
              .font(.headline)

            // Type-safe access to linked entity!
            // This is Optional because the link may not exist
            if let linked = item.\(linkLabel) {
              HStack {
                Image(systemName: "link")
                Text("Linked: \\(linked.id)")
              }
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
    """
    
    // Build available links listing
    var availableItems = typeSafetyExample + "\n///\n"
    for link in schema.links {
      let fromType = schema.entity(named: link.forward.entityName)?.swiftTypeName ?? "Unknown"
      let toType = schema.entity(named: link.reverse.entityName)?.swiftTypeName ?? "Unknown"
      let forwardType = link.forward.cardinality == .one ? "\(toType)?" : "[\(toType)]?"
      let reverseType = link.reverse.cardinality == .one ? "\(fromType)?" : "[\(fromType)]?"
      
      availableItems += """
      
      /// \(link.name) {
      ///   name: "\(link.name)"
      ///
      ///   forward: {
      ///     on: \(fromType)
      ///     label: "\(link.forward.label)"
      ///     has: \(link.forward.cardinality.rawValue)
      ///   }
      ///   // Access: \(fromType).\(link.forward.label) → \(forwardType)
      ///
      ///   reverse: {
      ///     on: \(toType)
      ///     label: "\(link.reverse.label)"
      ///     has: \(link.reverse.cardinality.rawValue)
      ///   }
      ///   // Access: \(toType).\(link.reverse.label) → \(reverseType)
      /// }
      ///
      """
    }
    
    var output = fileHeader(
      "Links.swift",
      schema: schema,
      fileDescription: fileDescription,
      howToUse: howToUse,
      quickStart: quickStart,
      availableItems: availableItems
    )
    
    output += """
    import Foundation
    import SharingInstant
    
    // MARK: - Link Definitions
    
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
      if link.involvesSystemEntity {
        output += "  /// - Note: Involves InstantDB system entity.\n"
      }
      if let doc = link.documentation {
        output += "  /// \(doc)\n"
      }
    }
    
    let fromEntity = schema.entity(named: link.forward.entityName)?.swiftTypeName ?? "Unknown"
    let toEntity = schema.entity(named: link.reverse.entityName)?.swiftTypeName ?? "Unknown"
    
    output += """
      \(access) static let \(link.swiftPropertyName) = Link(
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
  
  // MARK: - Rooms Generation
  
  private func generateRooms(from schema: SchemaIR) -> String {
    let access = configuration.accessLevel.rawValue
    
    // Find example room and topic
    let exampleRoom = schema.rooms.first
    let roomName = exampleRoom?.name ?? "room"
    let presenceTypeName = exampleRoom?.presenceTypeName ?? "Presence"
    let presenceFields = exampleRoom?.presence?.fields ?? []
    
    let allTopics = schema.rooms.flatMap { $0.topics }
    let exampleTopic = allTopics.first
    let topicPayloadTypeName = exampleTopic?.payloadTypeName ?? "Payload"
    
    let fileDescription = """
    This file defines type-safe room keys and presence types for real-time features:

    • Presence - See who's online, their cursor positions, typing status, etc.
    • Topics - Fire-and-forget events like emoji reactions, notifications

    Rooms are accessed via `Schema.Rooms.<roomName>` and topics via
    `Schema.Topics.<topicName>`.
    """
    
    // Build presence field initializer example
    var presenceInitFields = ""
    for field in presenceFields {
      let value: String
      switch field.type {
      case .string: value = "\"\""
      case .number, .date: value = "0"
      case .boolean: value = "false"
      default: value = "nil"
      }
      presenceInitFields += "\(field.name): \(value), "
    }
    if presenceInitFields.hasSuffix(", ") {
      presenceInitFields = String(presenceInitFields.dropLast(2))
    }
    
    let howToUse = """
    PRESENCE - Track who's online and their state:

      @Shared(.instantPresence(
        Schema.Rooms.\(roomName),
        roomId: "my-room-id",
        initialPresence: \(presenceTypeName)(\(presenceInitFields))
      ))
      var presence: RoomPresence<\(presenceTypeName)>

    Access presence data:
      presence.user        // Your presence data
      presence.peers       // Other users in the room
      presence.totalCount  // Total users including you

    Update your presence:
      $presence.withLock { $0.user = \(presenceTypeName)(...) }
    """
    
    var quickStart = """
    import SwiftUI
    import SharingInstant

    struct \(presenceTypeName.replacingOccurrences(of: "Presence", with: ""))RoomView: View {
      @Shared(.instantPresence(
        Schema.Rooms.\(roomName),
        roomId: "demo-room",
        initialPresence: \(presenceTypeName)(\(presenceInitFields))
      ))
      private var presence: RoomPresence<\(presenceTypeName)>

      var body: some View {
        VStack {
          Text("People in room: \\(presence.totalCount)")
            .font(.headline)

          // Your presence
          Text("You: \\(presence.user)")
            .font(.caption)

          // Other users
          ForEach(presence.peers) { peer in
            Text("Peer \\(peer.id): \\(peer.data)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .onAppear {
          // Update your presence when view appears
          $presence.withLock { state in
            state.user = \(presenceTypeName)(\(presenceInitFields))
          }
        }
      }
    }
    """
    
    // Add topic example if there are topics
    if let topic = exampleTopic {
      let topicFields = topic.payload.fields
      var topicInitFields = ""
      for field in topicFields {
        let value: String
        switch field.type {
        case .string: value = "\"value\""
        case .number, .date: value = "0"
        case .boolean: value = "false"
        default: value = "nil"
        }
        topicInitFields += "\(field.name): \(value), "
      }
      if topicInitFields.hasSuffix(", ") {
        topicInitFields = String(topicInitFields.dropLast(2))
      }
      
      quickStart += """


    // TOPIC EXAMPLE - Fire-and-forget events:

    struct \(topic.name.capitalized)TopicView: View {
      @Shared(.instantTopic(
        Schema.Topics.\(topic.name),
        roomId: "demo-room"
      ))
      private var channel: TopicChannel<\(topicPayloadTypeName)>

      var body: some View {
        Button("Send Event") {
          channel.publish(\(topicPayloadTypeName)(\(topicInitFields)))
        }
        .onReceive(channel.events) { event in
          print("Received from \\(event.peerId): \\(event.data)")
        }
      }
    }
    """
    }
    
    // Build available rooms listing
    var availableItems = "/// ROOMS:\n///\n"
    for room in schema.rooms.filter({ $0.presence != nil }) {
      availableItems += "/// Schema.Rooms.\(room.name) → \(room.presenceTypeName) {\n"
      if let presence = room.presence {
        for field in presence.fields {
          let optionalMark = field.isOptional ? "?" : ""
          availableItems += "///   \(field.name): \(field.type.swiftType)\(optionalMark)\n"
        }
      }
      availableItems += "/// }\n///\n"
    }
    
    if !allTopics.isEmpty {
      availableItems += "/// TOPICS:\n///\n"
      for topic in allTopics {
        availableItems += "/// Schema.Topics.\(topic.name) → \(topic.payloadTypeName) {\n"
        availableItems += "///   room: \"\(topic.roomName)\"\n"
        availableItems += "///   payload: {\n"
        for field in topic.payload.fields {
          let optionalMark = field.isOptional ? "?" : ""
          availableItems += "///     \(field.name): \(field.type.swiftType)\(optionalMark)\n"
        }
        availableItems += "///   }\n"
        availableItems += "/// }\n///\n"
      }
    }
    
    var output = fileHeader(
      "Rooms.swift",
      schema: schema,
      fileDescription: fileDescription,
      howToUse: howToUse,
      quickStart: quickStart,
      availableItems: availableItems
    )
    
    output += """
    import Foundation
    import SharingInstant
    import InstantDB
    
    
    """
    
    // Generate presence types
    output += "// MARK: - Room Presence Types\n\n"
    for room in schema.rooms {
      if let presence = room.presence {
        output += generatePresenceType(for: room, presence: presence)
        output += "\n"
      }
    }
    
    // Generate topic payload types
    if !allTopics.isEmpty {
      output += "// MARK: - Topic Payload Types\n\n"
      for topic in allTopics {
        output += generateTopicPayloadType(for: topic)
        output += "\n"
      }
    }
    
    // Generate Schema.Rooms namespace
    let roomsWithPresence = schema.rooms.filter { $0.presence != nil }
    if !roomsWithPresence.isEmpty {
      output += """
      // MARK: - Room Keys
      
      \(access) extension Schema {
        /// Type-safe room keys for presence subscriptions.
        enum Rooms {
      
      """
      
      for room in roomsWithPresence {
        output += generateRoomKeyProperty(for: room)
      }
      
      output += "  }\n}\n\n"
    }
    
    // Generate Schema.Topics namespace
    if !allTopics.isEmpty {
      output += """
      // MARK: - Topic Keys
      
      \(access) extension Schema {
        /// Type-safe topic keys for fire-and-forget events.
        enum Topics {
      
      """
      
      for topic in allTopics {
        output += generateTopicKeyProperty(for: topic)
      }
      
      output += "  }\n}\n"
    }
    
    return output
  }
  
  private func generatePresenceType(for room: RoomIR, presence: EntityIR) -> String {
    let access = configuration.accessLevel.rawValue
    let typeName = room.presenceTypeName
    
    var output = ""
    
    if configuration.includeDocumentation {
      output += "/// Presence data for '\(room.name)' room.\n"
      if let doc = room.documentation {
        output += "///\n/// \(doc.replacingOccurrences(of: "\n", with: "\n/// "))\n"
      }
    }
    
    // Use PresenceData protocol which includes Codable, Sendable, Equatable
    output += "\(access) struct \(typeName): PresenceData {\n"
    
    // Fields
    for field in presence.fields {
      let optionalMark = field.isOptional ? "?" : ""
      if configuration.includeDocumentation, let doc = field.documentation {
        output += "  /// \(doc)\n"
      }
      output += "  \(access) var \(field.name): \(field.type.swiftType)\(optionalMark)\n"
    }
    
    // Initializer
    output += "\n  \(access) init(\n"
    for (index, field) in presence.fields.enumerated() {
      let comma = index < presence.fields.count - 1 ? "," : ""
      let optionalMark = field.isOptional ? "?" : ""
      let defaultValue = field.isOptional ? " = nil" : (field.defaultValue.map { " = \($0)" } ?? "")
      output += "    \(field.name): \(field.type.swiftType)\(optionalMark)\(defaultValue)\(comma)\n"
    }
    output += "  ) {\n"
    for field in presence.fields {
      output += "    self.\(field.name) = \(field.name)\n"
    }
    output += "  }\n"
    
    output += "}\n"
    
    return output
  }
  
  private func generateTopicPayloadType(for topic: TopicIR) -> String {
    let access = configuration.accessLevel.rawValue
    let sendable = configuration.generateSendable ? ", Sendable" : ""
    let typeName = topic.payloadTypeName
    
    var output = ""
    
    if configuration.includeDocumentation {
      output += "/// Topic payload for '\(topic.roomName).\(topic.name)' events.\n"
      if let doc = topic.documentation {
        output += "///\n/// \(doc.replacingOccurrences(of: "\n", with: "\n/// "))\n"
      }
    }
    
    output += "\(access) struct \(typeName): Codable\(sendable), Equatable {\n"
    
    // Fields
    for field in topic.payload.fields {
      let optionalMark = field.isOptional ? "?" : ""
      if configuration.includeDocumentation, let doc = field.documentation {
        output += "  /// \(doc)\n"
      }
      output += "  \(access) var \(field.name): \(field.type.swiftType)\(optionalMark)\n"
    }
    
    // Initializer
    output += "\n  \(access) init(\n"
    for (index, field) in topic.payload.fields.enumerated() {
      let comma = index < topic.payload.fields.count - 1 ? "," : ""
      let optionalMark = field.isOptional ? "?" : ""
      let defaultValue = field.isOptional ? " = nil" : (field.defaultValue.map { " = \($0)" } ?? "")
      output += "    \(field.name): \(field.type.swiftType)\(optionalMark)\(defaultValue)\(comma)\n"
    }
    output += "  ) {\n"
    for field in topic.payload.fields {
      output += "    self.\(field.name) = \(field.name)\n"
    }
    output += "  }\n"
    
    output += "}\n"
    
    return output
  }
  
  private func generateRoomKeyProperty(for room: RoomIR) -> String {
    let access = configuration.accessLevel.rawValue
    var output = ""
    
    if configuration.includeDocumentation {
      output += "    /// '\(room.name)' room - presence sync\n"
    }
    
    output += "    \(access) static let \(room.name) = RoomKey<\(room.presenceTypeName)>(type: \"\(room.name)\")\n\n"
    
    return output
  }
  
  private func generateTopicKeyProperty(for topic: TopicIR) -> String {
    let access = configuration.accessLevel.rawValue
    var output = ""
    
    if configuration.includeDocumentation {
      output += "    /// '\(topic.name)' topic in '\(topic.roomName)' room\n"
    }
    
    output += "    \(access) static let \(topic.name) = TopicKey<\(topic.payloadTypeName)>(roomType: \"\(topic.roomName)\", topic: \"\(topic.name)\")\n\n"
    
    return output
  }
  
  // MARK: - Helpers
  
  /// Generate the enhanced file header with generation context
  private func fileHeader(_ filename: String, schema: SchemaIR, fileDescription: String, howToUse: String, quickStart: String, availableItems: String) -> String {
    var output = """
    /// ═══════════════════════════════════════════════════════════════════════════════
    /// \(filename)
    /// Generated by InstantSchemaCodegen
    /// ═══════════════════════════════════════════════════════════════════════════════
    ///
    /// ⚠️  DO NOT EDIT - This file is generated from your InstantDB schema.
    /// Any changes will be overwritten on the next codegen run.
    ///
    /// ─────────────────────────────────────────────────────────────────────────────────
    /// WHAT THIS FILE IS
    /// ─────────────────────────────────────────────────────────────────────────────────
    ///
    \(fileDescription.split(separator: "\n").map { "/// \($0)" }.joined(separator: "\n"))
    ///
    /// ─────────────────────────────────────────────────────────────────────────────────
    /// HOW TO USE
    /// ─────────────────────────────────────────────────────────────────────────────────
    ///
    \(howToUse.split(separator: "\n").map { "/// \($0)" }.joined(separator: "\n"))
    ///
    /// ─────────────────────────────────────────────────────────────────────────────────
    /// QUICK START - Copy & Paste Example
    /// ─────────────────────────────────────────────────────────────────────────────────

    /* Copy-pasteable example:

    \(quickStart)
    */

    ///
    /// ─────────────────────────────────────────────────────────────────────────────────
    /// AVAILABLE IN THIS FILE
    /// ─────────────────────────────────────────────────────────────────────────────────
    ///
    \(availableItems)
    ///
    """
    
    // Add generation info if context is available
    if let ctx = context {
      output += """
      
      /// ─────────────────────────────────────────────────────────────────────────────────
      /// GENERATION INFO
      /// ─────────────────────────────────────────────────────────────────────────────────
      ///
      /// Mode:            \(ctx.modeDescription)
      /// Generated:       \(ctx.formattedDate)
      /// Machine:         \(ctx.machine.formatted)
      /// Generator:       \(ctx.generatorPath)
      /// Source Schema:   \(ctx.sourceSchemaPath)

      /* To regenerate this file, run:

      \(formatCommand(ctx.commandOrDescription))
      */

      """
      
      // Add git state only for production mode
      if case .production(let prodCtx) = ctx.mode {
        output += """
        /// ─────────────────────────────────────────────────────────────────────────────────
        /// GIT STATE AT GENERATION
        /// ─────────────────────────────────────────────────────────────────────────────────
        ///
        /// HEAD Commit:
        ///   SHA:      \(prodCtx.gitState.headCommit.sha)
        ///   Date:     \(prodCtx.gitState.headCommit.formattedDate(timezone: ctx.timezone))
        ///   Author:   \(prodCtx.gitState.headCommit.author)
        ///   Message:  \(prodCtx.gitState.headCommit.message)
        ///
        /// Schema File Last Modified:
        ///   SHA:      \(prodCtx.gitState.schemaLastModified.sha)
        ///   Date:     \(prodCtx.gitState.schemaLastModified.formattedDate(timezone: ctx.timezone))
        ///   Author:   \(prodCtx.gitState.schemaLastModified.author)
        ///   Message:  \(prodCtx.gitState.schemaLastModified.message)
        ///
        """
      }
    }
    
    output += """
    
    /// ═══════════════════════════════════════════════════════════════════════════════

    
    """
    
    return output
  }
  
  /// Format the command for display with line continuation
  private func formatCommand(_ command: String) -> String {
    // Split into parts and format with backslash continuation
    let parts = command.split(separator: " ")
    var lines: [String] = []
    var currentLine = ""
    
    for (index, part) in parts.enumerated() {
      if part.hasPrefix("--") && !currentLine.isEmpty {
        lines.append(currentLine + " \\")
        currentLine = "  \(part)"
      } else {
        if currentLine.isEmpty {
          currentLine = String(part)
        } else {
          currentLine += " \(part)"
        }
      }
      
      if index == parts.count - 1 {
        lines.append(currentLine)
      }
    }
    
    return lines.joined(separator: "\n")
  }
  
  /// Generate JSON-style entity listing for headers
  private func formatEntityListing(_ entity: EntityIR, schema: SchemaIR) -> String {
    var output = "/// \(entity.swiftTypeName) {\n"
    output += "///   id: String\n"
    
    for field in entity.fields {
      let optionalMark = field.isOptional ? "?" : ""
      output += "///   \(field.name): \(field.type.swiftType)\(optionalMark)\n"
    }
    
    // Add link properties
    let forwardLinks = schema.links.filter { $0.forward.entityName == entity.name }
    let reverseLinks = schema.links.filter { $0.reverse.entityName == entity.name }
    
    for link in forwardLinks {
      if let target = schema.entity(named: link.reverse.entityName) {
        let type = link.forward.cardinality == .one ? "\(target.swiftTypeName)?" : "[\(target.swiftTypeName)]?"
        output += "///   \(link.forward.label): \(type)  // Link (has: \(link.forward.cardinality.rawValue))\n"
      }
    }
    
    for link in reverseLinks {
      if let target = schema.entity(named: link.forward.entityName) {
        let type = link.reverse.cardinality == .one ? "\(target.swiftTypeName)?" : "[\(target.swiftTypeName)]?"
        output += "///   \(link.reverse.label): \(type)  // Link (has: \(link.reverse.cardinality.rawValue))\n"
      }
    }
    
    output += "/// }"
    return output
  }
  
  private func formatDocumentation(_ doc: String, indent: String = "") -> String {
    let lines = doc.components(separatedBy: .newlines)
    return lines.map { "\(indent)/// \($0)" }.joined(separator: "\n") + "\n"
  }
}
