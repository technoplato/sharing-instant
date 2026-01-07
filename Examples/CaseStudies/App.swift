import SharingInstant
import SwiftUI

@main
struct CaseStudiesApp: App {
  
  init() {
    prepareDependencies {
      // Use the test InstantDB app
      $0.instantAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
    }
  }
  
  var body: some Scene {
    WindowGroup {
      NavigationStack {
        List {
          Section {
            VStack(alignment: .leading, spacing: 8) {
              Text("SharingInstant")
                .font(.largeTitle)
                .bold()
              Text("A Swift Sharing integration for InstantDB's real-time database.")
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
          }
          
          Section {
            DisclosureGroup {
              Text("""
                SharingInstant brings the power of Point-Free's Sharing library to InstantDB, \
                enabling local-first, optimistic updates with automatic synchronization.
                
                • **@Shared** - Read-write sync with optimistic updates
                • **@SharedReader** - Read-only queries
                • **Dynamic Keys** - Filter and search in real-time
                • **Real-time Sync** - Changes sync across all devices instantly
                """)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            } label: {
              Label("About", systemImage: "info.circle")
            }
          }
          
          Section("Examples") {
            // NOTE: The key demo for dynamic queries with server-side filtering
            // is the Advanced Todo demo below. It demonstrates search, sort, and
            // filter operations all happening on the InstantDB server.
            
            // MARK: - Commented out demos (kept for reference)
            // SwiftUISyncDemo - Basic bidirectional sync (simpler than AdvancedTodo)
            // DynamicFilterDemo - Client-side filtering (less efficient than server-side)
            // ObservableModelDemo - @Observable pattern (alternative to @Shared)
            
//            NavigationLink {
//              CaseStudyView {
//                SwiftUISyncDemo()
//              }
//            } label: {
//              VStack(alignment: .leading, spacing: 4) {
//                Label("Sync Demo", systemImage: "arrow.triangle.2.circlepath")
//                Text("Bidirectional sync with optimistic updates")
//                  .font(.caption)
//                  .foregroundStyle(.secondary)
//              }
//            }
            
            NavigationLink {
              CaseStudyView {
                MicroblogDemo()
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Label("Microblog (Links)", systemImage: "link")
                Text("Entity relationships with .with()")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            
            NavigationLink {
              CaseStudyView {
                AdvancedTodoDemo()
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Label("Advanced Todo", systemImage: "checklist")
                Text("Server-side search, sort, and filter with dynamic queries")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            
//            NavigationLink {
//              CaseStudyView {
//                DynamicFilterDemo()
//              }
//            } label: {
//              VStack(alignment: .leading, spacing: 4) {
//                Label("Dynamic Filtering", systemImage: "line.3.horizontal.decrease.circle")
//                Text("Search and filter with dynamic keys")
//                  .font(.caption)
//                  .foregroundStyle(.secondary)
//              }
//            }
            
//            NavigationLink {
//              CaseStudyView {
//                ObservableModelDemo()
//              }
//            } label: {
//              VStack(alignment: .leading, spacing: 4) {
//                Label("Observable Model", systemImage: "cube")
//                Text("Use @Shared with @Observable models")
//                  .font(.caption)
//                  .foregroundStyle(.secondary)
//              }
//            }
            NavigationLink {
              CaseStudyView {
                RecursiveLoaderDemo()
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Label("Recursive Loader", systemImage: "arrow.triangle.branch")
                Text("Deeply nested queries (User -> Posts -> Comments)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }

            NavigationLink {
              CaseStudyView {
                StorageDemo()
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Label("Storage", systemImage: "externaldrive")
                Text("Upload, list, and preview files ($files)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
          
          Section("Presence & Real-time") {
            NavigationLink {
              CaseStudyView {
                CursorsDemo()
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Label("Cursors", systemImage: "cursorarrow.rays")
                Text("Real-time cursor tracking across users")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            
            NavigationLink {
              CaseStudyView {
                TypingIndicatorDemo()
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Label("Typing Indicators", systemImage: "text.bubble")
                Text("Show when other users are typing")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            
            NavigationLink {
              CaseStudyView {
                AvatarStackDemo()
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Label("Avatar Stack", systemImage: "person.2.circle")
                Text("Show who's currently in a room")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            
            NavigationLink {
              CaseStudyView {
                TopicsDemo()
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Label("Topics (Emoji Reactions)", systemImage: "antenna.radiowaves.left.and.right")
                Text("Ephemeral broadcast events")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            
            NavigationLink {
              CaseStudyView {
                TileGameDemo()
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Label("Tile Game", systemImage: "square.grid.3x3.fill")
                Text("Collaborative game with presence + sync")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
          
          Section("Bug Reproductions") {
            NavigationLink {
              CaseStudyView {
                DifferentWithClausesDemo()
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Label("Different .with() Clauses", systemImage: "exclamationmark.triangle")
                Text("Optimistic updates across different query shapes")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }

            NavigationLink {
              CaseStudyView {
                RapidTranscriptionDemo()
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Label("Rapid Updates", systemImage: "waveform")
                Text("Rapid text updates like speech transcription")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
          
          Section("Authentication") {
            NavigationLink {
              CaseStudyView {
                AuthDemo()
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Label("Auth Flow", systemImage: "person.badge.key")
                Text("Guest, magic code, and Apple sign-in")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Case Studies")
      }
    }
  }
}
