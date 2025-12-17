#if canImport(SwiftUI)
import InstantDB
import SwiftUI

// MARK: - MagicCodeView

/// A complete magic code authentication flow view.
///
/// This view handles the entire email magic code authentication process,
/// including email entry, code verification, and error handling.
///
/// ## Basic Usage
///
/// ```swift
/// MagicCodeView { result in
///   switch result {
///   case .success(let user):
///     print("Signed in as: \(user.email ?? "unknown")")
///   case .failure(let error):
///     print("Sign in failed: \(error)")
///   }
/// }
/// ```
///
/// ## With InstantAuth
///
/// ```swift
/// MagicCodeView(auth: auth) { result in
///   // Handle result
/// }
/// ```
///
/// ## Custom Styling
///
/// ```swift
/// MagicCodeView(
///   emailPlaceholder: "Your email address",
///   codePlaceholder: "Enter code",
///   sendButtonTitle: "Get Code",
///   verifyButtonTitle: "Sign In"
/// ) { result in
///   // Handle result
/// }
/// ```
public struct MagicCodeView: View {
  let auth: InstantAuth?
  let appID: String?
  let emailPlaceholder: String
  let codePlaceholder: String
  let sendButtonTitle: String
  let verifyButtonTitle: String
  let onCompletion: (Result<User, Error>) -> Void
  
  @State private var email = ""
  @State private var code = ""
  @State private var sentEmail: String?
  @State private var isLoading = false
  @State private var error: String?
  
  /// Creates a magic code authentication view.
  ///
  /// - Parameters:
  ///   - appID: Optional app ID. Uses the default if not specified.
  ///   - emailPlaceholder: Placeholder text for email field
  ///   - codePlaceholder: Placeholder text for code field
  ///   - sendButtonTitle: Title for the send code button
  ///   - verifyButtonTitle: Title for the verify button
  ///   - onCompletion: Called when authentication completes or fails
  public init(
    appID: String? = nil,
    emailPlaceholder: String = "Enter your email",
    codePlaceholder: String = "Magic code",
    sendButtonTitle: String = "Send Code",
    verifyButtonTitle: String = "Verify",
    onCompletion: @escaping (Result<User, Error>) -> Void
  ) {
    self.auth = nil
    self.appID = appID
    self.emailPlaceholder = emailPlaceholder
    self.codePlaceholder = codePlaceholder
    self.sendButtonTitle = sendButtonTitle
    self.verifyButtonTitle = verifyButtonTitle
    self.onCompletion = onCompletion
  }
  
  /// Creates a magic code authentication view using an existing InstantAuth.
  ///
  /// - Parameters:
  ///   - auth: The InstantAuth coordinator to use
  ///   - emailPlaceholder: Placeholder text for email field
  ///   - codePlaceholder: Placeholder text for code field
  ///   - sendButtonTitle: Title for the send code button
  ///   - verifyButtonTitle: Title for the verify button
  ///   - onCompletion: Called when authentication completes or fails
  public init(
    auth: InstantAuth,
    emailPlaceholder: String = "Enter your email",
    codePlaceholder: String = "Magic code",
    sendButtonTitle: String = "Send Code",
    verifyButtonTitle: String = "Verify",
    onCompletion: @escaping (Result<User, Error>) -> Void
  ) {
    self.auth = auth
    self.appID = nil
    self.emailPlaceholder = emailPlaceholder
    self.codePlaceholder = codePlaceholder
    self.sendButtonTitle = sendButtonTitle
    self.verifyButtonTitle = verifyButtonTitle
    self.onCompletion = onCompletion
  }
  
  public var body: some View {
    VStack(spacing: 16) {
      if sentEmail == nil {
        emailEntryView
      } else {
        codeEntryView
      }
      
      if let error = error {
        Text(error)
          .font(.caption)
          .foregroundColor(.red)
          .padding(.horizontal)
      }
    }
    .disabled(isLoading)
  }
  
  private var emailEntryView: some View {
    VStack(spacing: 12) {
      Text("Let's log you in!")
        .font(.headline)
      
      TextField(emailPlaceholder, text: $email)
        #if os(iOS)
        .textContentType(.emailAddress)
        .keyboardType(.emailAddress)
        .autocapitalization(.none)
        #endif
        #if !os(watchOS) && !os(tvOS)
        .textFieldStyle(.roundedBorder)
        #endif
      
      Button(action: sendCode) {
        if isLoading {
          ProgressView()
            .frame(maxWidth: .infinity)
        } else {
          Text(sendButtonTitle)
            .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(email.isEmpty || isLoading)
    }
  }
  
  private var codeEntryView: some View {
    VStack(spacing: 12) {
      Text("Check your email!")
        .font(.headline)
      
      Text("We sent a code to \(sentEmail ?? "")")
        .font(.subheadline)
        .foregroundColor(.secondary)
      
      TextField(codePlaceholder, text: $code)
        #if os(iOS)
        .textContentType(.oneTimeCode)
        .keyboardType(.numberPad)
        #endif
        #if !os(watchOS) && !os(tvOS)
        .textFieldStyle(.roundedBorder)
        #endif
      
      Button(action: verifyCode) {
        if isLoading {
          ProgressView()
            .frame(maxWidth: .infinity)
        } else {
          Text(verifyButtonTitle)
            .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(code.isEmpty || isLoading)
      
      Button("Use different email") {
        sentEmail = nil
        code = ""
        error = nil
      }
      .font(.caption)
    }
  }
  
  private func sendCode() {
    guard !email.isEmpty else { return }
    
    isLoading = true
    error = nil
    
    Task { @MainActor in
      do {
        if let auth = auth {
          try await auth.sendMagicCode(to: email)
        } else {
          let client = InstantClientFactory.makeClient(appID: appID ?? "")
          try await client.authManager.sendMagicCode(email: email)
        }
        
        sentEmail = email
        isLoading = false
      } catch {
        self.error = error.localizedDescription
        isLoading = false
      }
    }
  }
  
  private func verifyCode() {
    guard let sentEmail = sentEmail, !code.isEmpty else { return }
    
    isLoading = true
    error = nil
    
    Task { @MainActor in
      do {
        let user: User
        
        if let auth = auth {
          user = try await auth.verifyMagicCode(email: sentEmail, code: code)
        } else {
          let client = InstantClientFactory.makeClient(appID: appID ?? "")
          user = try await client.authManager.signInWithMagicCode(email: sentEmail, code: code)
        }
        
        isLoading = false
        onCompletion(.success(user))
      } catch {
        self.error = error.localizedDescription
        isLoading = false
      }
    }
  }
}

// MARK: - Preview

#if DEBUG
struct MagicCodeView_Previews: PreviewProvider {
  static var previews: some View {
    MagicCodeView { _ in }
      .padding()
  }
}
#endif
#endif


