import InstantDB
import SharingInstant
import SwiftUI

/// Demonstrates authentication flows using InstantDB.
///
/// This example shows how to use `InstantAuth` for:
/// - Guest sign-in
/// - Magic code (email) authentication
/// - Sign out
struct AuthDemo: View, SwiftUICaseStudy {
  var caseStudyTitle: String { "Authentication" }
  var readMe: String {
    """
    This demo shows authentication flows using InstantDB.
    
    InstantAuth supports multiple authentication methods:
    • Guest sign-in - Quick anonymous access
    • Magic code - Email-based passwordless authentication
    • Sign in with Apple - Native Apple authentication
    
    Guest accounts are temporary. Sign in with email or Apple to persist your data.
    """
  }
  
  @StateObject private var auth = InstantAuth()
  
  var body: some View {
    VStack(spacing: 20) {
      switch auth.state {
      case .loading:
        ProgressView("Loading...")
        
      case .unauthenticated:
        UnauthenticatedView(auth: auth)
        
      case .guest(let user):
        AuthenticatedView(
          user: user,
          isGuest: true,
          auth: auth
        )
        
      case .authenticated(let user):
        AuthenticatedView(
          user: user,
          isGuest: false,
          auth: auth
        )
      }
    }
    .padding()
    .animation(.easeInOut, value: auth.state)
  }
}

// MARK: - Unauthenticated View

struct UnauthenticatedView: View {
  @ObservedObject var auth: InstantAuth
  
  @State private var showMagicCode = false
  @State private var isLoading = false
  @State private var error: String?
  
  var body: some View {
    VStack(spacing: watchOS ? 12 : 24) {
      Image(systemName: "person.circle")
        .font(.system(size: watchOS ? 40 : 80))
        .foregroundStyle(.secondary)
      
      Text("Welcome!")
        .font(watchOS ? .headline : .title)
        .fontWeight(.bold)
      
      #if !os(watchOS)
      Text("Choose how to sign in")
        .foregroundStyle(.secondary)
      #endif
      
      VStack(spacing: 12) {
        // Guest sign-in
        Button {
          signInAsGuest()
        } label: {
          #if os(watchOS)
          Label("Guest", systemImage: "person.fill.questionmark")
          #else
          Label("Continue as Guest", systemImage: "person.fill.questionmark")
            .frame(maxWidth: .infinity)
          #endif
        }
        .buttonStyle(.bordered)
        .disabled(isLoading)
        
        // Magic code sign-in
        Button {
          showMagicCode = true
        } label: {
          #if os(watchOS)
          Label("Email", systemImage: "envelope.fill")
          #else
          Label("Sign in with Email", systemImage: "envelope.fill")
            .frame(maxWidth: .infinity)
          #endif
        }
        .buttonStyle(.borderedProminent)
        .disabled(isLoading)
        
        #if canImport(AuthenticationServices) && !os(watchOS)
        // Apple sign-in (when available)
        InstantSignInWithAppleButton(auth: auth) { result in
          switch result {
          case .success:
            break
          case .failure(let error):
            self.error = error.localizedDescription
          }
        }
        .frame(height: 44)
        #endif
      }
      #if !os(watchOS)
      .frame(maxWidth: 280)
      #endif
      
      if let error = error {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .sheet(isPresented: $showMagicCode) {
      MagicCodeSheet(auth: auth, isPresented: $showMagicCode)
    }
  }
  
  private var watchOS: Bool {
    #if os(watchOS)
    return true
    #else
    return false
    #endif
  }
  
  private func signInAsGuest() {
    isLoading = true
    error = nil
    
    Task {
      do {
        _ = try await auth.signInAsGuest()
      } catch {
        self.error = error.localizedDescription
      }
      isLoading = false
    }
  }
}

// MARK: - Magic Code Sheet

struct MagicCodeSheet: View {
  @ObservedObject var auth: InstantAuth
  @Binding var isPresented: Bool
  
  var body: some View {
    NavigationStack {
      MagicCodeView(auth: auth) { result in
        switch result {
        case .success:
          isPresented = false
        case .failure:
          break // Error is shown in the MagicCodeView
        }
      }
      .padding()
      .navigationTitle("Sign In")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            isPresented = false
          }
        }
      }
    }
    #if os(iOS)
    .presentationDetents([.medium])
    #endif
  }
}

// MARK: - Authenticated View

struct AuthenticatedView: View {
  let user: User
  let isGuest: Bool
  @ObservedObject var auth: InstantAuth
  
  @State private var isSigningOut = false
  @State private var error: String?
  
  private var watchOS: Bool {
    #if os(watchOS)
    return true
    #else
    return false
    #endif
  }
  
  var body: some View {
    #if os(watchOS)
    ScrollView {
      watchOSContent
    }
    #else
    regularContent
    #endif
  }
  
  private var watchOSContent: some View {
    VStack(spacing: 12) {
      // Compact avatar
      ZStack {
        Circle()
          .fill(Color.blue.gradient)
          .frame(width: 50, height: 50)
        
        if let email = user.email, let first = email.first {
          Text(String(first).uppercased())
            .font(.title3)
            .fontWeight(.bold)
            .foregroundStyle(.white)
        } else {
          Image(systemName: "person.fill")
            .font(.title3)
            .foregroundStyle(.white)
        }
      }
      
      VStack(spacing: 2) {
        Text(user.email ?? "Guest")
          .font(.caption)
          .fontWeight(.semibold)
          .lineLimit(1)
        
        if isGuest {
          Text("Guest")
            .font(.caption2)
            .foregroundStyle(.orange)
        } else {
          Text("Signed In")
            .font(.caption2)
            .foregroundStyle(.green)
        }
      }
      
      // Sign out button
      Button(role: .destructive) {
        signOut()
      } label: {
        if isSigningOut {
          ProgressView()
        } else {
          Text("Sign Out")
        }
      }
      .buttonStyle(.bordered)
      .disabled(isSigningOut)
    }
    .padding(8)
  }
  
  private var regularContent: some View {
    VStack(spacing: 24) {
      // Avatar
      ZStack {
        Circle()
          .fill(Color.blue.gradient)
          .frame(width: 100, height: 100)
        
        if let email = user.email, let first = email.first {
          Text(String(first).uppercased())
            .font(.largeTitle)
            .fontWeight(.bold)
            .foregroundStyle(.white)
        } else {
          Image(systemName: "person.fill")
            .font(.largeTitle)
            .foregroundStyle(.white)
        }
      }
      
      VStack(spacing: 4) {
        Text(user.email ?? "Guest User")
          .font(.title2)
          .fontWeight(.semibold)
        
        if isGuest {
          Label("Guest Account", systemImage: "person.fill.questionmark")
            .font(.caption)
            .foregroundStyle(.orange)
        } else {
          Label("Authenticated", systemImage: "checkmark.seal.fill")
            .font(.caption)
            .foregroundStyle(.green)
        }
      }
      
      // User ID
      VStack(alignment: .leading, spacing: 4) {
        Text("User ID")
          .font(.caption)
          .foregroundStyle(.secondary)
        
        Text(user.id)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8)
          #if os(iOS)
          .fill(Color(uiColor: .secondarySystemBackground))
          #elseif os(macOS)
          .fill(Color(nsColor: .controlBackgroundColor))
          #else
          .fill(Color.gray.opacity(0.2))
          #endif
      )
      
      if isGuest {
        Text("Guest accounts are temporary. Sign in with email to save your data permanently.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      
      Spacer()
      
      // Sign out button
      Button(role: .destructive) {
        signOut()
      } label: {
        if isSigningOut {
          ProgressView()
            .frame(maxWidth: .infinity)
        } else {
          Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.bordered)
      .disabled(isSigningOut)
      
      if let error = error {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding()
  }
  
  private func signOut() {
    isSigningOut = true
    error = nil
    
    Task {
      do {
        try await auth.signOut()
      } catch {
        self.error = error.localizedDescription
      }
      isSigningOut = false
    }
  }
}

#Preview {
  AuthDemo()
}


