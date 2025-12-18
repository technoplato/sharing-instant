//
//  ContentView.swift
//  Sharing Instant Examples
//
//  Created by Michael Lustig on 12/17/25.
//

import SharingInstant
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
  var body: some View {
    NavigationStack {
      List {
        #if os(watchOS)
        // Compact header for watchOS
        Section {
          Text("SharingInstant")
            .font(.headline)
            .bold()
        }
        #else
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
        Section("Connection Status") {
          ConnectionStatusView()
        }
        #endif
        
        #if os(tvOS)
        // tvOS doesn't support DisclosureGroup
        Section("About") {
          Text("""
            SharingInstant brings the power of Point-Free's Sharing library to InstantDB, \
            enabling local-first, optimistic updates with automatic synchronization.
            
            • @Shared - Read-write sync with optimistic updates
            • @SharedReader - Read-only queries
            • Dynamic Keys - Filter and search in real-time
            • Real-time Sync - Changes sync across all devices instantly
            """)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        }
        #elseif !os(watchOS)
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
        #endif
        
        Section("Data Sync") {
          #if os(macOS)
          Button {
            if let url = URL(string: "https://www.instantdb.com/dash?s=main&app=b9319949-2f2d-410b-8f8a-6990177c1d44&t=explorer") {
              NSWorkspace.shared.open(url)
            }
          } label: {
            demoLabel("Open Dashboard", icon: "globe", description: "View data in InstantDB Explorer")
          }
          .buttonStyle(.plain)
          #endif
          
          NavigationLink {
            CaseStudyView {
              SwiftUISyncDemo()
            }
          } label: {
            demoLabel("Sync Demo", icon: "arrow.triangle.2.circlepath", description: "Bidirectional sync with optimistic updates")
          }
          
          NavigationLink {
            CaseStudyView {
              AdvancedTodoDemo()
            }
          } label: {
            demoLabel("Advanced Todo", icon: "checklist", description: "Search, sort, and filter todos")
          }
          
          NavigationLink {
            CaseStudyView {
              ObservableModelDemo()
            }
          } label: {
            demoLabel("Observable Model", icon: "cube", description: "Use @Shared with @Observable models")
          }
        }
        
        Section("Presence") {
          #if !os(watchOS)
          // Cursors demo doesn't make sense on watchOS (no cursor)
          NavigationLink {
            CaseStudyView {
              CursorsDemo()
            }
          } label: {
            demoLabel("Cursors", icon: "cursorarrow.rays", description: "Real-time cursor tracking across users")
          }
          #endif
          
          NavigationLink {
            CaseStudyView {
              TypingIndicatorDemo()
            }
          } label: {
            demoLabel("Typing Indicators", icon: "text.bubble", description: "Show when other users are typing")
          }
          
          NavigationLink {
            CaseStudyView {
              AvatarStackDemo()
            }
          } label: {
            demoLabel("Avatar Stack", icon: "person.2.circle", description: "Show who's currently in a room")
          }
          
          NavigationLink {
            CaseStudyView {
              TopicsDemo()
            }
          } label: {
            #if os(watchOS)
            demoLabel("Emoji Reactions", icon: "antenna.radiowaves.left.and.right", description: "Ephemeral broadcast events")
            #else
            demoLabel("Topics (Emoji Reactions)", icon: "antenna.radiowaves.left.and.right", description: "Ephemeral broadcast events")
            #endif
          }
          
          NavigationLink {
            CaseStudyView {
              TileGameDemo()
            }
          } label: {
            demoLabel("Tile Game", icon: "square.grid.3x3.fill", description: "Collaborative game with presence + sync")
          }
        }
        
        Section("Auth") {
          NavigationLink {
            CaseStudyView {
              AuthDemo()
            }
          } label: {
            demoLabel("Auth Flow", icon: "person.badge.key", description: "Guest, magic code, and Apple sign-in")
          }
        }
        
        #if !os(watchOS)
        // SSL Debug is too complex for watchOS
        Section("Diagnostics") {
          NavigationLink {
            SSLDebugView()
          } label: {
            demoLabel("SSL Debug", icon: "lock.shield", description: "Diagnose SSL/TLS and Zscaler issues")
          }
        }
        #endif 
      }
      #if os(iOS)
      .listStyle(.insetGrouped)
      #endif
      .navigationTitle("Case Studies")
    }
  }
  
  @ViewBuilder
  private func demoLabel(_ title: String, icon: String, description: String) -> some View {
    #if os(watchOS)
    Label(title, systemImage: icon)
    #else
    VStack(alignment: .leading, spacing: 4) {
      Label(title, systemImage: icon)
      Text(description)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    #endif
  }
}

#Preview {
  ContentView()
}
