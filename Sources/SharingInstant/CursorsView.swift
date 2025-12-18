#if canImport(SwiftUI)
import SwiftUI
import InstantDB

// MARK: - CursorsView

/// A SwiftUI view that displays real-time cursors for all users in a room.
///
/// This view overlays cursor indicators on top of your content, showing where
/// other users are pointing or interacting.
///
/// ## Basic Usage
///
/// ```swift
/// CursorsView(room: room) {
///   // Your content here
///   Text("Move your cursor around!")
/// }
/// ```
///
/// ## Custom Cursor Rendering
///
/// ```swift
/// CursorsView(room: room) {
///   MyContent()
/// } cursor: { peer in
///   CustomCursor(name: peer.name, color: peer.color)
/// }
/// ```
///
/// ## With User Color
///
/// ```swift
/// CursorsView(room: room, userColor: .blue) {
///   MyContent()
/// }
/// ```
///
/// - Note: This component automatically syncs cursor positions using presence.
public struct CursorsView<Content: View, CursorContent: View>: View {
  let room: InstantRoom
  let userColor: Color
  let content: Content
  let cursorContent: ((CursorPeer) -> CursorContent)?
  
  @State private var presenceState = InstantPresenceState()
  @State private var unsubscribe: (() -> Void)?
  @State private var myPosition: CGPoint = .zero
  
  /// Creates a cursors view with default cursor rendering.
  ///
  /// - Parameters:
  ///   - room: The room to sync cursors in
  ///   - userColor: Your cursor color (default: random)
  ///   - content: The content to overlay cursors on
  public init(
    room: InstantRoom,
    userColor: Color = .random,
    @ViewBuilder content: () -> Content
  ) where CursorContent == DefaultCursor {
    self.room = room
    self.userColor = userColor
    self.content = content()
    self.cursorContent = nil
  }
  
  /// Creates a cursors view with custom cursor rendering.
  ///
  /// - Parameters:
  ///   - room: The room to sync cursors in
  ///   - userColor: Your cursor color
  ///   - content: The content to overlay cursors on
  ///   - cursor: A view builder for custom cursor rendering
  public init(
    room: InstantRoom,
    userColor: Color = .random,
    @ViewBuilder content: () -> Content,
    @ViewBuilder cursor: @escaping (CursorPeer) -> CursorContent
  ) {
    self.room = room
    self.userColor = userColor
    self.content = content()
    self.cursorContent = cursor
  }
  
  public var body: some View {
    GeometryReader { geometry in
      ZStack {
        content
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          #if os(iOS) || os(visionOS)
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { value in
                updateCursorPosition(value.location, in: geometry.size)
              }
          )
          #endif
        
        // Render peer cursors
        ForEach(peerCursors) { peer in
          if let cursorContent = cursorContent {
            cursorContent(peer)
              .position(peer.position)
          } else {
            DefaultCursor(peer: peer)
              .position(peer.position)
          }
        }
      }
      #if os(macOS)
      .trackingMouse { location in
        updateCursorPosition(location, in: geometry.size)
      }
      #endif
    }
    .task {
      await subscribeToPresence()
    }
    .onDisappear {
      unsubscribe?()
    }
  }
  
  private var peerCursors: [CursorPeer] {
    presenceState.peersList.compactMap { peer in
      guard let cursor = peer.data["cursor"]?.value as? [String: Any],
            let x = cursor["x"] as? Double,
            let y = cursor["y"] as? Double else {
        return nil
      }
      
      return CursorPeer(
        id: peer.id,
        position: CGPoint(x: x, y: y),
        name: peer.name,
        color: peer.color.flatMap { Color(hex: $0) } ?? .gray
      )
    }
  }
  
  @MainActor
  private func subscribeToPresence() async {
    let client = InstantClientFactory.makeClient(appID: room.appID)
    
    // Wait for connection
    while client.connectionState != .authenticated {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    
    // Sync initial presence with color
    _ = client.presence.joinRoom(room.roomId, initialPresence: [
      "color": userColor.hexString,
      "cursor": ["x": 0, "y": 0]
    ])
    
    // Subscribe to presence updates
    unsubscribe = client.presence.subscribePresence(roomId: room.roomId) { slice in
      presenceState = InstantPresenceState(from: slice)
    }
  }
  
  @MainActor
  private func updateCursorPosition(_ position: CGPoint, in size: CGSize) {
    myPosition = position
    
    let client = InstantClientFactory.makeClient(appID: room.appID)
    client.presence.publishPresence(roomId: room.roomId, data: [
      "cursor": ["x": position.x, "y": position.y]
    ])
  }
}

// MARK: - CursorPeer

/// Represents a peer's cursor in the room.
public struct CursorPeer: Identifiable {
  /// The peer's session ID
  public let id: String
  
  /// The cursor position
  public let position: CGPoint
  
  /// The peer's display name
  public let name: String?
  
  /// The peer's cursor color
  public let color: Color
}

// MARK: - DefaultCursor

/// The default cursor view rendered for each peer.
public struct DefaultCursor: View {
  let peer: CursorPeer
  
  public init(peer: CursorPeer) {
    self.peer = peer
  }
  
  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Cursor arrow
      Image(systemName: "cursorarrow")
        .font(.system(size: 20))
        .foregroundColor(peer.color)
        .shadow(color: .black.opacity(0.3), radius: 1, x: 1, y: 1)
      
      // Name label
      if let name = peer.name {
        Text(name)
          .font(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(peer.color.opacity(0.9))
          .foregroundColor(.white)
          .cornerRadius(4)
          .offset(x: 10, y: -5)
      }
    }
  }
}

// MARK: - Color Extensions

public extension Color {
  /// Creates a color from a hex string.
  init?(hex: String) {
    var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
    
    var rgb: UInt64 = 0
    guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
      return nil
    }
    
    let r = Double((rgb & 0xFF0000) >> 16) / 255.0
    let g = Double((rgb & 0x00FF00) >> 8) / 255.0
    let b = Double(rgb & 0x0000FF) / 255.0
    
    self.init(red: r, green: g, blue: b)
  }
  
  /// Returns a hex string representation of the color.
  var hexString: String {
    #if canImport(UIKit) && !os(watchOS)
    guard let components = UIColor(self).cgColor.components, components.count >= 3 else {
      return "#808080"
    }
    let r = Int(components[0] * 255)
    let g = Int(components[1] * 255)
    let b = Int(components[2] * 255)
    return String(format: "#%02X%02X%02X", r, g, b)
    #elseif os(watchOS)
    // watchOS: Use a simpler approach - generate a consistent hash-based color
    // Since we can't easily extract RGB components on watchOS
    return "#808080"
    #elseif canImport(AppKit)
    guard let color = NSColor(self).usingColorSpace(.sRGB),
          let components = color.cgColor.components, components.count >= 3 else {
      return "#808080"
    }
    let r = Int(components[0] * 255)
    let g = Int(components[1] * 255)
    let b = Int(components[2] * 255)
    return String(format: "#%02X%02X%02X", r, g, b)
    #else
    return "#808080"
    #endif
  }
  
  /// A random dark color suitable for cursors.
  static var random: Color {
    Color(
      red: Double.random(in: 0...0.7),
      green: Double.random(in: 0...0.7),
      blue: Double.random(in: 0...0.7)
    )
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

#endif

