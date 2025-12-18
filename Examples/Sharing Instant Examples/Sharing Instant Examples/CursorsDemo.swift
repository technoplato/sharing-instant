import SharingInstant
import SwiftUI

/// Demonstrates real-time cursor tracking using InstantDB presence.
///
/// This example shows how to use `CursorsView` to display live cursor
/// positions from all users in a room.
struct CursorsDemo: View, SwiftUICaseStudy {
  var caseStudyTitle: String { "Cursors" }
  var readMe: String {
    """
    This demo shows real-time cursor tracking using InstantDB presence.
    
    CursorsView automatically tracks mouse/touch positions and broadcasts them \
    to all users in the same room. Each user sees other users' cursors with \
    their assigned colors.
    
    Try opening this demo in multiple windows or devices to see cursors from \
    other users appear in real-time.
    """
  }
  
  let room = InstantRoom(type: "cursors", id: "demo-123")
  
  private var backgroundColor: Color {
    #if os(iOS)
    return Color(uiColor: .systemBackground)
    #elseif os(macOS)
    return Color(nsColor: .windowBackgroundColor)
    #else
    return Color.black
    #endif
  }
  
  var body: some View {
    CursorsView(room: room, userColor: .random) {
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
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(backgroundColor)
    }
  }
}

#Preview {
  CursorsDemo()
}


