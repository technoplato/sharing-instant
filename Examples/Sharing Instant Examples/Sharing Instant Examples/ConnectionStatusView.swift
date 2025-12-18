//
//  ConnectionStatusView.swift
//  Sharing Instant Examples
//
//  Shows the current connection status of the InstantDB client.
//  Useful for debugging connection issues (especially SSL/TLS failures
//  caused by corporate VPNs like Zscaler).
//

import Sharing
import SharingInstant
import SwiftUI

// MARK: - ConnectionStatusView

/// A view that displays the current InstantDB connection status.
///
/// ## Why This Exists
/// When debugging connection issues (especially SSL/TLS failures from corporate
/// VPNs), it's helpful to see the connection state in the UI. This view shows:
/// - Current connection state with emoji indicator
/// - Session info when authenticated (user, schema)
/// - Error details with SSL-specific guidance
///
/// Logs are automatically synced to InstantDB via `InstantLogger`.
///
/// ## Usage
///
/// ```swift
/// ConnectionStatusView()
/// ```
struct ConnectionStatusView: View {
  @SharedReader(.instantConnection) private var connection: InstantConnectionState
  
  @State private var isExpanded = false
  
  var body: some View {
    #if os(tvOS) || os(watchOS)
    // tvOS and watchOS don't support DisclosureGroup, show inline content
    VStack(alignment: .leading, spacing: 12) {
      statusHeader
      stateDetails
    }
    .onAppear {
      InstantLogger.viewAppeared("ConnectionStatusView")
    }
    #else
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 12) {
        stateDetails
      }
      .padding(.vertical, 8)
    } label: {
      statusHeader
    }
    .onAppear {
      InstantLogger.viewAppeared("ConnectionStatusView")
    }
    #endif
  }
  
  private var statusHeader: some View {
    HStack(spacing: 12) {
      Text(connection.statusEmoji)
        .font(.title2)
      
      VStack(alignment: .leading, spacing: 2) {
        Text(connection.statusText)
          .font(.headline)
        
        if case .authenticated(let session) = connection {
          if let email = session.user?.email {
            Text(email)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let sessionID = Optional(session.sessionID) {
            Text("Session: \(sessionID.prefix(8))...")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
      }
      
      Spacer()
    }
  }
  
  // MARK: - State Details
  
  @ViewBuilder
  private var stateDetails: some View {
    switch connection {
    case .disconnected:
      disconnectedDetails
      
    case .connecting:
      connectingDetails
      
    case .connected:
      connectedDetails
      
    case .authenticated(let session):
      authenticatedDetails(session)
      
    case .error(let error):
      errorDetails(error)
    }
  }
  
  private var disconnectedDetails: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Not connected to InstantDB")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("The app will connect automatically when needed.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }
  
  private var connectingDetails: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        ProgressView()
          .scaleEffect(0.8)
        Text("Establishing connection...")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text("This includes DNS, TCP, TLS handshake, and WebSocket upgrade.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }
  
  private var connectedDetails: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        ProgressView()
          .scaleEffect(0.8)
        Text("WebSocket open, authenticating...")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
  
  private func authenticatedDetails(_ session: InstantConnectionState.Session) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      // User info
      HStack {
        Image(systemName: session.isAuthenticated ? "person.fill.checkmark" : "person.fill")
          .foregroundStyle(session.isAuthenticated ? .green : .orange)
        
        if let user = session.user {
          if let email = user.email {
            Text(email)
              .font(.caption)
          } else {
            Text("Guest User (ID: \(user.id.prefix(8))...)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else {
          Text("No user")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      
      // Schema info
      HStack {
        Image(systemName: "doc.text")
          .foregroundStyle(session.isSchemaLoaded ? .blue : .gray)
        
        if session.isSchemaLoaded {
          Text("\(session.attributeCount) attributes loaded")
            .font(.caption)
        } else {
          Text("Schema not loaded")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
  
  private func errorDetails(_ error: InstantConnectionState.ConnectionError) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      // Error message
      Text(error.localizedDescription)
        .font(.caption)
        .foregroundStyle(.red)
      
      // SSL-specific guidance
      if error.isSSLError {
        sslErrorGuidance
      }
      
      // Recovery suggestion
      if let suggestion = error.recoverySuggestion {
        Text(suggestion)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      
      // Retry info
      Text("The SDK will automatically retry with exponential backoff.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .italic()
    }
    .padding(8)
    .background(Color.red.opacity(0.1))
    .cornerRadius(8)
  }
  
  private var sslErrorGuidance: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("This is likely caused by a corporate VPN")
        .font(.caption)
        .bold()
      
      Text("(Zscaler, Netskope, Cisco AnyConnect, etc.)")
        .font(.caption2)
        .foregroundStyle(.secondary)
      
      Divider()
      
      Text("Solutions:")
        .font(.caption2)
        .bold()
      
      VStack(alignment: .leading, spacing: 2) {
        Label("Disable VPN temporarily", systemImage: "1.circle")
        Label("Add VPN's root cert to simulator", systemImage: "2.circle")
        Label("Ask IT to whitelist api.instantdb.com", systemImage: "3.circle")
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      
      Divider()
      
      NavigationLink {
        SSLDebugView()
      } label: {
        Label("Run SSL Diagnostics", systemImage: "stethoscope")
          .font(.caption)
          .foregroundStyle(.blue)
      }
    }
  }
}

// MARK: - Preview

#Preview {
  List {
    Section("Connection Status") {
      ConnectionStatusView()
    }
  }
}
