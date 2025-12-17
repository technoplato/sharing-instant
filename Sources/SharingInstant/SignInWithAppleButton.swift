#if canImport(SwiftUI) && canImport(AuthenticationServices)
import AuthenticationServices
import InstantDB
import SwiftUI

// MARK: - InstantSignInWithAppleButton

/// A Sign in with Apple button that integrates with InstantDB authentication.
///
/// This component wraps the standard `SignInWithAppleButton` and handles the
/// entire authentication flow, including exchanging the Apple ID token with
/// InstantDB.
///
/// ## Basic Usage
///
/// ```swift
/// InstantSignInWithAppleButton { result in
///   switch result {
///   case .success(let user):
///     print("Signed in as: \(user.email ?? "unknown")")
///   case .failure(let error):
///     print("Sign in failed: \(error)")
///   }
/// }
/// ```
///
/// ## With Custom Styling
///
/// ```swift
/// InstantSignInWithAppleButton(
///   type: .continue,
///   style: .whiteOutline
/// ) { result in
///   // Handle result
/// }
/// ```
///
/// ## Using InstantAuth
///
/// If you have an `InstantAuth` instance, you can use it directly:
///
/// ```swift
/// InstantSignInWithAppleButton(auth: auth) { result in
///   // Handle result
/// }
/// ```
@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *)
public struct InstantSignInWithAppleButton: View {
  let type: SignInWithAppleButton.Label
  let style: SignInWithAppleButton.Style
  let auth: InstantAuth?
  let appID: String?
  let onCompletion: (Result<User, Error>) -> Void
  
  @State private var isLoading = false
  
  /// Creates a Sign in with Apple button.
  ///
  /// - Parameters:
  ///   - type: The button label type (default: `.signIn`)
  ///   - style: The button style (default: `.black`)
  ///   - appID: Optional app ID. Uses the default if not specified.
  ///   - onCompletion: Called when sign-in completes or fails
  public init(
    type: SignInWithAppleButton.Label = .signIn,
    style: SignInWithAppleButton.Style = .black,
    appID: String? = nil,
    onCompletion: @escaping (Result<User, Error>) -> Void
  ) {
    self.type = type
    self.style = style
    self.auth = nil
    self.appID = appID
    self.onCompletion = onCompletion
  }
  
  /// Creates a Sign in with Apple button using an existing InstantAuth.
  ///
  /// - Parameters:
  ///   - type: The button label type (default: `.signIn`)
  ///   - style: The button style (default: `.black`)
  ///   - auth: The InstantAuth coordinator to use
  ///   - onCompletion: Called when sign-in completes or fails
  public init(
    type: SignInWithAppleButton.Label = .signIn,
    style: SignInWithAppleButton.Style = .black,
    auth: InstantAuth,
    onCompletion: @escaping (Result<User, Error>) -> Void
  ) {
    self.type = type
    self.style = style
    self.auth = auth
    self.appID = nil
    self.onCompletion = onCompletion
  }
  
  public var body: some View {
    SignInWithAppleButton(type) { request in
      request.requestedScopes = [.email, .fullName]
    } onCompletion: { result in
      handleAppleSignIn(result)
    }
    .signInWithAppleButtonStyle(style)
    .disabled(isLoading)
    .overlay {
      if isLoading {
        ProgressView()
      }
    }
  }
  
  private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
    switch result {
    case .success(let authorization):
      guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let identityTokenData = appleIDCredential.identityToken,
            let identityToken = String(data: identityTokenData, encoding: .utf8) else {
        onCompletion(.failure(InstantError.invalidMessage))
        return
      }
      
      // Get the nonce if available (for additional security)
      let nonce: String? = nil // Apple doesn't provide nonce in this flow
      
      isLoading = true
      
      Task { @MainActor in
        do {
          let user: User
          
          if let auth = auth {
            // Use provided InstantAuth
            user = try await auth.signInWithIdToken(
              clientName: "apple",
              idToken: identityToken,
              nonce: nonce
            )
          } else {
            // Create a new client
            let client = InstantClientFactory.makeClient(appID: appID ?? "")
            user = try await client.authManager.signInWithIdToken(
              clientName: "apple",
              idToken: identityToken,
              nonce: nonce
            )
          }
          
          isLoading = false
          onCompletion(.success(user))
        } catch {
          isLoading = false
          onCompletion(.failure(error))
        }
      }
      
    case .failure(let error):
      onCompletion(.failure(error))
    }
  }
}

// MARK: - Preview

#if DEBUG
@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *)
struct InstantSignInWithAppleButton_Previews: PreviewProvider {
  static var previews: some View {
    VStack(spacing: 20) {
      InstantSignInWithAppleButton { _ in }
        .frame(height: 50)
      
      InstantSignInWithAppleButton(style: .white) { _ in }
        .frame(height: 50)
      
      InstantSignInWithAppleButton(type: .continue, style: .whiteOutline) { _ in }
        .frame(height: 50)
    }
    .padding()
  }
}
#endif
#endif

