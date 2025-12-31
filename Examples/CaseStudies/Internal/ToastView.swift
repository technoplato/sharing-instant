import SwiftUI

// MARK: - Toast Model

enum ToastType {
  case success
  case error
  case info
  
  var icon: String {
    switch self {
    case .success: return "checkmark.circle.fill"
    case .error: return "xmark.circle.fill"
    case .info: return "info.circle.fill"
    }
  }
  
  var color: Color {
    switch self {
    case .success: return .green
    case .error: return .red
    case .info: return .blue
    }
  }
}

struct Toast: Equatable, Identifiable {
  let id = UUID()
  let type: ToastType
  let message: String
  
  static func == (lhs: Toast, rhs: Toast) -> Bool {
    lhs.id == rhs.id
  }
}

// MARK: - Toast View

struct ToastView: View {
  let toast: Toast
  
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: toast.type.icon)
        .foregroundStyle(toast.type.color)
      Text(toast.message)
        .font(.subheadline)
        .foregroundStyle(.primary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(.ultraThinMaterial)
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    )
  }
}

// MARK: - Toast Modifier

struct ToastModifier: ViewModifier {
  @Binding var toast: Toast?
  
  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if let toast {
          ToastView(toast: toast)
            .padding(.bottom, 60)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
              DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeOut(duration: 0.3)) {
                  self.toast = nil
                }
              }
            }
        }
      }
      .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toast)
  }
}

extension View {
  func toast(_ toast: Binding<Toast?>) -> some View {
    modifier(ToastModifier(toast: toast))
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 20) {
    ToastView(toast: Toast(type: .success, message: "Todo created!"))
    ToastView(toast: Toast(type: .error, message: "Failed to save"))
    ToastView(toast: Toast(type: .info, message: "Syncing..."))
  }
  .padding()
}
