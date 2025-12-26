// main.swift
// instant-schema CLI
//
// Command-line tool for InstantDB schema codegen and validation.
//
// Built with swift-argument-parser for type-safe argument handling.

import ArgumentParser
import Foundation
import InstantSchemaCodegen

// MARK: - Root Command

@main
struct InstantSchema: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "instant-schema",
    abstract: "InstantDB Schema Codegen Tool",
    discussion: """
      Generate type-safe Swift code from your InstantDB TypeScript schema.
      
      ENVIRONMENT VARIABLES:
        INSTANT_APP_ID         Default app ID for all commands
        INSTANT_ADMIN_TOKEN    Admin token for API access
      
      SPM BUILD PLUGIN:
        Add the InstantSchemaPlugin to your Package.swift to automatically
        generate Swift types on every build. See documentation for setup.
      """,
    version: "0.1.0",
    subcommands: [
      Generate.self,
      Sample.self,
      Pull.self,
      Verify.self,
      Diff.self,
      Migrate.self,
      Parse.self,
      Print.self,
      SwiftToTS.self,
    ],
    defaultSubcommand: nil
  )
}

// MARK: - Generate Command

extension InstantSchema {
  struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "generate",
      abstract: "Generate Swift code from TypeScript schema or API",
      aliases: ["gen"]
    )
    
    @Option(name: [.customShort("f"), .customLong("from")], help: "Input TypeScript schema file")
    var inputPath: String?
    
    @Option(name: [.customShort("t"), .customLong("to")], help: "Output directory")
    var outputDir: String = "Sources/Generated"
    
    @Option(name: [.customShort("a"), .customLong("app-id")], help: "InstantDB App ID (or set INSTANT_APP_ID)")
    var appId: String?
    
    @Option(name: .long, help: "Admin token for API access (or set INSTANT_ADMIN_TOKEN)")
    var adminToken: String?
    
    @Flag(name: .long, help: "Validate that generated files are up-to-date without modifying them")
    var validate: Bool = false
    
    mutating func run() async throws {
      // Resolve credentials from environment if not provided
      let resolvedAppId = appId ?? ProcessInfo.processInfo.environment["INSTANT_APP_ID"]
      let resolvedToken = adminToken ?? ProcessInfo.processInfo.environment["INSTANT_ADMIN_TOKEN"]
      
      // Skip git check in validate mode - we're just comparing files
      if !validate {
        // STEP 1: Ensure git working directory is clean
        print("🔍 Checking git status...")
        try GitUtilities.ensureCleanWorkingDirectory()
        print("✅ Working directory is clean")
      } else {
        print("🔍 Validating generated files are up-to-date...")
      }
      
      // STEP 2: Get schema from file or API
      let schema: SchemaIR
      let resolvedInputPath: String
      
      if let input = inputPath {
        print("📖 Parsing \(input)...")
        let parser = CommentPreservingSchemaParser()
        schema = try parser.parse(String(contentsOfFile: input, encoding: .utf8), sourceFile: input)
        resolvedInputPath = input
      } else if let app = resolvedAppId, let token = resolvedToken {
        print("📡 Fetching schema from InstantDB for app \(app)...")
        let api = InstantDBAPI(adminToken: token)
        schema = try await api.fetchSchema(appID: app)
        resolvedInputPath = "InstantDB API (app: \(app))"
      } else {
        throw ValidationError("""
          No input file or API credentials specified.
          
          Either provide a schema file:
            instant-schema generate --from instant.schema.ts
          
          Or provide API credentials:
            instant-schema generate --app-id <id> --admin-token <token>
          
          Or set environment variables:
            export INSTANT_APP_ID=<id>
            export INSTANT_ADMIN_TOKEN=<token>
          """)
      }
      
      print("✅ Found \(schema.entities.count) entities, \(schema.links.count) links, \(schema.rooms.count) rooms")
      
      // STEP 3: Build generation context (use validation context if in validate mode)
      let context: GenerationContext?
      if validate {
        // In validate mode, we use a minimal context that produces stable output
        // for comparison (no timestamps, git info, or machine info)
        context = nil
      } else {
        print("📋 Capturing generation context...")
        context = try buildGenerationContext(
          inputPath: resolvedInputPath,
          outputDir: outputDir
        )
      }
      
      // STEP 4: Generate Swift code
      print("🔨 Generating Swift code...")
      let generator = SwiftCodeGenerator()
      let files = generator.generate(from: schema, context: context)
      
      if validate {
        // VALIDATION MODE: Compare generated files against existing files
        try runValidation(files: files)
      } else {
        // NORMAL MODE: Write files to disk
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        
        for file in files {
          let path = (outputDir as NSString).appendingPathComponent(file.name)
          try file.content.write(toFile: path, atomically: true, encoding: .utf8)
          print("  ✓ \(path)")
        }
        
        print("✅ Generated \(files.count) files in \(outputDir)")
        print("")
        print("📝 Generation Info:")
        print("   Date:    \(context!.formattedDate)")
        print("   Machine: \(context!.machine.formatted)")
        if let gitState = context!.gitState {
          print("   Commit:  \(String(gitState.headCommit.sha.prefix(8))) - \(gitState.headCommit.message)")
        }
      }
    }
    
    /// Validates that existing generated files match what would be generated.
    /// 
    /// Compares the semantic content of files, stripping dynamic metadata
    /// (timestamps, git state, machine info) before comparison.
    /// 
    /// Returns successfully if files are up-to-date, throws if there are differences.
    private func runValidation(files: [SwiftCodeGenerator.GeneratedFile]) throws {
      var hasErrors = false
      var missingFiles: [String] = []
      var differentFiles: [(name: String, existingLines: Int, expectedLines: Int)] = []
      
      print("")
      print("📋 Comparing \(files.count) generated files against \(outputDir)...")
      print("")
      
      for file in files {
        let existingPath = (outputDir as NSString).appendingPathComponent(file.name)
        
        // Check if file exists
        guard FileManager.default.fileExists(atPath: existingPath) else {
          print("  ❌ \(file.name) - MISSING")
          missingFiles.append(file.name)
          hasErrors = true
          continue
        }
        
        // Read existing file
        let existingContent: String
        do {
          existingContent = try String(contentsOfFile: existingPath, encoding: .utf8)
        } catch {
          print("  ❌ \(file.name) - Could not read: \(error.localizedDescription)")
          hasErrors = true
          continue
        }
        
        // Compare semantic content (strip dynamic metadata)
        let existingStripped = stripDynamicMetadata(from: existingContent)
        let generatedStripped = stripDynamicMetadata(from: file.content)
        
        if existingStripped == generatedStripped {
          print("  ✓ \(file.name) - up to date")
        } else {
          print("  ❌ \(file.name) - OUT OF DATE")
          let existingLines = existingStripped.components(separatedBy: .newlines).count
          let expectedLines = generatedStripped.components(separatedBy: .newlines).count
          differentFiles.append((name: file.name, existingLines: existingLines, expectedLines: expectedLines))
          hasErrors = true
          
          // Find first differing line for debugging
          let existingLinesArray = existingStripped.components(separatedBy: .newlines)
          let expectedLinesArray = generatedStripped.components(separatedBy: .newlines)
          for (i, (existing, expected)) in zip(existingLinesArray, expectedLinesArray).enumerated() {
            if existing != expected {
              print("      First difference at line \(i + 1):")
              print("        existing: \"\(existing.prefix(80))\"")
              print("        expected: \"\(expected.prefix(80))\"")
              break
            }
          }
          if existingLinesArray.count != expectedLinesArray.count {
            print("      Line count: existing=\(existingLinesArray.count), expected=\(expectedLinesArray.count)")
          }
        }
      }
      
      print("")
      
      if hasErrors {
        print("═══════════════════════════════════════════════════════════════════════════════")
        print("❌ VALIDATION FAILED")
        print("═══════════════════════════════════════════════════════════════════════════════")
        print("")
        
        if !missingFiles.isEmpty {
          print("Missing files:")
          for file in missingFiles {
            print("  • \(file)")
          }
          print("")
        }
        
        if !differentFiles.isEmpty {
          print("Files that need regeneration:")
          for (name, existingLines, expectedLines) in differentFiles {
            print("  • \(name) (existing: \(existingLines) lines, expected: \(expectedLines) lines)")
          }
          print("")
        }
        
        print("To fix, run:")
        print("  swift run instant-schema generate --from \(inputPath ?? "<schema>") --to \(outputDir)")
        print("")
        
        throw ExitCode.failure
      } else {
        print("═══════════════════════════════════════════════════════════════════════════════")
        print("✅ VALIDATION PASSED - All generated files are up to date")
        print("═══════════════════════════════════════════════════════════════════════════════")
      }
    }
    
    /// Strips dynamic metadata from generated file content for comparison.
    /// 
    /// This removes sections that change on every generation:
    /// - GENERATION INFO section (timestamps, machine info) and its preceding divider
    /// - GIT STATE AT GENERATION section
    /// - Regeneration command comments (contain absolute paths)
    /// 
    /// The approach: extract just the code (starting from `import` outside of comments) and compare that.
    /// The headers are documentation and don't affect functionality.
    private func stripDynamicMetadata(from content: String) -> String {
      let lines = content.components(separatedBy: .newlines)
      
      // Find the first import statement that's NOT inside a block comment
      var inBlockComment = false
      var importIndex: Int? = nil
      
      for (index, line) in lines.enumerated() {
        // Track block comment state
        if line.contains("/*") {
          inBlockComment = true
        }
        if line.contains("*/") {
          inBlockComment = false
          continue  // The */ line itself might have content after it
        }
        
        // Look for import outside of block comments
        if !inBlockComment && line.hasPrefix("import ") {
          importIndex = index
          break
        }
      }
      
      guard let startIndex = importIndex else {
        // No import found outside comments, return as-is
        return content
      }
      
      // Return everything from the first real import onwards
      let codeLines = Array(lines[startIndex...])
      
      // Normalize: remove trailing empty lines
      var normalized = codeLines
      while let last = normalized.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        normalized.removeLast()
      }
      
      return normalized.joined(separator: "\n")
    }
    
    private func buildGenerationContext(inputPath: String, outputDir: String) throws -> GenerationContext {
      let headCommit = try GitUtilities.getHeadCommit()
      let schemaLastModified: GitCommit
      
      if !inputPath.contains("InstantDB API") {
        schemaLastModified = try GitUtilities.getLastModifyingCommit(forFile: inputPath)
      } else {
        schemaLastModified = headCommit
      }
      
      let command = "swift run instant-schema generate --from \(inputPath) --to \(outputDir)"
      let relativeInputPath = GitUtilities.relativePath(from: inputPath)
      let relativeOutputDir = GitUtilities.relativePath(from: outputDir)
      
      return GenerationContext(
        generatedAt: Date(),
        timezone: .current,
        machine: MachineInfo.current(),
        generatorPath: "Sources/instant-schema/main.swift",
        sourceSchemaPath: relativeInputPath,
        outputDirectory: relativeOutputDir,
        mode: .production(ProductionContext(
          gitState: GitState(
            headCommit: headCommit,
            schemaLastModified: schemaLastModified
          ),
          command: command
        ))
      )
    }
  }
}

// MARK: - Sample Command

extension InstantSchema {
  struct Sample: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "sample",
      abstract: "Generate sample schema and Swift types for quick start"
    )
    
    @Option(name: [.customShort("t"), .customLong("to")], help: "Output directory for Swift types")
    var outputDir: String = "Sources/Generated"
    
    @Option(name: [.customShort("s"), .customLong("schema")], help: "Output path for TypeScript schema")
    var schemaPath: String = "instant.schema.ts"
    
    @Flag(name: .long, help: "Skip generating the TypeScript schema file")
    var skipSchema: Bool = false
    
    mutating func run() async throws {
      print("🎉 Generating sample schema and Swift types...")
      print("")
      
      let sampleSchema = """
        // instant.schema.ts
        // Sample schema for sharing-instant quick start
        //
        // This schema defines:
        // - A "todos" entity for a todo list app
        // - A "chat" room for presence features (typing indicators, online status)
        //
        // To use this schema:
        // 1. Create an InstantDB project at https://instantdb.com/dash/new
        // 2. Push this schema: npx instant-cli@latest push schema --app YOUR_APP_ID
        // 3. Generate Swift types: swift run instant-schema generate --from instant.schema.ts
        
        import { i } from "@instantdb/core";
        
        const _schema = i.schema({
          entities: {
            todos: i.entity({
              title: i.string(),
              done: i.boolean(),
              createdAt: i.number().indexed(),
            }),
          },
          rooms: {
            chat: {
              presence: i.entity({
                name: i.string(),
                color: i.string(),
                isTyping: i.boolean(),
              }),
            },
          },
        });
        
        type _AppSchema = typeof _schema;
        interface AppSchema extends _AppSchema {}
        const schema: AppSchema = _schema;
        
        export type { AppSchema };
        export default schema;
        """
      
      // Write schema file if not skipping
      if !skipSchema {
        if FileManager.default.fileExists(atPath: schemaPath) {
          throw ValidationError("""
            Schema file already exists: \(schemaPath)
            
            Use --skip-schema to skip schema generation
            Or specify a different path with --schema <path>
            """)
        }
        
        try sampleSchema.write(toFile: schemaPath, atomically: true, encoding: .utf8)
        print("✅ Created sample schema: \(schemaPath)")
      }
      
      // Parse the schema
      let parser = CommentPreservingSchemaParser()
      let schema = try parser.parse(sampleSchema, sourceFile: "instant.schema.ts")
      
      print("📋 Schema contains: \(schema.entities.count) entity, \(schema.rooms.count) room")
      
      // Generate Swift types
      print("🔨 Generating Swift types...")
      
      let generator = SwiftCodeGenerator()
      let context = GenerationContext(
        generatedAt: Date(),
        timezone: .current,
        machine: MachineInfo.current(),
        generatorPath: "instant-schema sample",
        sourceSchemaPath: schemaPath,
        outputDirectory: outputDir,
        mode: .sample(SampleContext(description: "Sample schema for sharing-instant quick start"))
      )
      
      let files = generator.generate(from: schema, context: context)
      
      try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
      
      for file in files {
        let path = (outputDir as NSString).appendingPathComponent(file.name)
        try file.content.write(toFile: path, atomically: true, encoding: .utf8)
        print("  ✓ \(path)")
      }
      
      print("")
      print("✅ Generated \(files.count) files in \(outputDir)")
      print("")
      print(String(repeating: "=", count: 60))
      print("🚀 Quick Start")
      print(String(repeating: "=", count: 60))
      print("""
        
        1. Create an InstantDB project:
           https://www.instantdb.com/dash/new
        
        2. Push the schema to InstantDB:
           npx instant-cli@latest push schema --app YOUR_APP_ID
        
        3. Configure your app:
        
           import SharingInstant
        
           @main
           struct MyApp: App {
             init() {
               prepareDependencies {
                 $0.defaultInstant = InstantClient(appId: "YOUR_APP_ID")
               }
             }
             // ...
           }
        
        4. Use in your views:
        
           @Shared(.instantSync(Schema.todos))
           private var todos: IdentifiedArrayOf<Todo> = []
        
        See README.md for complete examples.
        
        """)
    }
  }
}

// MARK: - Pull Command

extension InstantSchema {
  struct Pull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "pull",
      abstract: "Fetch deployed schema from InstantDB"
    )
    
    @Option(name: [.customShort("a"), .customLong("app-id")], help: "InstantDB App ID (or set INSTANT_APP_ID)")
    var appId: String?
    
    @Option(name: .long, help: "Admin token (or set INSTANT_ADMIN_TOKEN)")
    var adminToken: String?
    
    @Option(name: [.customShort("o"), .long], help: "Output file (prints to stdout if not specified)")
    var output: String?
    
    @Option(name: .long, help: "Output format: typescript (default) or json")
    var format: OutputFormat = .typescript
    
    @Flag(name: .long, help: "Output as JSON (shorthand for --format json)")
    var json: Bool = false
    
    enum OutputFormat: String, ExpressibleByArgument {
      case typescript, json
    }
    
    mutating func run() async throws {
      let resolvedAppId = appId ?? ProcessInfo.processInfo.environment["INSTANT_APP_ID"]
      let resolvedToken = adminToken ?? ProcessInfo.processInfo.environment["INSTANT_ADMIN_TOKEN"]
      
      guard let app = resolvedAppId else {
        throw ValidationError("No app ID specified. Use --app-id or set INSTANT_APP_ID")
      }
      
      guard let token = resolvedToken else {
        throw ValidationError("No admin token specified. Use --admin-token or set INSTANT_ADMIN_TOKEN")
      }
      
      print("📡 Fetching schema from InstantDB...")
      print("   App ID: \(app)")
      
      let api = InstantDBAPI(adminToken: token)
      let outputFormat = json ? OutputFormat.json : format
      
      if outputFormat == .json {
        let data = try await api.fetchSchemaJSON(appID: app)
        let jsonObj = try JSONSerialization.jsonObject(with: data)
        let prettyData = try JSONSerialization.data(withJSONObject: jsonObj, options: [.prettyPrinted, .sortedKeys])
        let outputStr = String(data: prettyData, encoding: .utf8)!
        
        if let path = output {
          try outputStr.write(toFile: path, atomically: true, encoding: .utf8)
          print("✅ Saved raw JSON to \(path)")
        } else {
          print(outputStr)
        }
      } else {
        let schema = try await api.fetchSchema(appID: app)
        print("✅ Found \(schema.entities.count) entities, \(schema.links.count) links")
        
        let printer = TypeScriptSchemaPrinter()
        let outputStr = printer.print(schema)
        
        if let path = output {
          try outputStr.write(toFile: path, atomically: true, encoding: .utf8)
          print("✅ Saved TypeScript schema to \(path)")
        } else {
          print("")
          print(outputStr)
        }
      }
    }
  }
}

// MARK: - Verify Command

extension InstantSchema {
  struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "verify",
      abstract: "Verify local schema matches deployed schema"
    )
    
    @Option(name: [.customShort("a"), .customLong("app-id")], help: "InstantDB App ID (or set INSTANT_APP_ID)")
    var appId: String?
    
    @Option(name: .long, help: "Admin token (or set INSTANT_ADMIN_TOKEN)")
    var adminToken: String?
    
    @Option(name: [.customShort("l"), .long], help: "Local schema file")
    var local: String
    
    @Flag(name: .long, help: "Exit with error code 1 if schemas differ")
    var strict: Bool = false
    
    mutating func run() async throws {
      let resolvedAppId = appId ?? ProcessInfo.processInfo.environment["INSTANT_APP_ID"]
      let resolvedToken = adminToken ?? ProcessInfo.processInfo.environment["INSTANT_ADMIN_TOKEN"]
      
      guard let app = resolvedAppId else {
        throw ValidationError("No app ID specified. Use --app-id or set INSTANT_APP_ID")
      }
      
      guard let token = resolvedToken else {
        throw ValidationError("No admin token specified. Use --admin-token or set INSTANT_ADMIN_TOKEN")
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
          throw ExitCode.failure
        }
      } else {
        print("✅ Schemas match!")
      }
    }
  }
}

// MARK: - Diff Command

extension InstantSchema {
  struct Diff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "diff",
      abstract: "Show differences between local and deployed schema"
    )
    
    @Option(name: [.customShort("a"), .customLong("app-id")], help: "InstantDB App ID (or set INSTANT_APP_ID)")
    var appId: String?
    
    @Option(name: .long, help: "Admin token (or set INSTANT_ADMIN_TOKEN)")
    var adminToken: String?
    
    @Option(name: [.customShort("l"), .long], help: "Local schema file")
    var local: String
    
    mutating func run() async throws {
      let resolvedAppId = appId ?? ProcessInfo.processInfo.environment["INSTANT_APP_ID"]
      let resolvedToken = adminToken ?? ProcessInfo.processInfo.environment["INSTANT_ADMIN_TOKEN"]
      
      guard let app = resolvedAppId else {
        throw ValidationError("No app ID specified. Use --app-id or set INSTANT_APP_ID")
      }
      
      guard let token = resolvedToken else {
        throw ValidationError("No admin token specified. Use --admin-token or set INSTANT_ADMIN_TOKEN")
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
  }
}

// MARK: - Migrate Command

extension InstantSchema {
  struct Migrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "migrate",
      abstract: "Generate migration script between two schemas"
    )
    
    @Option(name: [.customShort("f"), .customLong("from")], help: "Source schema file (or use --app-id for deployed)")
    var fromPath: String?
    
    @Option(name: [.customShort("t"), .customLong("to")], help: "Target schema file")
    var toPath: String
    
    @Option(name: [.customShort("o"), .long], help: "Output migration script file")
    var output: String?
    
    @Option(name: [.customShort("a"), .customLong("app-id")], help: "Use deployed schema as source")
    var appId: String?
    
    @Option(name: .long, help: "Admin token for API access")
    var adminToken: String?
    
    @Flag(name: .long, help: "Print migration script to stdout")
    var script: Bool = false
    
    mutating func run() async throws {
      let resolvedAppId = appId ?? ProcessInfo.processInfo.environment["INSTANT_APP_ID"]
      let resolvedToken = adminToken ?? ProcessInfo.processInfo.environment["INSTANT_ADMIN_TOKEN"]
      
      // Parse "from" schema
      let fromSchema: SchemaIR
      if let from = fromPath {
        print("📖 Parsing source schema from \(from)...")
        let parser = CommentPreservingSchemaParser()
        let content = try String(contentsOfFile: from, encoding: .utf8)
        fromSchema = try parser.parse(content, sourceFile: from)
      } else if let app = resolvedAppId, let token = resolvedToken {
        print("📡 Fetching deployed schema as source...")
        let api = InstantDBAPI(adminToken: token)
        fromSchema = try await api.fetchSchema(appID: app)
      } else {
        throw ValidationError("""
          No source schema specified.
          
          Either provide a schema file:
            instant-schema migrate --from old.schema.ts --to new.schema.ts
          
          Or use deployed schema as source:
            instant-schema migrate --app-id <id> --to new.schema.ts
          """)
      }
      
      // Parse "to" schema
      print("📖 Parsing target schema from \(toPath)...")
      let parser = CommentPreservingSchemaParser()
      let content = try String(contentsOfFile: toPath, encoding: .utf8)
      let toSchema = try parser.parse(content, sourceFile: toPath)
      
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
      if script {
        print("")
        print(String(repeating: "=", count: 60))
        print("TypeScript Migration Script")
        print(String(repeating: "=", count: 60))
        print("")
        
        let scriptContent = migration.generateTypeScriptMigration()
        
        if let outputPath = output {
          try scriptContent.write(toFile: outputPath, atomically: true, encoding: .utf8)
          print("✅ Migration script saved to \(outputPath)")
        } else {
          print(scriptContent)
        }
      } else if let outputPath = output {
        let scriptContent = migration.generateTypeScriptMigration()
        try scriptContent.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print("✅ Migration script saved to \(outputPath)")
      }
    }
  }
}

// MARK: - Parse Command

extension InstantSchema {
  struct Parse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "parse",
      abstract: "Parse a schema file and display the IR"
    )
    
    @Argument(help: "Schema file to parse")
    var file: String
    
    mutating func run() async throws {
      let content = try String(contentsOfFile: file, encoding: .utf8)
      
      let parser = CommentPreservingSchemaParser()
      let schema = try parser.parse(content, sourceFile: file)
      
      print("Schema from \(file):")
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
  }
}

// MARK: - Print Command

extension InstantSchema {
  struct Print: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "print",
      abstract: "Print IR back to TypeScript format"
    )
    
    @Argument(help: "Schema file to parse and print")
    var file: String
    
    mutating func run() async throws {
      let content = try String(contentsOfFile: file, encoding: .utf8)
      
      let parser = CommentPreservingSchemaParser()
      let schema = try parser.parse(content, sourceFile: file)
      
      let output = try parser.print(schema)
      Swift.print(output)
    }
  }
}

// MARK: - Swift to TypeScript Command

extension InstantSchema {
  struct SwiftToTS: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "swift-to-ts",
      abstract: "Generate TypeScript from Swift schema files",
      aliases: ["s2t"]
    )
    
    @Option(name: [.customShort("f"), .customLong("from")], help: "Input Swift file or directory")
    var inputPath: String?
    
    @Option(name: [.customShort("t"), .customLong("to")], help: "Output TypeScript file")
    var outputPath: String = "instant.schema.ts"
    
    @Argument(help: "Input Swift file or directory (alternative to --from)")
    var input: String?
    
    mutating func run() async throws {
      let resolvedInput = inputPath ?? input
      
      guard let inputDir = resolvedInput else {
        throw ValidationError("""
          No input path specified.
          
          Usage:
            instant-schema swift-to-ts --from Sources/Schema/ --to instant.schema.ts
            instant-schema swift-to-ts Sources/Schema/*.swift
          """)
      }
      
      print("📖 Parsing Swift schema from \(inputDir)...")
      
      let parser = SwiftSchemaParser()
      let schema: SchemaIR
      
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: inputDir, isDirectory: &isDirectory)
      
      guard exists else {
        throw ValidationError("Input path does not exist: \(inputDir)")
      }
      
      if isDirectory.boolValue {
        schema = try parser.parseDirectory(at: inputDir)
      } else {
        schema = try parser.parse(fileAt: inputDir)
      }
      
      print("✅ Found \(schema.entities.count) entities, \(schema.links.count) links")
      
      print("🔨 Generating TypeScript schema...")
      
      let printer = TypeScriptSchemaPrinter()
      let output = printer.print(schema)
      
      try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
      print("✅ Generated TypeScript schema: \(outputPath)")
    }
  }
}
