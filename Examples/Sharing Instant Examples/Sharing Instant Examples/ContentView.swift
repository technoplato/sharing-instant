//
//  ContentView.swift
//  Sharing Instant Examples
//
//  Created by Michael Lustig on 12/17/25.
//

import InstantDB
import SharingInstant
import SwiftUI

struct ContentView: View {
  /// The shared InstantDB client.
  /// We access it here to show connection status in the UI.
  @State private var client: InstantClient?
  
  var body: some View {
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
        
        // Connection Status Section
        if let client = client {
          Section("Connection Status") {
            ConnectionStatusView(client: client)
          }
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
        
        Section("Data Sync Examples") {
          NavigationLink {
            CaseStudyView {
              SwiftUISyncDemo()
            }
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Label("Sync Demo", systemImage: "arrow.triangle.2.circlepath")
              Text("Bidirectional sync with optimistic updates")
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
              Text("Search, sort, and filter todos")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          
          NavigationLink {
            CaseStudyView {
              ObservableModelDemo()
            }
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Label("Observable Model", systemImage: "cube")
              Text("Use @Shared with @Observable models")
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
      .task {
        // Get the shared InstantDB client on main actor
        await MainActor.run {
          client = InstantClientFactory.makeClient()
        }
      }
    }
  }
}

#Preview {
  ContentView()
}
