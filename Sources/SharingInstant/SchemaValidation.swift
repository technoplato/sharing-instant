import Dependencies
import Foundation
import InstantDB

// MARK: - Schema Validation Errors

/// Errors that can occur when validating data against the InstantDB schema.
public enum SchemaValidationError: Error, CustomStringConvertible {
  /// The namespace specified in the Swift type doesn't exist in the InstantDB schema.
  case namespaceNotFound(namespace: String, swiftType: String)
  
  /// An attribute in the Swift type doesn't exist in the InstantDB schema.
  case attributeNotFound(attribute: String, namespace: String, swiftType: String)
  
  /// The Swift type has a different type than the InstantDB schema expects.
  case typeMismatch(attribute: String, namespace: String, expectedType: String, actualType: String)
  
  /// A required attribute in the schema is missing from the Swift type.
  case missingRequiredAttribute(attribute: String, namespace: String, swiftType: String)
  
  /// The Swift type is missing the `id` property required for EntityIdentifiable.
  case missingIdProperty(swiftType: String)
  
  /// Failed to decode data from InstantDB into the Swift type.
  case decodingFailed(namespace: String, swiftType: String, underlyingError: Error)
  
  public var description: String {
    switch self {
    case .namespaceNotFound(let namespace, let swiftType):
      return """
        Schema mismatch: Namespace '\(namespace)' not found in InstantDB schema.
        
        The Swift type '\(swiftType)' specifies namespace '\(namespace)', but this namespace \
        doesn't exist in your InstantDB app's schema.
        
        To fix this:
        1. Check that '\(namespace)' is defined in your instant.schema.ts
        2. Run 'npx instant-cli@latest push' to sync your schema
        3. Or update the namespace property in your Swift type
        """
      
    case .attributeNotFound(let attribute, let namespace, let swiftType):
      return """
        Schema mismatch: Attribute '\(attribute)' not found in namespace '\(namespace)'.
        
        The Swift type '\(swiftType)' has a property '\(attribute)', but this attribute \
        doesn't exist in the InstantDB schema for '\(namespace)'.
        
        To fix this:
        1. Add '\(attribute)' to '\(namespace)' in your instant.schema.ts
        2. Run 'npx instant-cli@latest push' to sync your schema
        3. Or remove '\(attribute)' from your Swift type
        """
      
    case .typeMismatch(let attribute, let namespace, let expectedType, let actualType):
      return """
        Schema mismatch: Type mismatch for '\(namespace).\(attribute)'.
        
        InstantDB expects type '\(expectedType)', but Swift type has '\(actualType)'.
        
        To fix this:
        1. Update the type of '\(attribute)' in your instant.schema.ts to match
        2. Run 'npx instant-cli@latest push' to sync your schema
        3. Or update the Swift property type to match the schema
        """
      
    case .missingRequiredAttribute(let attribute, let namespace, let swiftType):
      return """
        Schema mismatch: Required attribute '\(attribute)' missing from Swift type.
        
        The InstantDB schema requires '\(namespace).\(attribute)', but '\(swiftType)' \
        doesn't have this property.
        
        To fix this:
        1. Add 'var \(attribute): ...' to your Swift type
        2. Or mark '\(attribute)' as optional in your instant.schema.ts
        """
      
    case .missingIdProperty(let swiftType):
      return """
        Schema mismatch: Swift type '\(swiftType)' is missing 'id' property.
        
        Types conforming to EntityIdentifiable must have an 'id: String' property.
        
        To fix this, add: var id: String
        """
      
    case .decodingFailed(let namespace, let swiftType, let underlyingError):
      return """
        Failed to decode '\(namespace)' data into Swift type '\(swiftType)'.
        
        This usually means your Swift type doesn't match the InstantDB schema.
        
        Underlying error: \(underlyingError.localizedDescription)
        
        To fix this:
        1. Compare your Swift type properties with the InstantDB schema
        2. Ensure all property types match (String, Int, Bool, Date, etc.)
        3. Check that optional properties are marked as Optional in Swift
        """
    }
  }
}

// MARK: - Schema Validation

/// Utilities for validating Swift types against InstantDB schemas.
public enum SchemaValidation {
  
  /// Reports a schema validation error to the developer.
  ///
  /// This uses `reportIssue` to show the error in Xcode during development,
  /// making it easier to catch schema mismatches early.
  ///
  /// - Parameter error: The schema validation error to report.
  public static func report(_ error: SchemaValidationError) {
    reportIssue(error.description)
  }
  
  /// Reports a schema validation error with additional context.
  ///
  /// - Parameters:
  ///   - error: The schema validation error to report.
  ///   - file: The file where the error occurred.
  ///   - line: The line number where the error occurred.
  public static func report(
    _ error: SchemaValidationError,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    reportIssue("""
      \(error.description)
      
      Location: \(file):\(line)
      """)
  }
  
  /// Validates that a namespace exists in the schema attributes.
  ///
  /// - Parameters:
  ///   - namespace: The namespace to validate.
  ///   - swiftType: The name of the Swift type (for error messages).
  ///   - attributes: The schema attributes from InstantDB.
  /// - Returns: `true` if the namespace exists, `false` otherwise.
  public static func validateNamespace(
    _ namespace: String,
    swiftType: String,
    attributes: [Attribute]
  ) -> Bool {
    let namespaceExists = attributes.contains { attr in
      guard attr.forwardIdentity.count >= 2 else { return false }
      return attr.forwardIdentity[1] == namespace
    }
    
    if !namespaceExists {
      report(.namespaceNotFound(namespace: namespace, swiftType: swiftType))
      return false
    }
    
    return true
  }
  
  /// Validates that an attribute exists in the schema.
  ///
  /// - Parameters:
  ///   - attribute: The attribute name to validate.
  ///   - namespace: The namespace the attribute should belong to.
  ///   - swiftType: The name of the Swift type (for error messages).
  ///   - attributes: The schema attributes from InstantDB.
  /// - Returns: `true` if the attribute exists, `false` otherwise.
  public static func validateAttribute(
    _ attribute: String,
    namespace: String,
    swiftType: String,
    attributes: [Attribute]
  ) -> Bool {
    let attributeExists = attributes.contains { attr in
      guard attr.forwardIdentity.count >= 3 else { return false }
      return attr.forwardIdentity[1] == namespace && attr.forwardIdentity[2] == attribute
    }
    
    if !attributeExists {
      report(.attributeNotFound(attribute: attribute, namespace: namespace, swiftType: swiftType))
      return false
    }
    
    return true
  }
}

// MARK: - Decoding Error Handling

extension SchemaValidation {
  
  /// Wraps a decoding operation and reports any errors as schema validation issues.
  ///
  /// - Parameters:
  ///   - namespace: The namespace being decoded.
  ///   - swiftType: The name of the Swift type.
  ///   - decode: The decoding closure to execute.
  /// - Returns: The decoded value, or `nil` if decoding failed.
  public static func decode<T>(
    namespace: String,
    swiftType: String,
    _ decode: () throws -> T
  ) -> T? {
    do {
      return try decode()
    } catch {
      report(.decodingFailed(namespace: namespace, swiftType: swiftType, underlyingError: error))
      return nil
    }
  }
}








