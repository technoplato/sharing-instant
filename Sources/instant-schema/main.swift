// main.swift
// instant-schema CLI
//
// Command-line tool for InstantDB schema codegen and validation.
//
// ## Features
//
// - **generate**: Generate Swift types from TypeScript schema
// - **pull**: Fetch deployed schema from InstantDB
// - **verify**: Validate local schema matches deployed
// - **diff**: Show differences between local and deployed
//
// ## Environment Variables
//
// - `INSTANT_APP_ID`: Default app ID for commands
// - `INSTANT_ADMIN_TOKEN`: Admin token for API access
//
// ## Usage with SPM Build Plugin
//
// The SPM build plugin automatically runs codegen on every build.
// See `InstantSchemaPlugin` for details.

import Foundation
import InstantSchemaCodegen

// MARK: - CLI Entry Point

@main
struct InstantSchemaCLI {
  static func main() async throws {
    let arguments = CommandLine.arguments.dropFirst()
    
    guard let command = arguments.first else {
      printUsage()
      return
    }
    
    do {
      switch command {
      case "generate", "gen":
        try await generateCommand(Array(arguments.dropFirst()))
        
      case "pull":
        try await pullCommand(Array(arguments.dropFirst()))
        
      case "parse":
        try await parseCommand(Array(arguments.dropFirst()))
        
      case "print":
        try await printCommand(Array(arguments.dropFirst()))
        
      case "verify":
        try await verifyCommand(Array(arguments.dropFirst()))
        
      case "diff":
        try await diffCommand(Array(arguments.dropFirst()))
        
      case "swift-to-ts", "s2t":
        try await swiftToTypeScriptCommand(Array(arguments.dropFirst()))
        
      case "migrate":
        try await migrateCommand(Array(arguments.dropFirst()))
        
      case "help", "--help", "-h":
        printUsage()
        
      case "version", "--version", "-v":
        print("instant-schema 0.1.0")
        
      default:
        print("Unknown command: \(command)")
        printUsage()
        exit(1)
      }
    } catch {
      print("❌ Error: \(error.localizedDescription)")
      exit(1)
    }
  }
  
  // MARK: - Generate Command
  
  /// Generate Swift from TypeScript schema
  static func generateCommand(_ args: [String]) async throws {
    var inputPath: String?
    var outputDir: String = "Sources/Generated"
    var appId: String?
    var adminToken: String?
    
    var i = 0
    while i < args.count {
      switch args[i] {
      case "--from", "-f":
        i += 1
        inputPath = args[i]
      case "--to", "-t":
        i += 1
        outputDir = args[i]
      case "--app-id", "-a":
        i += 1
        appId = args[i]
      case "--admin-token":
        i += 1
        adminToken = args[i]
      default:
        if inputPath == nil {
          inputPath = args[i]
        }
      }
      i += 1
    }
    
    // Get credentials from environment if not provided
    appId = appId ?? ProcessInfo.processInfo.environment["INSTANT_APP_ID"]
    adminToken = adminToken ?? ProcessInfo.processInfo.environment["INSTANT_ADMIN_TOKEN"]
    
    // If no input file, try to pull from API
    let schema: SchemaIR
    if let input = inputPath {
      print("📖 Parsing \(input)...")
      let parser = CommentPreservingSchemaParser()
      schema = try parser.parse(String(contentsOfFile: input, encoding: .utf8), sourceFile: input)
    } else if let app = appId, let token = adminToken {
      print("📡 Fetching schema from InstantDB for app \(app)...")
      let api = InstantDBAPI(adminToken: token)
      schema = try await api.fetchSchema(appID: app)
    } else {
      print("Error: No input file or API credentials specified")
      print("Usage: instant-schema generate --from instant.schema.ts --to Sources/Generated/")
      print("   or: instant-schema generate --app-id <id> --admin-token <token> --to Sources/Generated/")
      exit(1)
    }
    
    print("✅ Found \(schema.entities.count) entities, \(schema.links.count) links")
    
    print("🔨 Generating Swift code...")
    
    let generator = SwiftCodeGenerator()
    let files = generator.generate(from: schema)
    
    // Create output directory
    try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    
    for file in files {
      let path = (outputDir as NSString).appendingPathComponent(file.name)
      try file.content.write(toFile: path, atomically: true, encoding: .utf8)
      print("  ✓ \(path)")
    }
    
    print("✅ Generated \(files.count) files in \(outputDir)")
  }
  
  // MARK: - Pull Command
  
  /// Pull deployed schema from InstantDB
  static func pullCommand(_ args: [String]) async throws {
    var appId: String?
    var adminToken: String?
    var outputPath: String?
    var format: String = "typescript"
    
    var i = 0
    while i < args.count {
      switch args[i] {
      case "--app-id", "-a":
        i += 1
        appId = args[i]
      case "--admin-token":
        i += 1
        adminToken = args[i]
      case "--output", "-o":
        i += 1
        outputPath = args[i]
      case "--format":
        i += 1
        format = args[i]
      case "--json":
        format = "json"
      default:
        break
      }
      i += 1
    }
    
    // Get credentials from environment if not provided
    appId = appId ?? ProcessInfo.processInfo.environment["INSTANT_APP_ID"]
    adminToken = adminToken ?? ProcessInfo.processInfo.environment["INSTANT_ADMIN_TOKEN"]
    
    guard let app = appId else {
      print("Error: No app ID specified")
      print("Usage: instant-schema pull --app-id <id> --admin-token <token>")
      print("Or set INSTANT_APP_ID environment variable")
      exit(1)
    }
    
    guard let token = adminToken else {
      print("Error: No admin token specified")
      print("Usage: instant-schema pull --app-id <id> --admin-token <token>")
      print("Or set INSTANT_ADMIN_TOKEN environment variable")
      exit(1)
    }
    
    print("📡 Fetching schema from InstantDB...")
    print("   App ID: \(app)")
    
    let api = InstantDBAPI(adminToken: token)
    
    if format == "json" {
      let data = try await api.fetchSchemaJSON(appID: app)
      let json = try JSONSerialization.jsonObject(with: data)
      let prettyData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
      let output = String(data: prettyData, encoding: .utf8)!
      
      if let path = outputPath {
        try output.write(toFile: path, atomically: true, encoding: .utf8)
        print("✅ Saved raw JSON to \(path)")
      } else {
        print(output)
      }
    } else {
      let schema = try await api.fetchSchema(appID: app)
      
      print("✅ Found \(schema.entities.count) entities, \(schema.links.count) links")
      
      let printer = TypeScriptSchemaPrinter()
      let output = printer.print(schema)
      
      if let path = outputPath {
        try output.write(toFile: path, atomically: true, encoding: .utf8)
        print("✅ Saved TypeScript schema to \(path)")
      } else {
        print("")
        print(output)
      }
    }
  }
  
  // MARK: - Parse Command
  
  /// Parse a schema file and print the IR
  static func parseCommand(_ args: [String]) async throws {
    guard let inputPath = args.first else {
      print("Error: No input file specified")
      print("Usage: instant-schema parse <file>")
      exit(1)
    }
    
    let content = try String(contentsOfFile: inputPath, encoding: .utf8)
    
    let parser = CommentPreservingSchemaParser()
    let schema = try parser.parse(content, sourceFile: inputPath)
    
    print("Schema from \(inputPath):")
    print("")
    print("Entities:")
    for entity in schema.entities {
      print("  \(entity.name) (\(entity.swiftTypeName))")
      if let doc = entity.documentation {
        print("    /// \(doc)")
      }
      for field in entity.fields {
        let opt = field.isOptional ? "?" : ""
        print("    - \(field.name): \(field.type.swiftType)\(opt)")
      }
    }
    
    if !schema.links.isEmpty {
      print("")
      print("Links:")
      for link in schema.links {
        print("  \(link.name):")
        print("    forward: \(link.forward.entityName).\(link.forward.label) (has \(link.forward.cardinality))")
        print("    reverse: \(link.reverse.entityName).\(link.reverse.label) (has \(link.reverse.cardinality))")
      }
    }
  }
  
  // MARK: - Print Command
  
  /// Print IR back to TypeScript
  static func printCommand(_ args: [String]) async throws {
    guard let inputPath = args.first else {
      print("Error: No input file specified")
      print("Usage: instant-schema print <schema.ts>")
      exit(1)
    }
    
    let content = try String(contentsOfFile: inputPath, encoding: .utf8)
    
    let parser = CommentPreservingSchemaParser()
    let schema = try parser.parse(content, sourceFile: inputPath)
    
    let output = try parser.print(schema)
    print(output)
  }
  
  // MARK: - Verify Command
  
  /// Verify local schema matches deployed schema
  static func verifyCommand(_ args: [String]) async throws {
    var appId: String?
    var adminToken: String?
    var localPath: String?
    var strict = false
    
    var i = 0
    while i < args.count {
      switch args[i] {
      case "--app-id", "-a":
        i += 1
        appId = args[i]
      case "--admin-token":
        i += 1
        adminToken = args[i]
      case "--local", "-l":
        i += 1
        localPath = args[i]
      case "--strict":
        strict = true
      default:
        if localPath == nil {
          localPath = args[i]
        }
      }
      i += 1
    }
    
    // Get credentials from environment if not provided
    appId = appId ?? ProcessInfo.processInfo.environment["INSTANT_APP_ID"]
    adminToken = adminToken ?? ProcessInfo.processInfo.environment["INSTANT_ADMIN_TOKEN"]
    
    guard let app = appId else {
      print("Error: No app ID specified")
      print("Usage: instant-schema verify --app-id <id> --local <path>")
      print("Or set INSTANT_APP_ID environment variable")
      exit(1)
    }
    
    guard let token = adminToken else {
      print("Error: No admin token specified")
      print("Usage: instant-schema verify --app-id <id> --admin-token <token> --local <path>")
      print("Or set INSTANT_ADMIN_TOKEN environment variable")
      exit(1)
    }
    
    guard let local = localPath else {
      print("Error: No local schema path specified")
      exit(1)
    }
    
    print("🔍 Verifying schema...")
    print("   App ID: \(app)")
    print("   Local:  \(local)")
    print("")
    
    // Parse local schema
    let content = try String(contentsOfFile: local, encoding: .utf8)
    let parser = CommentPreservingSchemaParser()
    let localSchema = try parser.parse(content, sourceFile: local)
    
    print("📖 Local schema: \(localSchema.entities.count) entities, \(localSchema.links.count) links")
    
    // Fetch deployed schema
    print("📡 Fetching deployed schema...")
    let api = InstantDBAPI(adminToken: token)
    let deployedSchema = try await api.fetchSchema(appID: app)
    
    print("📡 Deployed schema: \(deployedSchema.entities.count) entities, \(deployedSchema.links.count) links")
    print("")
    
    // Compare
    let diff = diffSchemas(local: localSchema, deployed: deployedSchema)
    
    if diff.hasDifferences {
      print("⚠️  Schema differences detected!")
      print("")
      print(diff.summary())
      print("")
      print("To resolve:")
      print("  • Run `npx instant-cli@latest push schema` to deploy local changes")
      print("  • Or run `instant-schema pull --app-id \(app) -o \(local)` to update local")
      
      if strict {
        exit(1)
      }
    } else {
      print("✅ Schemas match!")
    }
  }
  
  // MARK: - Diff Command
  
  /// Diff local vs deployed schema
  static func diffCommand(_ args: [String]) async throws {
    var appId: String?
    var adminToken: String?
    var localPath: String?
    
    var i = 0
    while i < args.count {
      switch args[i] {
      case "--app-id", "-a":
        i += 1
        appId = args[i]
      case "--admin-token":
        i += 1
        adminToken = args[i]
      case "--local", "-l":
        i += 1
        localPath = args[i]
      default:
        if localPath == nil {
          localPath = args[i]
        }
      }
      i += 1
    }
    
    // Get credentials from environment if not provided
    appId = appId ?? ProcessInfo.processInfo.environment["INSTANT_APP_ID"]
    adminToken = adminToken ?? ProcessInfo.processInfo.environment["INSTANT_ADMIN_TOKEN"]
    
    guard let app = appId else {
      print("Error: No app ID specified")
      print("Usage: instant-schema diff --app-id <id> --local <path>")
      exit(1)
    }
    
    guard let token = adminToken else {
      print("Error: No admin token specified")
      exit(1)
    }
    
    guard let local = localPath else {
      print("Error: No local schema path specified")
      exit(1)
    }
    
    // Parse local schema
    let content = try String(contentsOfFile: local, encoding: .utf8)
    let parser = CommentPreservingSchemaParser()
    let localSchema = try parser.parse(content, sourceFile: local)
    
    // Fetch deployed schema
    let api = InstantDBAPI(adminToken: token)
    let deployedSchema = try await api.fetchSchema(appID: app)
    
    // Compare
    let diff = diffSchemas(local: localSchema, deployed: deployedSchema)
    
    if diff.hasDifferences {
      print(diff.summary())
    } else {
      print("No differences found.")
    }
  }
  
  // MARK: - Migrate Command
  
  /// Generate migration script between two schemas
  static func migrateCommand(_ args: [String]) async throws {
    var fromPath: String?
    var toPath: String?
    var outputPath: String?
    var appId: String?
    var adminToken: String?
    var showScript = false
    
    var i = 0
    while i < args.count {
      switch args[i] {
      case "--from", "-f":
        i += 1
        fromPath = args[i]
      case "--to", "-t":
        i += 1
        toPath = args[i]
      case "--output", "-o":
        i += 1
        outputPath = args[i]
      case "--app-id", "-a":
        i += 1
        appId = args[i]
      case "--admin-token":
        i += 1
        adminToken = args[i]
      case "--script":
        showScript = true
      default:
        break
      }
      i += 1
    }
    
    // Get credentials from environment if not provided
    appId = appId ?? ProcessInfo.processInfo.environment["INSTANT_APP_ID"]
    adminToken = adminToken ?? ProcessInfo.processInfo.environment["INSTANT_ADMIN_TOKEN"]
    
    // Parse "from" schema (can be file or deployed)
    let fromSchema: SchemaIR
    if let from = fromPath {
      print("📖 Parsing source schema from \(from)...")
      let parser = CommentPreservingSchemaParser()
      let content = try String(contentsOfFile: from, encoding: .utf8)
      fromSchema = try parser.parse(content, sourceFile: from)
    } else if let app = appId, let token = adminToken {
      print("📡 Fetching deployed schema as source...")
      let api = InstantDBAPI(adminToken: token)
      fromSchema = try await api.fetchSchema(appID: app)
    } else {
      print("Error: No source schema specified")
      print("Usage: instant-schema migrate --from old.schema.ts --to new.schema.ts")
      print("   or: instant-schema migrate --app-id <id> --to new.schema.ts")
      exit(1)
    }
    
    // Parse "to" schema
    guard let to = toPath else {
      print("Error: No target schema specified")
      print("Usage: instant-schema migrate --from old.schema.ts --to new.schema.ts")
      exit(1)
    }
    
    print("📖 Parsing target schema from \(to)...")
    let parser = CommentPreservingSchemaParser()
    let content = try String(contentsOfFile: to, encoding: .utf8)
    let toSchema = try parser.parse(content, sourceFile: to)
    
    print("")
    print("Source: \(fromSchema.entities.count) entities, \(fromSchema.links.count) links")
    print("Target: \(toSchema.entities.count) entities, \(toSchema.links.count) links")
    print("")
    
    // Generate migration
    let migration = SchemaMigration(from: fromSchema, to: toSchema)
    
    if migration.changes.isEmpty {
      print("✅ No changes detected - schemas are identical")
      return
    }
    
    // Print summary
    print(migration.summary())
    
    // Generate script if requested
    if showScript {
      print("")
      print("=" .padding(toLength: 60, withPad: "=", startingAt: 0))
      print("TypeScript Migration Script")
      print("=" .padding(toLength: 60, withPad: "=", startingAt: 0))
      print("")
      
      let script = migration.generateTypeScriptMigration()
      
      if let output = outputPath {
        try script.write(toFile: output, atomically: true, encoding: .utf8)
        print("✅ Migration script saved to \(output)")
      } else {
        print(script)
      }
    } else if let output = outputPath {
      let script = migration.generateTypeScriptMigration()
      try script.write(toFile: output, atomically: true, encoding: .utf8)
      print("✅ Migration script saved to \(output)")
    }
  }
  
  // MARK: - Swift to TypeScript Command
  
  /// Generate TypeScript from Swift schema files
  static func swiftToTypeScriptCommand(_ args: [String]) async throws {
    var inputPath: String?
    var outputPath: String = "instant.schema.ts"
    
    var i = 0
    while i < args.count {
      switch args[i] {
      case "--from", "-f":
        i += 1
        inputPath = args[i]
      case "--to", "-t", "--output", "-o":
        i += 1
        outputPath = args[i]
      default:
        if inputPath == nil {
          inputPath = args[i]
        }
      }
      i += 1
    }
    
    guard let input = inputPath else {
      print("Error: No input path specified")
      print("Usage: instant-schema swift-to-ts --from Sources/Schema/ --to instant.schema.ts")
      print("   or: instant-schema swift-to-ts Sources/Schema/*.swift")
      exit(1)
    }
    
    print("📖 Parsing Swift schema from \(input)...")
    
    let parser = SwiftSchemaParser()
    let schema: SchemaIR
    
    // Check if input is a directory or file
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: input, isDirectory: &isDirectory)
    
    if !exists {
      print("Error: Input path does not exist: \(input)")
      exit(1)
    }
    
    if isDirectory.boolValue {
      // Parse all Swift files in directory
      schema = try parser.parseDirectory(at: input)
    } else {
      // Parse single file
      schema = try parser.parse(fileAt: input)
    }
    
    print("✅ Found \(schema.entities.count) entities, \(schema.links.count) links")
    
    print("🔨 Generating TypeScript schema...")
    
    let printer = TypeScriptSchemaPrinter()
    let output = printer.print(schema)
    
    try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
    print("✅ Generated TypeScript schema: \(outputPath)")
  }
  
  // MARK: - Help
  
  static func printUsage() {
    print("""
    instant-schema - InstantDB Schema Codegen Tool
    
    USAGE:
      instant-schema <command> [options]
    
    COMMANDS:
      generate    Generate Swift code from TypeScript schema or API
      swift-to-ts Generate TypeScript from Swift schema files (alias: s2t)
      pull        Fetch deployed schema from InstantDB
      parse       Parse a schema file and display the IR
      print       Print IR back to TypeScript format
      verify      Verify local schema matches deployed schema
      diff        Show differences between local and deployed schema
      migrate     Generate migration script between two schemas
      help        Show this help message
      version     Show version
    
    GENERATE OPTIONS:
      --from, -f <file>      Input TypeScript schema file
      --to, -t <dir>         Output directory (default: Sources/Generated/)
      --app-id, -a <id>      App ID (can also use INSTANT_APP_ID env var)
      --admin-token <token>  Admin token (can also use INSTANT_ADMIN_TOKEN env var)
    
    PULL OPTIONS:
      --app-id, -a <id>      App ID (required)
      --admin-token <token>  Admin token (required)
      --output, -o <file>    Output file (prints to stdout if not specified)
      --format <format>      Output format: typescript (default) or json
      --json                 Shorthand for --format json
    
    VERIFY OPTIONS:
      --app-id, -a <id>      App ID (required)
      --admin-token <token>  Admin token (required)
      --local, -l <file>     Local schema file (required)
      --strict               Exit with error code 1 if schemas differ
    
    SWIFT-TO-TS OPTIONS:
      --from, -f <path>      Input Swift file or directory
      --to, -t <file>        Output TypeScript file (default: instant.schema.ts)
    
    MIGRATE OPTIONS:
      --from, -f <file>      Source schema (file or use --app-id for deployed)
      --to, -t <file>        Target schema file
      --output, -o <file>    Output migration script file
      --script               Print migration script to stdout
      --app-id, -a <id>      Use deployed schema as source
      --admin-token <token>  Admin token for API access
    
    EXAMPLES:
      # Generate Swift from TypeScript
      instant-schema generate --from instant.schema.ts --to Sources/Generated/
    
      # Generate Swift directly from deployed schema
      instant-schema generate --app-id abc123 --admin-token xyz --to Sources/Generated/
    
      # Generate TypeScript from Swift (iOS-first workflow)
      instant-schema swift-to-ts --from Sources/Schema/ --to instant.schema.ts
    
      # Pull deployed schema as TypeScript
      instant-schema pull --app-id abc123 --admin-token xyz -o instant.schema.ts
    
      # Verify local matches deployed
      instant-schema verify --app-id abc123 --admin-token xyz --local instant.schema.ts
    
      # Show diff between local and deployed
      instant-schema diff --app-id abc123 --admin-token xyz --local instant.schema.ts
    
      # Generate migration script from deployed to local
      instant-schema migrate --app-id abc123 --admin-token xyz --to new.schema.ts --script
    
      # Generate migration script between two files
      instant-schema migrate --from old.schema.ts --to new.schema.ts -o migrate.ts
    
    ENVIRONMENT VARIABLES:
      INSTANT_APP_ID         Default app ID for all commands
      INSTANT_ADMIN_TOKEN    Admin token for API access
    
    SPM BUILD PLUGIN:
      Add the InstantSchemaPlugin to your Package.swift to automatically
      generate Swift types on every build. See documentation for setup.
    
    """)
  }
}
