import SharingInstant
import SwiftUI

/// Demonstrates real-time cursor tracking using InstantDB presence.
///
/// This example shows how to use `CursorsView` to display live cursor
/// positions from all users in a room.
struct CursorsDemo: View {
  let room = InstantRoom(type: "cursors", id: "demo-123")
  
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
      .background(Color(.systemBackground))
    }
  }
}

#Preview {
  CursorsDemo()
}

