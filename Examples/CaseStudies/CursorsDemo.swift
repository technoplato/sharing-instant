import Sharing
import SharingInstant
import SwiftUI

/// Demonstrates real-time cursor tracking using InstantDB presence.
///
/// This example shows how to track and display live cursor positions
/// from all users in a room using the type-safe presence API.
///
/// ## Declarative API
///
/// This demo uses `@Shared(.instantPresence(...))` with cursor position
/// updates via `$presence.withLock { $0.user.cursorX = x }`.
struct CursorsDemo: SwiftUICaseStudy {
  var caseStudyTitle: String { "Cursors" }
  
  var readMe: String {
    """
    This demo shows real-time cursor tracking using InstantDB presence.
    
    **Features:**
    • Track cursor positions across multiple users
    • Uses `@Shared(.instantPresence(...))` for declarative presence
    • Updates via `$presence.withLock { $0.user.cursorX = x }`
    
    Open this demo in multiple windows or devices to see cursors from other users!
    """
  }
  
  private let userId = String(UUID().uuidString.prefix(4))
  private let userColor = Color.random
  
  /// Type-safe presence subscription with cursor data.
  @Shared(.instantPresence(
    Schema.Rooms.cursors,
    roomId: "demo-123",
    initialPresence: CursorsPresence(name: "", color: "", cursorX: 0, cursorY: 0)
  ))
  private var presence: RoomPresence<CursorsPresence>
  
  /// Track previous peer count for logging
  @State private var previousPeerCount: Int = 0
  
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        // Background content
        VStack(spacing: 20) {
          Text("Move your cursor around!")
            .font(.title2)
            .foregroundStyle(.secondary)
          
          Text("Open this demo in multiple windows or devices to see cursors from other users.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
          
          Image(systemName: "cursorarrow.rays")
            .font(.system(size: 60))
            .foregroundStyle(.blue.opacity(0.3))
          
          if presence.isLoading {
            ProgressView("Connecting...")
              .font(.caption)
          } else {
            Text("\(presence.totalCount) cursor\(presence.totalCount == 1 ? "" : "s") in room")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        
        // Render peer cursors
        ForEach(presence.peers) { peer in
          CursorView(
            name: peer.data.name.isEmpty ? String(peer.id.prefix(4)) : peer.data.name,
            color: Color(hex: peer.data.color) ?? .gray
          )
          .position(x: peer.data.cursorX, y: peer.data.cursorY)
        }
      }
      #if os(iOS) || os(visionOS)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            updateCursorPosition(value.location, in: geometry.size)
          }
      )
      #endif
      #if os(macOS)
      .trackingMouse { location in
        updateCursorPosition(location, in: geometry.size)
      }
      #endif
    }
    .onAppear {
      InstantLogger.viewAppeared("CursorsDemo")
      InstantLogger.info("Joining cursors room", json: ["userId": userId, "roomId": "demo-123"])
      
      // Set initial presence with actual values
      $presence.withLock { state in
        state.user = CursorsPresence(
          name: userId,
          color: userColor.hexString,
          cursorX: 0,
          cursorY: 0
        )
      }
    }
    .onDisappear {
      InstantLogger.viewDisappeared("CursorsDemo")
    }
    .onChange(of: presence.peers.count) { oldCount, newCount in
      if newCount != previousPeerCount {
        InstantLogger.presenceUpdate(
          newCount > previousPeerCount ? "Peer joined" : "Peer left",
          peerCount: newCount,
          details: ["previousCount": previousPeerCount]
        )
        previousPeerCount = newCount
      }
    }
    .onChange(of: presence.isLoading) { _, isLoading in
      if !isLoading {
        InstantLogger.info("Presence connected", json: ["peerCount": presence.peers.count])
        previousPeerCount = presence.peers.count
      }
    }
  }
  
  private func updateCursorPosition(_ position: CGPoint, in size: CGSize) {
    $presence.withLock { state in
      state.user.cursorX = position.x
      state.user.cursorY = position.y
    }
  }
}

// MARK: - Cursor View

struct CursorView: View {
  let name: String
  let color: Color
  
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Cursor arrow
      Image(systemName: "cursorarrow")
        .font(.system(size: 20))
        .foregroundColor(color)
        .shadow(color: .black.opacity(0.3), radius: 1, x: 1, y: 1)
      
      // Name label
      Text(name)
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.9))
        .foregroundColor(.white)
        .cornerRadius(4)
        .offset(x: 10, y: -5)
    }
  }
}

// MARK: - macOS Mouse Tracking

#if os(macOS)
import AppKit

extension View {
  /// Tracks mouse movement within the view.
  func trackingMouse(onMove: @escaping (CGPoint) -> Void) -> some View {
    self.overlay(
      MouseTrackingView(onMove: onMove)
    )
  }
}

struct MouseTrackingView: NSViewRepresentable {
  let onMove: (CGPoint) -> Void
  
  func makeNSView(context: Context) -> NSView {
    let view = TrackingNSView()
    view.onMove = onMove
    return view
  }
  
  func updateNSView(_ nsView: NSView, context: Context) {
    if let trackingView = nsView as? TrackingNSView {
      trackingView.onMove = onMove
    }
  }
}

class TrackingNSView: NSView {
  var onMove: ((CGPoint) -> Void)?
  private var trackingArea: NSTrackingArea?
  
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    
    if let existing = trackingArea {
      removeTrackingArea(existing)
    }
    
    trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    
    if let area = trackingArea {
      addTrackingArea(area)
    }
  }
  
  override func mouseMoved(with event: NSEvent) {
    let location = convert(event.locationInWindow, from: nil)
    // Flip Y coordinate since NSView uses bottom-left origin
    let flippedLocation = CGPoint(x: location.x, y: bounds.height - location.y)
    onMove?(flippedLocation)
  }
}
#endif

#Preview {
  CursorsDemo()
}
