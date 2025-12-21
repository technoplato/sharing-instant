// SchemaMigration.swift
// InstantSchemaCodegen
//
// Helpers for schema migrations and data transformations.

import Foundation

// MARK: - Schema Migration

/// Represents a migration between two schema versions.
///
/// ## Usage
///
/// ```swift
/// let migration = SchemaMigration(
///   from: oldSchema,
///   to: newSchema
/// )
///
/// // Get migration steps
/// let steps = migration.generateMigrationSteps()
///
/// // Generate migration script
/// let script = migration.generateTypeScriptMigration()
/// ```
public struct SchemaMigration {
  /// The source schema (current deployed)
  public let fromSchema: SchemaIR
  
  /// The target schema (new version)
  public let toSchema: SchemaIR
  
  /// The detected changes between schemas
  public let changes: [SchemaChange]
  
  /// Creates a migration between two schemas.
  public init(from: SchemaIR, to: SchemaIR) {
    self.fromSchema = from
    self.toSchema = to
    self.changes = SchemaMigration.detectChanges(from: from, to: to)
  }
  
  // MARK: - Change Detection
  
  private static func detectChanges(from: SchemaIR, to: SchemaIR) -> [SchemaChange] {
    var changes: [SchemaChange] = []
    
    let fromEntities = Dictionary(uniqueKeysWithValues: from.entities.map { ($0.name, $0) })
    let toEntities = Dictionary(uniqueKeysWithValues: to.entities.map { ($0.name, $0) })
    
    // Detect added entities
    for (name, entity) in toEntities where fromEntities[name] == nil {
      changes.append(.entityAdded(entity))
    }
    
    // Detect removed entities
    for (name, entity) in fromEntities where toEntities[name] == nil {
      changes.append(.entityRemoved(entity))
    }
    
    // Detect modified entities
    for (name, toEntity) in toEntities {
      guard let fromEntity = fromEntities[name] else { continue }
      
      let fromFields = Dictionary(uniqueKeysWithValues: fromEntity.fields.map { ($0.name, $0) })
      let toFields = Dictionary(uniqueKeysWithValues: toEntity.fields.map { ($0.name, $0) })
      
      // Added fields
      for (fieldName, field) in toFields where fromFields[fieldName] == nil {
        changes.append(.fieldAdded(entityName: name, field: field))
      }
      
      // Removed fields
      for (fieldName, field) in fromFields where toFields[fieldName] == nil {
        changes.append(.fieldRemoved(entityName: name, field: field))
      }
      
      // Modified fields
      for (fieldName, toField) in toFields {
        guard let fromField = fromFields[fieldName] else { continue }
        
        if fromField.type != toField.type {
          changes.append(.fieldTypeChanged(
            entityName: name,
            fieldName: fieldName,
            fromType: fromField.type,
            toType: toField.type
          ))
        }
        
        if fromField.isOptional != toField.isOptional {
          changes.append(.fieldOptionalityChanged(
            entityName: name,
            fieldName: fieldName,
            wasOptional: fromField.isOptional,
            isOptional: toField.isOptional
          ))
        }
      }
    }
    
    // Detect link changes
    let fromLinks = Dictionary(uniqueKeysWithValues: from.links.map { ($0.name, $0) })
    let toLinks = Dictionary(uniqueKeysWithValues: to.links.map { ($0.name, $0) })
    
    for (name, link) in toLinks where fromLinks[name] == nil {
      changes.append(.linkAdded(link))
    }
    
    for (name, link) in fromLinks where toLinks[name] == nil {
      changes.append(.linkRemoved(link))
    }
    
    return changes
  }
  
  // MARK: - Migration Steps
  
  /// Generate migration steps for the schema changes.
  public func generateMigrationSteps() -> [MigrationStep] {
    var steps: [MigrationStep] = []
    
    for change in changes {
      switch change {
      case .entityAdded(let entity):
        steps.append(MigrationStep(
          action: .createEntity,
          description: "Create entity '\(entity.name)'",
          details: "Add new entity with \(entity.fields.count) fields",
          isBreaking: false,
          requiresDataMigration: false
        ))
        
      case .entityRemoved(let entity):
        steps.append(MigrationStep(
          action: .deleteEntity,
          description: "Delete entity '\(entity.name)'",
          details: "⚠️ This will delete all data for this entity",
          isBreaking: true,
          requiresDataMigration: true
        ))
        
      case .fieldAdded(let entityName, let field):
        let isBreaking = !field.isOptional
        steps.append(MigrationStep(
          action: .addField,
          description: "Add field '\(field.name)' to '\(entityName)'",
          details: isBreaking
            ? "⚠️ Required field - existing records need default value"
            : "Optional field - safe to add",
          isBreaking: isBreaking,
          requiresDataMigration: isBreaking
        ))
        
      case .fieldRemoved(let entityName, let field):
        steps.append(MigrationStep(
          action: .removeField,
          description: "Remove field '\(field.name)' from '\(entityName)'",
          details: "⚠️ Existing data in this field will be lost",
          isBreaking: true,
          requiresDataMigration: false
        ))
        
      case .fieldTypeChanged(let entityName, let fieldName, let fromType, let toType):
        steps.append(MigrationStep(
          action: .changeFieldType,
          description: "Change type of '\(fieldName)' in '\(entityName)'",
          details: "From \(fromType.typeScriptType) to \(toType.typeScriptType) - requires data transformation",
          isBreaking: true,
          requiresDataMigration: true
        ))
        
      case .fieldOptionalityChanged(let entityName, let fieldName, let wasOptional, let isOptional):
        let isBreaking = wasOptional && !isOptional
        steps.append(MigrationStep(
          action: .changeFieldOptionality,
          description: isOptional
            ? "Make '\(fieldName)' optional in '\(entityName)'"
            : "Make '\(fieldName)' required in '\(entityName)'",
          details: isBreaking
            ? "⚠️ Existing null values need default"
            : "Safe change",
          isBreaking: isBreaking,
          requiresDataMigration: isBreaking
        ))
        
      case .linkAdded(let link):
        steps.append(MigrationStep(
          action: .addLink,
          description: "Add link '\(link.name)'",
          details: "Links \(link.forward.entityName) to \(link.reverse.entityName)",
          isBreaking: false,
          requiresDataMigration: false
        ))
        
      case .linkRemoved(let link):
        steps.append(MigrationStep(
          action: .removeLink,
          description: "Remove link '\(link.name)'",
          details: "⚠️ Existing link data will be lost",
          isBreaking: true,
          requiresDataMigration: false
        ))
      }
    }
    
    return steps
  }
  
  // MARK: - TypeScript Migration Script
  
  /// Generate a TypeScript migration script.
  public func generateTypeScriptMigration() -> String {
    let steps = generateMigrationSteps()
    let hasBreaking = steps.contains { $0.isBreaking }
    let hasDataMigration = steps.contains { $0.requiresDataMigration }
    
    var output = """
    // Schema Migration Script
    // Generated by InstantSchemaCodegen
    //
    // From: \(fromSchema.sourceFile ?? "unknown")
    // To: \(toSchema.sourceFile ?? "unknown")
    //
    // Changes: \(changes.count)
    // Breaking: \(hasBreaking ? "Yes" : "No")
    // Data Migration Required: \(hasDataMigration ? "Yes" : "No")
    
    import { init } from "@instantdb/admin";
    
    const db = init({
      appId: process.env.INSTANT_APP_ID!,
      adminToken: process.env.INSTANT_ADMIN_TOKEN!,
    });
    
    async function migrate() {
      console.log("Starting migration...");
    
    """
    
    // Add migration steps
    for (index, step) in steps.enumerated() {
      output += """
        // Step \(index + 1): \(step.description)
        // \(step.details)
      
      """
      
      switch step.action {
      case .createEntity:
        output += """
          // Entity will be created when first record is added
          console.log("Entity ready for creation");
        
        """
        
      case .deleteEntity:
        output += """
          // WARNING: This will delete all data!
          // await db.transact([
          //   db.tx.entityName[id].delete()
          // ]);
          console.log("Entity deletion requires manual confirmation");
        
        """
        
      case .addField:
        if step.requiresDataMigration {
          output += """
            // Required field - set default value for existing records
            // const records = await db.query({ entityName: {} });
            // await db.transact(
            //   records.entityName.map(record =>
            //     db.tx.entityName[record.id].update({ fieldName: defaultValue })
            //   )
            // );
            console.log("Field addition requires default value");
          
          """
        } else {
          output += """
            // Optional field - safe to add
            console.log("Optional field ready");
          
          """
        }
        
      case .removeField:
        output += """
          // Field removal is handled by schema push
          console.log("Field will be removed on schema push");
        
        """
        
      case .changeFieldType:
        output += """
          // Type change requires data transformation
          // const records = await db.query({ entityName: {} });
          // await db.transact(
          //   records.entityName.map(record => {
          //     const newValue = transformValue(record.fieldName);
          //     return db.tx.entityName[record.id].update({ fieldName: newValue });
          //   })
          // );
          console.log("Field type change requires data transformation");
        
        """
        
      case .changeFieldOptionality:
        if step.requiresDataMigration {
          output += """
            // Making field required - set default for null values
            // const records = await db.query({ entityName: {} });
            // await db.transact(
            //   records.entityName
            //     .filter(r => r.fieldName == null)
            //     .map(record =>
            //       db.tx.entityName[record.id].update({ fieldName: defaultValue })
            //     )
            // );
            console.log("Optionality change requires default values");
          
          """
        } else {
          output += """
            // Making field optional - safe change
            console.log("Optionality change ready");
          
          """
        }
        
      case .addLink:
        output += """
          // Link will be created when first relationship is added
          console.log("Link ready for creation");
        
        """
        
      case .removeLink:
        output += """
          // Link removal is handled by schema push
          console.log("Link will be removed on schema push");
        
        """
      }
    }
    
    output += """
      console.log("Migration complete!");
    }
    
    migrate().catch(console.error);
    """
    
    return output
  }
  
  // MARK: - Summary
  
  /// Generate a human-readable summary of the migration.
  public func summary() -> String {
    let steps = generateMigrationSteps()
    let breakingSteps = steps.filter { $0.isBreaking }
    let dataMigrationSteps = steps.filter { $0.requiresDataMigration }
    
    var output = """
    Schema Migration Summary
    ========================
    
    Total Changes: \(changes.count)
    Breaking Changes: \(breakingSteps.count)
    Data Migrations Required: \(dataMigrationSteps.count)
    
    """
    
    if !breakingSteps.isEmpty {
      output += """
      
      ⚠️  Breaking Changes:
      
      """
      for step in breakingSteps {
        output += "  • \(step.description)\n"
        output += "    \(step.details)\n"
      }
    }
    
    if !dataMigrationSteps.isEmpty {
      output += """
      
      📦 Data Migrations Required:
      
      """
      for step in dataMigrationSteps {
        output += "  • \(step.description)\n"
      }
    }
    
    let safeSteps = steps.filter { !$0.isBreaking }
    if !safeSteps.isEmpty {
      output += """
      
      ✅ Safe Changes:
      
      """
      for step in safeSteps {
        output += "  • \(step.description)\n"
      }
    }
    
    return output
  }
}

// MARK: - Schema Change

/// A detected change between two schema versions.
public enum SchemaChange: Equatable {
  case entityAdded(EntityIR)
  case entityRemoved(EntityIR)
  case fieldAdded(entityName: String, field: FieldIR)
  case fieldRemoved(entityName: String, field: FieldIR)
  case fieldTypeChanged(entityName: String, fieldName: String, fromType: FieldType, toType: FieldType)
  case fieldOptionalityChanged(entityName: String, fieldName: String, wasOptional: Bool, isOptional: Bool)
  case linkAdded(LinkIR)
  case linkRemoved(LinkIR)
}

// MARK: - Migration Step

/// A single step in a migration.
public struct MigrationStep {
  /// The action to perform
  public let action: MigrationAction
  
  /// Human-readable description
  public let description: String
  
  /// Additional details
  public let details: String
  
  /// Whether this is a breaking change
  public let isBreaking: Bool
  
  /// Whether this requires data migration
  public let requiresDataMigration: Bool
}

/// The type of migration action.
public enum MigrationAction: String {
  case createEntity
  case deleteEntity
  case addField
  case removeField
  case changeFieldType
  case changeFieldOptionality
  case addLink
  case removeLink
}






