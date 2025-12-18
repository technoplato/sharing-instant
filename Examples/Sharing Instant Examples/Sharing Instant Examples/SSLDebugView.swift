// SSLDebugView.swift
// A diagnostic view to debug SSL/TLS connection issues in iOS Simulator
//
// This view attempts to connect to api.instantdb.com and displays detailed
// information about the SSL certificate chain, any errors encountered, and
// the trust evaluation result.

import SwiftUI
import Foundation
import Security

// MARK: - SSL Debug View

struct SSLDebugView: View {
  @State private var logs: [LogEntry] = []
  @State private var isRunning = false
  
  var body: some View {
    NavigationView {
      VStack(spacing: 0) {
        // Status header
        statusHeader
        
        // Log output
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
              ForEach(logs) { log in
                LogRowView(entry: log)
                  .id(log.id)
              }
            }
            .padding()
          }
          .onChange(of: logs.count) { _ in
            if let lastLog = logs.last {
              withAnimation {
                proxy.scrollTo(lastLog.id, anchor: .bottom)
              }
            }
          }
        }
        
        // Action buttons
        actionButtons
      }
      .navigationTitle("SSL Debug")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
  
  // MARK: - Subviews
  
  private var statusHeader: some View {
    HStack {
      Circle()
        .fill(isRunning ? Color.orange : (hasError ? Color.red : Color.green))
        .frame(width: 12, height: 12)
      
      Text(isRunning ? "Running..." : (hasError ? "Error Detected" : "Ready"))
        .font(.headline)
      
      Spacer()
      
      if !logs.isEmpty {
        Button("Clear") {
          logs.removeAll()
        }
        .font(.caption)
      }
    }
    .padding()
    .background(Color(.systemGray6))
  }
  
  private var actionButtons: some View {
    VStack(spacing: 12) {
      Button(action: runFullDiagnostic) {
        HStack {
          Image(systemName: "stethoscope")
          Text("Run Full Diagnostic")
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.blue)
        .foregroundColor(.white)
        .cornerRadius(10)
      }
      .disabled(isRunning)
      
      HStack(spacing: 12) {
        Button(action: testInstantDB) {
          VStack {
            Image(systemName: "server.rack")
            Text("InstantDB")
              .font(.caption)
          }
          .frame(maxWidth: .infinity)
          .padding()
          .background(Color(.systemGray5))
          .cornerRadius(10)
        }
        .disabled(isRunning)
        
        Button(action: testApple) {
          VStack {
            Image(systemName: "apple.logo")
            Text("Apple")
              .font(.caption)
          }
          .frame(maxWidth: .infinity)
          .padding()
          .background(Color(.systemGray5))
          .cornerRadius(10)
        }
        .disabled(isRunning)
        
        Button(action: testGoogle) {
          VStack {
            Image(systemName: "globe")
            Text("Google")
              .font(.caption)
          }
          .frame(maxWidth: .infinity)
          .padding()
          .background(Color(.systemGray5))
          .cornerRadius(10)
        }
        .disabled(isRunning)
      }
    }
    .padding()
    .background(Color(.systemGray6))
  }
  
  private var hasError: Bool {
    logs.contains { $0.level == .error }
  }
  
  // MARK: - Diagnostic Functions
  
  private func runFullDiagnostic() {
    logs.removeAll()
    isRunning = true
    
    Task {
      log(.info, "═══════════════════════════════════════")
      log(.info, "  SSL/TLS DIAGNOSTIC REPORT")
      log(.info, "═══════════════════════════════════════")
      log(.info, "")
      log(.info, "Date: \(Date().formatted())")
      log(.info, "Device: \(UIDevice.current.name)")
      log(.info, "iOS: \(UIDevice.current.systemVersion)")
      log(.info, "")
      
      // Test multiple hosts
      await testHost("api.instantdb.com", port: 443)
      log(.info, "")
      await testHost("www.apple.com", port: 443)
      log(.info, "")
      await testHost("www.google.com", port: 443)
      
      log(.info, "")
      log(.info, "═══════════════════════════════════════")
      log(.info, "  DIAGNOSTIC COMPLETE")
      log(.info, "═══════════════════════════════════════")
      
      await MainActor.run {
        isRunning = false
      }
    }
  }
  
  private func testInstantDB() {
    logs.removeAll()
    isRunning = true
    Task {
      await testHost("api.instantdb.com", port: 443)
      await MainActor.run { isRunning = false }
    }
  }
  
  private func testApple() {
    logs.removeAll()
    isRunning = true
    Task {
      await testHost("www.apple.com", port: 443)
      await MainActor.run { isRunning = false }
    }
  }
  
  private func testGoogle() {
    logs.removeAll()
    isRunning = true
    Task {
      await testHost("www.google.com", port: 443)
      await MainActor.run { isRunning = false }
    }
  }
  
  // MARK: - Host Testing
  
  private func testHost(_ host: String, port: Int) async {
    log(.section, "Testing: \(host):\(port)")
    
    // Step 1: DNS Resolution
    log(.info, "→ Resolving DNS...")
    let dnsResult = await resolveDNS(host: host)
    switch dnsResult {
    case .success(let addresses):
      log(.success, "  DNS resolved: \(addresses.joined(separator: ", "))")
    case .failure(let error):
      log(.error, "  DNS failed: \(error.localizedDescription)")
      return
    }
    
    // Step 2: TCP Connection
    log(.info, "→ Establishing TCP connection...")
    
    // Step 3: TLS Handshake with certificate inspection
    log(.info, "→ Performing TLS handshake...")
    await performTLSConnection(host: host, port: port)
    
    // Step 4: HTTP Request
    log(.info, "→ Making HTTPS request...")
    await performHTTPRequest(host: host)
  }
  
  private func resolveDNS(host: String) async -> Result<[String], Error> {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        
        if status != 0 {
          let errorMessage = String(cString: gai_strerror(status))
          continuation.resume(returning: .failure(NSError(
            domain: "DNS",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: errorMessage]
          )))
          return
        }
        
        var addresses: [String] = []
        var ptr = result
        while ptr != nil {
          if let addr = ptr?.pointee.ai_addr {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(ptr!.pointee.ai_addrlen),
                          &hostname, socklen_t(hostname.count),
                          nil, 0, NI_NUMERICHOST) == 0 {
              addresses.append(String(cString: hostname))
            }
          }
          ptr = ptr?.pointee.ai_next
        }
        
        freeaddrinfo(result)
        continuation.resume(returning: .success(addresses))
      }
    }
  }
  
  private func performTLSConnection(host: String, port: Int) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().async {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        
        CFStreamCreatePairWithSocketToHost(nil, host as CFString, UInt32(port), &readStream, &writeStream)
        
        guard let inputStream = readStream?.takeRetainedValue() as? InputStream,
              let outputStream = writeStream?.takeRetainedValue() as? OutputStream else {
          self.log(.error, "  Failed to create streams")
          continuation.resume()
          return
        }
        
        // Enable SSL
        inputStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        outputStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        
        // Set SSL settings
        let sslSettings: [String: Any] = [
          kCFStreamSSLPeerName as String: host
        ]
        inputStream.setProperty(sslSettings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)
        outputStream.setProperty(sslSettings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)
        
        inputStream.open()
        outputStream.open()
        
        // Wait for connection
        var attempts = 0
        while inputStream.streamStatus == .opening && attempts < 50 {
          Thread.sleep(forTimeInterval: 0.1)
          attempts += 1
        }
        
        let status = inputStream.streamStatus
        self.log(.info, "  Stream status: \(self.streamStatusString(status))")
        
        if let error = inputStream.streamError {
          self.log(.error, "  Stream error: \(error.localizedDescription)")
          self.log(.error, "  Error code: \((error as NSError).code)")
          self.log(.error, "  Error domain: \((error as NSError).domain)")
          
          // Check for specific SSL errors
          let nsError = error as NSError
          if nsError.domain == NSOSStatusErrorDomain {
            self.logSSLError(code: OSStatus(nsError.code))
          }
        }
        
        // Try to get certificate info via URLSession instead
        inputStream.close()
        outputStream.close()
        
        continuation.resume()
      }
    }
    
    // Use URLSession to get certificate details
    await getCertificateChain(host: host)
  }
  
  private func getCertificateChain(host: String) async {
    let url = URL(string: "https://\(host)/")!
    
    let delegate = CertificateInspectorDelegate { [self] trust in
      self.inspectTrust(trust, host: host)
    }
    
    let session = URLSession(
      configuration: .ephemeral,
      delegate: delegate,
      delegateQueue: nil
    )
    
    do {
      let (_, response) = try await session.data(from: url)
      if let httpResponse = response as? HTTPURLResponse {
        log(.success, "  HTTP Status: \(httpResponse.statusCode)")
      }
    } catch {
      log(.error, "  Request failed: \(error.localizedDescription)")
      
      let nsError = error as NSError
      if nsError.domain == NSURLErrorDomain {
        switch nsError.code {
        case NSURLErrorServerCertificateUntrusted:
          log(.error, "  ⚠️ CERTIFICATE NOT TRUSTED")
          log(.error, "  This is likely a Zscaler interception issue")
        case NSURLErrorServerCertificateHasBadDate:
          log(.error, "  ⚠️ CERTIFICATE DATE INVALID")
        case NSURLErrorServerCertificateHasUnknownRoot:
          log(.error, "  ⚠️ UNKNOWN ROOT CERTIFICATE")
          log(.error, "  The Zscaler root CA is not trusted on this device")
        case NSURLErrorSecureConnectionFailed:
          log(.error, "  ⚠️ SECURE CONNECTION FAILED")
        default:
          break
        }
      }
    }
    
    session.invalidateAndCancel()
  }
  
  private func inspectTrust(_ trust: SecTrust, host: String) {
    let certCount = SecTrustGetCertificateCount(trust)
    log(.info, "  Certificate chain (\(certCount) certs):")
    
    for i in 0..<certCount {
      if let cert = SecTrustCopyCertificateChain(trust)?[i] as? SecCertificate {
        let summary = SecCertificateCopySubjectSummary(cert) as String? ?? "Unknown"
        let prefix = i == 0 ? "  └─ [Leaf]" : (i == certCount - 1 ? "  └─ [Root]" : "  ├─ [Intermediate]")
        
        // Check if this looks like Zscaler
        let isZscaler = summary.lowercased().contains("zscaler")
        if isZscaler {
          log(.warning, "\(prefix) \(summary) ⚡️ ZSCALER")
        } else {
          log(.info, "\(prefix) \(summary)")
        }
      }
    }
    
    // Evaluate trust
    var error: CFError?
    let trusted = SecTrustEvaluateWithError(trust, &error)
    
    if trusted {
      log(.success, "  ✅ Certificate chain is TRUSTED")
    } else {
      log(.error, "  ❌ Certificate chain is NOT TRUSTED")
      if let error = error {
        log(.error, "  Reason: \(error.localizedDescription)")
      }
    }
  }
  
  private func performHTTPRequest(host: String) async {
    let url = URL(string: "https://\(host)/")!
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      if let httpResponse = response as? HTTPURLResponse {
        log(.success, "  Response: \(httpResponse.statusCode)")
        log(.info, "  Data size: \(data.count) bytes")
      }
    } catch {
      log(.error, "  HTTP Request failed: \(error.localizedDescription)")
    }
  }
  
  // MARK: - Helpers
  
  private func log(_ level: LogLevel, _ message: String) {
    let entry = LogEntry(level: level, message: message)
    DispatchQueue.main.async {
      self.logs.append(entry)
    }
  }
  
  private func streamStatusString(_ status: Stream.Status) -> String {
    switch status {
    case .notOpen: return "Not Open"
    case .opening: return "Opening"
    case .open: return "Open"
    case .reading: return "Reading"
    case .writing: return "Writing"
    case .atEnd: return "At End"
    case .closed: return "Closed"
    case .error: return "Error"
    @unknown default: return "Unknown"
    }
  }
  
  private func logSSLError(code: OSStatus) {
    let errorMessages: [OSStatus: String] = [
      errSSLProtocol: "SSL Protocol Error",
      errSSLNegotiation: "SSL Negotiation Failed",
      errSSLFatalAlert: "SSL Fatal Alert",
      errSSLWouldBlock: "SSL Would Block",
      errSSLSessionNotFound: "SSL Session Not Found",
      errSSLClosedGraceful: "SSL Closed Gracefully",
      errSSLClosedAbort: "SSL Closed Abort",
      errSSLXCertChainInvalid: "SSL Certificate Chain Invalid",
      errSSLBadCert: "SSL Bad Certificate",
      errSSLCrypto: "SSL Crypto Error",
      errSSLInternal: "SSL Internal Error",
      errSSLCertExpired: "SSL Certificate Expired",
      errSSLCertNotYetValid: "SSL Certificate Not Yet Valid",
      errSSLClosedNoNotify: "SSL Closed No Notify",
      errSSLBufferOverflow: "SSL Buffer Overflow",
      errSSLBadCipherSuite: "SSL Bad Cipher Suite",
      errSSLPeerUnexpectedMsg: "SSL Peer Unexpected Message",
      errSSLPeerBadRecordMac: "SSL Peer Bad Record MAC",
      errSSLPeerDecryptionFail: "SSL Peer Decryption Failed",
      errSSLPeerRecordOverflow: "SSL Peer Record Overflow",
      errSSLPeerDecompressFail: "SSL Peer Decompress Failed",
      errSSLPeerHandshakeFail: "SSL Peer Handshake Failed",
      errSSLPeerBadCert: "SSL Peer Bad Certificate",
      errSSLPeerUnsupportedCert: "SSL Peer Unsupported Certificate",
      errSSLPeerCertRevoked: "SSL Peer Certificate Revoked",
      errSSLPeerCertExpired: "SSL Peer Certificate Expired",
      errSSLPeerCertUnknown: "SSL Peer Certificate Unknown",
      errSSLIllegalParam: "SSL Illegal Parameter",
      errSSLPeerUnknownCA: "SSL Peer Unknown CA - ROOT NOT TRUSTED",
      errSSLPeerAccessDenied: "SSL Peer Access Denied",
      errSSLHostNameMismatch: "SSL Hostname Mismatch",
      errSSLConnectionRefused: "SSL Connection Refused",
      errSSLDecryptionFail: "SSL Decryption Failed",
      errSSLBadRecordMac: "SSL Bad Record MAC",
      errSSLRecordOverflow: "SSL Record Overflow",
      errSSLBadConfiguration: "SSL Bad Configuration",
      errSSLUnexpectedRecord: "SSL Unexpected Record",
      errSSLWeakPeerEphemeralDHKey: "SSL Weak Peer DH Key",
      errSSLClientCertRequested: "SSL Client Cert Requested",
      errSSLTransportReset: "SSL Transport Reset",
      errSSLNetworkTimeout: "SSL Network Timeout",
      errSSLConfigurationFailed: "SSL Configuration Failed",
      errSSLUnsupportedExtension: "SSL Unsupported Extension",
      errSSLUnexpectedMessage: "SSL Unexpected Message",
      errSSLDecompressFail: "SSL Decompress Failed",
      errSSLHandshakeFail: "SSL Handshake Failed",
      errSSLDecodeError: "SSL Decode Error",
      errSSLInappropriateFallback: "SSL Inappropriate Fallback",
      errSSLMissingExtension: "SSL Missing Extension",
      errSSLBadCertificateStatusResponse: "SSL Bad Certificate Status Response",
      errSSLCertificateRequired: "SSL Certificate Required",
      errSSLUnknownPSKIdentity: "SSL Unknown PSK Identity",
      errSSLUnrecognizedName: "SSL Unrecognized Name",
      errSSLATSViolation: "SSL ATS Violation",
      errSSLATSMinimumVersionViolation: "SSL ATS Minimum Version Violation",
      errSSLATSCiphersuiteViolation: "SSL ATS Ciphersuite Violation",
      errSSLATSMinimumKeySizeViolation: "SSL ATS Minimum Key Size Violation",
      errSSLATSLeafCertificateHashAlgorithmViolation: "SSL ATS Leaf Cert Hash Algorithm Violation",
      errSSLATSCertificateHashAlgorithmViolation: "SSL ATS Cert Hash Algorithm Violation",
      errSSLATSCertificateTrustViolation: "SSL ATS Certificate Trust Violation",
    ]
    
    if let message = errorMessages[code] {
      log(.error, "  SSL Error: \(message) (code: \(code))")
    } else {
      log(.error, "  SSL Error code: \(code)")
    }
  }
}

// MARK: - Certificate Inspector Delegate

private class CertificateInspectorDelegate: NSObject, URLSessionDelegate {
  let onTrustReceived: (SecTrust) -> Void
  
  init(onTrustReceived: @escaping (SecTrust) -> Void) {
    self.onTrustReceived = onTrustReceived
  }
  
  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          let trust = challenge.protectionSpace.serverTrust else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    
    // Inspect the trust object
    onTrustReceived(trust)
    
    // Use default handling (will fail if cert not trusted)
    completionHandler(.performDefaultHandling, nil)
  }
}

// MARK: - Log Entry Model

private enum LogLevel {
  case info
  case success
  case warning
  case error
  case section
}

private struct LogEntry: Identifiable {
  let id = UUID()
  let timestamp = Date()
  let level: LogLevel
  let message: String
}

// MARK: - Log Row View

private struct LogRowView: View {
  let entry: LogEntry
  
  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      icon
        .frame(width: 16)
      
      Text(entry.message)
        .font(.system(.caption, design: .monospaced))
        .foregroundColor(textColor)
    }
  }
  
  @ViewBuilder
  private var icon: some View {
    switch entry.level {
    case .info:
      Image(systemName: "info.circle")
        .foregroundColor(.blue)
        .font(.caption)
    case .success:
      Image(systemName: "checkmark.circle.fill")
        .foregroundColor(.green)
        .font(.caption)
    case .warning:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.orange)
        .font(.caption)
    case .error:
      Image(systemName: "xmark.circle.fill")
        .foregroundColor(.red)
        .font(.caption)
    case .section:
      Image(systemName: "arrow.right.circle.fill")
        .foregroundColor(.purple)
        .font(.caption)
    }
  }
  
  private var textColor: Color {
    switch entry.level {
    case .error: return .red
    case .warning: return .orange
    case .success: return .green
    case .section: return .purple
    case .info: return .primary
    }
  }
}

// MARK: - Preview

#Preview {
  SSLDebugView()
}

