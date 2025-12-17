// InstantDBAPI.swift
// InstantSchemaCodegen
//
// Client for fetching schemas from InstantDB's Admin API.

import Foundation

// MARK: - InstantDB API Client

/// Client for interacting with InstantDB's Admin API.
///
/// Used to fetch deployed schemas for validation against local schemas.
///
/// ## Usage
///
/// ```swift
/// let api = InstantDBAPI(adminToken: "your-admin-token")
/// let schema = try await api.fetchSchema(appID: "your-app-id")
/// ```
public struct InstantDBAPI: Sendable {
  
  /// The admin token for API authentication
  public let adminToken: String
  
  /// Base URL for the InstantDB API
  public let baseURL: URL
  
  /// Initialize with admin token
  public init(adminToken: String, baseURL: URL = URL(string: "https://api.instantdb.com")!) {
    self.adminToken = adminToken
    self.baseURL = baseURL
  }
  
  // MARK: - Schema Fetching
  
  /// Fetch the deployed schema for an app
  public func fetchSchema(appID: String) async throws -> SchemaIR {
    // The InstantDB CLI uses /dash/apps/{appId}/schema/pull endpoint
    let url = baseURL.appendingPathComponent("dash/apps/\(appID)/schema/pull")
    
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(adminToken, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse else {
      throw InstantDBAPIError.invalidResponse
    }
    
    guard httpResponse.statusCode == 200 else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw InstantDBAPIError.httpError(statusCode: httpResponse.statusCode, body: body)
    }
    
    // Parse the JSON response into SchemaIR
    let apiSchema = try JSONDecoder().decode(APISchemaResponse.self, from: data)
    return try convertToSchemaIR(apiSchema)
  }
  
  /// Fetch raw schema JSON for debugging
  public func fetchSchemaJSON(appID: String) async throws -> Data {
    let url = baseURL.appendingPathComponent("dash/apps/\(appID)/schema/pull")
    
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(adminToken, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse else {
      throw InstantDBAPIError.invalidResponse
    }
    
    guard httpResponse.statusCode == 200 else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw InstantDBAPIError.httpError(statusCode: httpResponse.statusCode, body: body)
    }
    
    return data
  }
  
  // MARK: - Response Parsing
  
  private func convertToSchemaIR(_ apiSchema: APISchemaResponse) throws -> SchemaIR {
    var schema = SchemaIR()
    
    // Convert entities from blobs
    // Each blob is an entity, and its keys are the attribute names
    if let blobs = apiSchema.schema?.blobs {
      for (entityName, attrs) in blobs {
        var fields: [FieldIR] = []
        
        for (attrName, attr) in attrs {
          // Skip the id field - it's automatic
          if attrName == "id" { continue }
          
          // Skip ref types - those are links, not fields
          if attr.valueType == "ref" { continue }
          
          let fieldType = mapAPIType(attr.inferredTypes?.first)
          fields.append(FieldIR(
            name: attrName,
            type: fieldType,
            isOptional: !(attr.isRequired ?? false),
            documentation: nil
          ))
        }
        
        schema.entities.append(EntityIR(
          name: entityName,
          fields: fields,
          documentation: nil
        ))
      }
    }
    
    // Convert links from refs
    // Ref names are like ["$users" "linkedPrimaryUser" "$users" "linkedGuestUsers"]
    if let refs = apiSchema.schema?.refs {
      for (refName, ref) in refs {
        // Parse the ref name which is a JSON array like ["entity1", "label1", "entity2", "label2"]
        guard let forwardIdentity = ref.forwardIdentity,
              let reverseIdentity = ref.reverseIdentity,
              forwardIdentity.count >= 3,
              reverseIdentity.count >= 3 else {
          continue
        }
        
        // Forward: [_, entityName, label]
        // Reverse: [_, entityName, label]
        let forwardEntity = forwardIdentity[1]
        let forwardLabel = forwardIdentity[2]
        let reverseEntity = reverseIdentity[1]
        let reverseLabel = reverseIdentity[2]
        
        // Determine cardinality
        let forwardCardinality: Cardinality = ref.cardinality == "many" ? .many : .one
        let reverseCardinality: Cardinality = .many // Reverse is typically many
        
        // Create a readable link name
        let linkName = "\(forwardEntity)_\(forwardLabel)"
        
        schema.links.append(LinkIR(
          name: linkName,
          forward: LinkSide(
            entityName: forwardEntity,
            cardinality: forwardCardinality,
            label: forwardLabel
          ),
          reverse: LinkSide(
            entityName: reverseEntity,
            cardinality: reverseCardinality,
            label: reverseLabel
          ),
          documentation: nil
        ))
      }
    }
    
    return schema
  }
  
  private func mapAPIType(_ type: String?) -> FieldType {
    switch type?.lowercased() {
    case "string": return .string
    case "number": return .number
    case "boolean", "bool": return .boolean
    case "date": return .date
    case "json", "any", "object": return .json
    default: return .string // Default to string for unknown types
    }
  }
}

// MARK: - API Response Types

/// Response from /dash/apps/{appId}/schema/pull
struct APISchemaResponse: Codable {
  let schema: APISchema?
  let attrs: [APIAttribute]?
  let appTitle: String?
  
  enum CodingKeys: String, CodingKey {
    case schema
    case attrs
    case appTitle = "app-title"
  }
}

struct APISchema: Codable {
  /// Entity definitions - key is entity name, value is attributes dict
  let blobs: [String: [String: APIAttribute]]?
  /// Link definitions
  let refs: [String: APIRef]?
}

struct APIAttribute: Codable {
  let id: String?
  let valueType: String?
  let isRequired: Bool?
  let isIndexed: Bool?
  let isUnique: Bool?
  let cardinality: String?
  let inferredTypes: [String]?
  let catalog: String?
  let forwardIdentity: [String]?
  let reverseIdentity: [String]?
  let checkedDataType: String?
  
  enum CodingKeys: String, CodingKey {
    case id
    case valueType = "value-type"
    case isRequired = "required?"
    case isIndexed = "index?"
    case isUnique = "unique?"
    case cardinality
    case inferredTypes = "inferred-types"
    case catalog
    case forwardIdentity = "forward-identity"
    case reverseIdentity = "reverse-identity"
    case checkedDataType = "checked-data-type"
  }
}

struct APIRef: Codable {
  let id: String?
  let cardinality: String?
  let forwardIdentity: [String]?
  let reverseIdentity: [String]?
  let onDelete: String?
  
  enum CodingKeys: String, CodingKey {
    case id
    case cardinality
    case forwardIdentity = "forward-identity"
    case reverseIdentity = "reverse-identity"
    case onDelete = "on-delete"
  }
}

// MARK: - Errors

public enum InstantDBAPIError: Error, LocalizedError {
  case invalidResponse
  case httpError(statusCode: Int, body: String)
  case parseError(String)
  
  public var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "Invalid response from InstantDB API"
    case .httpError(let code, let body):
      return "HTTP \(code): \(body)"
    case .parseError(let message):
      return "Failed to parse schema: \(message)"
    }
  }
}

// MARK: - Schema Diff

/// Represents differences between two schemas
public struct SchemaDiff: Sendable {
  /// Entities in local but not in deployed
  public var addedEntities: [String] = []
  
  /// Entities in deployed but not in local
  public var removedEntities: [String] = []
  
  /// Fields added to existing entities (entity name -> field names)
  public var addedFields: [String: [String]] = [:]
  
  /// Fields removed from existing entities (entity name -> field names)
  public var removedFields: [String: [String]] = [:]
  
  /// Fields with changed types (entity.field -> (local type, deployed type))
  public var changedFieldTypes: [String: (local: FieldType, deployed: FieldType)] = [:]
  
  /// Links in local but not in deployed
  public var addedLinks: [String] = []
  
  /// Links in deployed but not in local
  public var removedLinks: [String] = []
  
  /// Whether there are any differences
  public var hasDifferences: Bool {
    !addedEntities.isEmpty ||
    !removedEntities.isEmpty ||
    !addedFields.isEmpty ||
    !removedFields.isEmpty ||
    !changedFieldTypes.isEmpty ||
    !addedLinks.isEmpty ||
    !removedLinks.isEmpty
  }
  
  /// Human-readable summary of differences
  public func summary() -> String {
    var lines: [String] = []
    
    if !addedEntities.isEmpty {
      lines.append("➕ New entities (not in deployed schema):")
      for entity in addedEntities.sorted() {
        lines.append("   - \(entity)")
      }
    }
    
    if !removedEntities.isEmpty {
      lines.append("➖ Missing entities (in deployed but not local):")
      for entity in removedEntities.sorted() {
        lines.append("   - \(entity)")
      }
    }
    
    if !addedFields.isEmpty {
      lines.append("➕ New fields (not in deployed schema):")
      for (entity, fields) in addedFields.sorted(by: { $0.key < $1.key }) {
        for field in fields.sorted() {
          lines.append("   - \(entity).\(field)")
        }
      }
    }
    
    if !removedFields.isEmpty {
      lines.append("➖ Missing fields (in deployed but not local):")
      for (entity, fields) in removedFields.sorted(by: { $0.key < $1.key }) {
        for field in fields.sorted() {
          lines.append("   - \(entity).\(field)")
        }
      }
    }
    
    if !changedFieldTypes.isEmpty {
      lines.append("⚠️  Changed field types:")
      for (field, types) in changedFieldTypes.sorted(by: { $0.key < $1.key }) {
        lines.append("   - \(field): \(types.deployed.swiftType) → \(types.local.swiftType)")
      }
    }
    
    if !addedLinks.isEmpty {
      lines.append("➕ New links (not in deployed schema):")
      for link in addedLinks.sorted() {
        lines.append("   - \(link)")
      }
    }
    
    if !removedLinks.isEmpty {
      lines.append("➖ Missing links (in deployed but not local):")
      for link in removedLinks.sorted() {
        lines.append("   - \(link)")
      }
    }
    
    return lines.joined(separator: "\n")
  }
}

/// Compare two schemas and return the differences
public func diffSchemas(local: SchemaIR, deployed: SchemaIR) -> SchemaDiff {
  var diff = SchemaDiff()
  
  let localEntityNames = Set(local.entities.map(\.name))
  let deployedEntityNames = Set(deployed.entities.map(\.name))
  
  // Find added/removed entities
  diff.addedEntities = Array(localEntityNames.subtracting(deployedEntityNames))
  diff.removedEntities = Array(deployedEntityNames.subtracting(localEntityNames))
  
  // Compare fields in common entities
  let commonEntities = localEntityNames.intersection(deployedEntityNames)
  for entityName in commonEntities {
    guard let localEntity = local.entities.first(where: { $0.name == entityName }),
          let deployedEntity = deployed.entities.first(where: { $0.name == entityName }) else {
      continue
    }
    
    let localFieldNames = Set(localEntity.fields.map(\.name))
    let deployedFieldNames = Set(deployedEntity.fields.map(\.name))
    
    let addedFields = localFieldNames.subtracting(deployedFieldNames)
    let removedFields = deployedFieldNames.subtracting(localFieldNames)
    
    if !addedFields.isEmpty {
      diff.addedFields[entityName] = Array(addedFields)
    }
    if !removedFields.isEmpty {
      diff.removedFields[entityName] = Array(removedFields)
    }
    
    // Check for type changes in common fields
    let commonFields = localFieldNames.intersection(deployedFieldNames)
    for fieldName in commonFields {
      guard let localField = localEntity.fields.first(where: { $0.name == fieldName }),
            let deployedField = deployedEntity.fields.first(where: { $0.name == fieldName }) else {
        continue
      }
      
      if localField.type != deployedField.type {
        diff.changedFieldTypes["\(entityName).\(fieldName)"] = (local: localField.type, deployed: deployedField.type)
      }
    }
  }
  
  // Compare links
  let localLinkNames = Set(local.links.map(\.name))
  let deployedLinkNames = Set(deployed.links.map(\.name))
  
  diff.addedLinks = Array(localLinkNames.subtracting(deployedLinkNames))
  diff.removedLinks = Array(deployedLinkNames.subtracting(localLinkNames))
  
  return diff
}

