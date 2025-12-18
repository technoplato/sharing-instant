//
//  ConnectionStatusView.swift
//  Sharing Instant Examples
//
//  Shows the current connection status of the InstantDB client.
//  Useful for debugging connection issues (especially SSL/TLS failures
//  caused by corporate VPNs like Zscaler).
//

import InstantDB
import SwiftUI

// MARK: - ConnectionStatusView

/// A view that displays the current InstantDB connection status.
///
/// ## Why This Exists
/// When debugging connection issues (especially SSL/TLS failures from corporate
/// VPNs), it's helpful to see the connection state in the UI. This view shows:
/// - Current connection state (disconnected, connecting, connected, authenticated, error)
/// - Session ID (when connected)
/// - Error details (when in error state)
/// - Manual connect/disconnect controls
///
/// ## Usage
/// Add this view to your app's main screen or settings page:
/// ```swift
/// ConnectionStatusView(client: myInstantClient)
/// ```
struct ConnectionStatusView: View {
  @ObservedObject var client: InstantClient
  @State private var isExpanded = false
  @State private var logs: [String] = []
  
  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 12) {
        statusDetails
        
        if !logs.isEmpty {
          logSection
        }
        
        actionButtons
      }
      .padding(.vertical, 8)
    } label: {
      HStack(spacing: 12) {
        statusEmoji
          .font(.title2)
        
        VStack(alignment: .leading, spacing: 2) {
          Text(statusText)
            .font(.headline)
          
          if let sessionID = client.sessionID {
            Text("Session: \(sessionID.prefix(8))...")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }
        
        Spacer()
      }
    }
    .onChange(of: client.connectionState) { _, newState in
      addLog("Connection: \(newState)")
    }
    .onAppear {
      addLog("View appeared, state: \(client.connectionState)")
    }
  }
  
  // MARK: - Status Display
  
  private var statusEmoji: Text {
    switch client.connectionState {
    case .disconnected:
      return Text("⚫️")
    case .connecting:
      return Text("🟡")
    case .connected:
      return Text("🟢")
    case .authenticated:
      return Text("✅")
    case .error:
      return Text("🔴")
    }
  }
  
  private var statusText: String {
    switch client.connectionState {
    case .disconnected:
      return "Disconnected"
    case .connecting:
      return "Connecting..."
    case .connected:
      return "Connected"
    case .authenticated:
      return "Authenticated"
    case .error(let error):
      if error.isSSLTrustFailure {
        return "SSL/TLS Error"
      }
      return "Error"
    }
  }
  
  private var statusDetails: some View {
    VStack(alignment: .leading, spacing: 8) {
      if case .error(let error) = client.connectionState {
        errorDetails(error)
      }
      
      HStack {
        Label("\(client.attributes.count) attributes", systemImage: "doc.text")
        Spacer()
        Label(client.isAuthenticated ? "Signed in" : "Guest", systemImage: "person.circle")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
  
  @ViewBuilder
  private func errorDetails(_ error: InstantError) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(error.localizedDescription ?? "Unknown error")
        .font(.caption)
        .foregroundStyle(.red)
      
      if error.isSSLTrustFailure {
        sslTrustFailureGuidance
      }
      
      if let suggestion = error.recoverySuggestion {
        Text(suggestion)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(8)
    .background(Color.red.opacity(0.1))
    .cornerRadius(8)
  }
  
  private var sslTrustFailureGuidance: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("This is likely caused by a corporate VPN (Zscaler, Netskope, etc.)")
        .font(.caption)
        .bold()
      
      Text("Solutions:")
        .font(.caption2)
        .foregroundStyle(.secondary)
      
      VStack(alignment: .leading, spacing: 2) {
        Text("1. Disable VPN temporarily")
        Text("2. Add VPN's root certificate to simulator")
        Text("3. Ask IT to whitelist api.instantdb.com")
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }
  
  // MARK: - Logs
  
  private var logSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Recent Logs")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Clear") {
          logs.removeAll()
        }
        .font(.caption2)
      }
      
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(logs.suffix(10), id: \.self) { log in
            Text(log)
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: 100)
      .padding(8)
      .background(Color.gray.opacity(0.1))
      .cornerRadius(6)
    }
  }
  
  // MARK: - Actions
  
  private var actionButtons: some View {
    HStack(spacing: 12) {
      Button {
        addLog("Manual connect requested")
        client.connect()
      } label: {
        Label("Connect", systemImage: "play.circle.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .tint(.green)
      .disabled(client.connectionState == .authenticated || client.connectionState == .connecting)
      
      Button {
        addLog("Manual disconnect requested")
        client.disconnect()
      } label: {
        Label("Disconnect", systemImage: "stop.circle.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .tint(.red)
      .disabled(client.connectionState == .disconnected)
    }
  }
  
  // MARK: - Helpers
  
  private func addLog(_ message: String) {
    let timestamp = Date().formatted(date: .omitted, time: .standard)
    logs.append("[\(timestamp)] \(message)")
  }
}

// MARK: - Preview

#Preview {
  List {
    // This preview won't work without a real client,
    // but shows the structure
    Text("ConnectionStatusView requires an InstantClient")
  }
}

