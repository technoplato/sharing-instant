// InstantSchemaPlugin.swift
// InstantDB Schema Codegen SPM Build Plugin
//
// This plugin automatically generates Swift types from your InstantDB schema
// on every build. It runs BEFORE compilation, ensuring your types are always
// in sync with your schema.
//
// ## How It Works
//
// 1. **Pre-build Phase**: The plugin runs before Swift compilation begins
// 2. **Schema Detection**: Looks for `instant.schema.ts` in your project
// 3. **Code Generation**: Generates Swift types in a build-specific directory
// 4. **Compilation**: Generated files are included in the build
//
// ## Setup Instructions
//
// ### 1. Add the Plugin to Your Package
//
// In your `Package.swift`:
//
// ```swift
// let package = Package(
//   name: "MyApp",
//   dependencies: [
//     .package(url: "https://github.com/instantdb/sharing-instant", from: "1.0.0"),
//   ],
//   targets: [
//     .target(
//       name: "MyApp",
//       dependencies: ["SharingInstant"],
//       plugins: [
//         .plugin(name: "InstantSchemaPlugin", package: "sharing-instant")
//       ]
//     )
//   ]
// )
// ```
//
// ### 2. Create Your Schema File
//
// Create `instant.schema.ts` in your project root or `Sources/` directory.
// The plugin will find it automatically.
//
// ### 3. Build Your Project
//
// Run `swift build` - the plugin will generate Swift types automatically!
//
// ## Generated Files
//
// The plugin generates:
// - `Schema.swift` - Namespace with EntityKey instances
// - `{EntityName}.swift` - One file per entity with Codable struct
//
// ## Environment Variables
//
// - `INSTANT_APP_ID`: Your InstantDB app ID (required for schema verification)
// - `INSTANT_ADMIN_TOKEN`: Admin token for API access (required for schema verification)
// - `INSTANT_SCHEMA_PATH`: Custom path to schema file (optional)
// - `INSTANT_SCHEMA_VERIFY`: Verification mode: "warn" (default), "strict", or "off"
//
// ## Schema Verification
//
// When `INSTANT_APP_ID` and `INSTANT_ADMIN_TOKEN` are set, the plugin will:
// 1. Generate Swift types from your local schema
// 2. Fetch the deployed schema from InstantDB
// 3. Compare local vs deployed and report differences
//
// Verification modes:
// - `warn` (default): Log warnings for mismatches, build continues
// - `strict`: Fail the build if schemas don't match (recommended for CI)
// - `off`: Skip verification entirely
//
// Example CI setup:
// ```yaml
// env:
//   INSTANT_APP_ID: ${{ secrets.INSTANT_APP_ID }}
//   INSTANT_ADMIN_TOKEN: ${{ secrets.INSTANT_ADMIN_TOKEN }}
//   INSTANT_SCHEMA_VERIFY: strict
// ```
//
// ## Troubleshooting
//
// If the plugin doesn't run:
// 1. Ensure `instant.schema.ts` exists in your project
// 2. Check build logs for plugin output
// 3. Try `swift package clean` and rebuild
//
// If generated types are outdated:
// 1. The plugin only regenerates when schema changes
// 2. Delete `.build/plugins/` to force regeneration

import Foundation
import PackagePlugin

/// SPM Build Tool Plugin for InstantDB Schema Codegen
///
/// Automatically generates Swift types from your `instant.schema.ts` file
/// on every build, ensuring type safety between your schema and code.
@main
struct InstantSchemaPlugin: BuildToolPlugin {
  
  /// Called by SPM before building a target that uses this plugin
  func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
    // Only process source targets
    guard let sourceTarget = target as? SourceModuleTarget else {
      return []
    }
    
    // Find the schema file
    let schemaPath = findSchemaFile(in: context, target: sourceTarget)
    
    guard let schema = schemaPath else {
      // No schema file found - skip silently
      // This allows the plugin to be added to projects that don't have a schema yet
      Diagnostics.remark("No instant.schema.ts found - skipping InstantDB codegen")
      return []
    }
    
    // Create output directory
    let outputDir = context.pluginWorkDirectoryURL.appending(path: "GeneratedSources")
    
    // Get the instant-schema tool
    let tool = try context.tool(named: "instant-schema")
    
    Diagnostics.remark("InstantDB: Generating Swift types from \(schema.lastPathComponent)")
    
    var commands: [Command] = []
    
    // 1. Generate Swift types from schema
    commands.append(
      .buildCommand(
        displayName: "Generate InstantDB Swift Types",
        executable: tool.url,
        arguments: [
          "generate",
          "--from", schema.path(percentEncoded: false),
          "--to", outputDir.path(percentEncoded: false)
        ],
        environment: [:],
        inputFiles: [schema],
        outputFiles: [
          outputDir.appending(path: "Schema.swift")
        ]
      )
    )
    
    // 2. Verify schema against deployed (if credentials available)
    let appId = ProcessInfo.processInfo.environment["INSTANT_APP_ID"]
    let adminToken = ProcessInfo.processInfo.environment["INSTANT_ADMIN_TOKEN"]
    let verifyMode = ProcessInfo.processInfo.environment["INSTANT_SCHEMA_VERIFY"] ?? "warn"
    
    if let appId = appId, let adminToken = adminToken, verifyMode != "off" {
      Diagnostics.remark("InstantDB: Verifying schema against deployed (app: \(appId))")
      
      var verifyArgs = [
        "verify",
        "--app-id", appId,
        "--local", schema.path(percentEncoded: false)
      ]
      
      // Add --strict flag if verify mode is "strict"
      if verifyMode == "strict" {
        verifyArgs.append("--strict")
      }
      
      commands.append(
        .buildCommand(
          displayName: "Verify InstantDB Schema",
          executable: tool.url,
          arguments: verifyArgs,
          environment: ["INSTANT_ADMIN_TOKEN": adminToken],
          inputFiles: [schema],
          outputFiles: []
        )
      )
    }
    
    return commands
  }
  
  /// Find the schema file in the project
  private func findSchemaFile(in context: PluginContext, target: SourceModuleTarget) -> URL? {
    // Check environment variable first
    if let customPath = ProcessInfo.processInfo.environment["INSTANT_SCHEMA_PATH"] {
      let url = URL(fileURLWithPath: customPath)
      if FileManager.default.fileExists(atPath: url.path) {
        return url
      }
    }
    
    // Common locations to search
    let searchPaths = [
      context.package.directoryURL.appending(path: "instant.schema.ts"),
      context.package.directoryURL.appending(path: "src/instant.schema.ts"),
      context.package.directoryURL.appending(path: "Sources/instant.schema.ts"),
      context.package.directoryURL.appending(path: "Sources/\(target.name)/instant.schema.ts"),
    ]
    
    for path in searchPaths {
      if FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) {
        return path
      }
    }
    
    // Also check target's source files
    for file in target.sourceFiles {
      if file.url.lastPathComponent == "instant.schema.ts" {
        return file.url
      }
    }
    
    return nil
  }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

/// Xcode Project Plugin extension for use in Xcode projects (not just SPM)
extension InstantSchemaPlugin: XcodeBuildToolPlugin {
  func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
    // Find schema file in Xcode project
    let schemaPath = findSchemaFileInXcode(context: context)
    
    guard let schema = schemaPath else {
      Diagnostics.remark("No instant.schema.ts found in Xcode project - skipping InstantDB codegen")
      return []
    }
    
    let outputDir = context.pluginWorkDirectoryURL.appending(path: "GeneratedSources")
    let tool = try context.tool(named: "instant-schema")
    
    Diagnostics.remark("InstantDB: Generating Swift types from \(schema.lastPathComponent)")
    
    var commands: [Command] = []
    
    // 1. Generate Swift types from schema
    commands.append(
      .buildCommand(
        displayName: "Generate InstantDB Swift Types",
        executable: tool.url,
        arguments: [
          "generate",
          "--from", schema.path(percentEncoded: false),
          "--to", outputDir.path(percentEncoded: false)
        ],
        inputFiles: [schema],
        outputFiles: [
          outputDir.appending(path: "Schema.swift")
        ]
      )
    )
    
    // 2. Verify schema against deployed (if credentials available)
    let appId = ProcessInfo.processInfo.environment["INSTANT_APP_ID"]
    let adminToken = ProcessInfo.processInfo.environment["INSTANT_ADMIN_TOKEN"]
    let verifyMode = ProcessInfo.processInfo.environment["INSTANT_SCHEMA_VERIFY"] ?? "warn"
    
    if let appId = appId, let adminToken = adminToken, verifyMode != "off" {
      Diagnostics.remark("InstantDB: Verifying schema against deployed (app: \(appId))")
      
      var verifyArgs = [
        "verify",
        "--app-id", appId,
        "--local", schema.path(percentEncoded: false)
      ]
      
      if verifyMode == "strict" {
        verifyArgs.append("--strict")
      }
      
      commands.append(
        .buildCommand(
          displayName: "Verify InstantDB Schema",
          executable: tool.url,
          arguments: verifyArgs,
          environment: ["INSTANT_ADMIN_TOKEN": adminToken],
          inputFiles: [schema],
          outputFiles: []
        )
      )
    }
    
    return commands
  }
  
  private func findSchemaFileInXcode(context: XcodePluginContext) -> URL? {
    // Check environment variable
    if let customPath = ProcessInfo.processInfo.environment["INSTANT_SCHEMA_PATH"] {
      let url = URL(fileURLWithPath: customPath)
      if FileManager.default.fileExists(atPath: url.path) {
        return url
      }
    }
    
    // Search common locations relative to project
    let projectDir = context.xcodeProject.directoryURL
    let searchPaths = [
      projectDir.appending(path: "instant.schema.ts"),
      projectDir.appending(path: "src/instant.schema.ts"),
      projectDir.appending(path: "Sources/instant.schema.ts"),
    ]
    
    for path in searchPaths {
      if FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) {
        return path
      }
    }
    
    return nil
  }
}
#endif

