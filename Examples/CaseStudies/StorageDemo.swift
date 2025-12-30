import SharingInstant
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
  import AppKit
#endif

#if os(iOS) && canImport(PhotosUI)
  import Photos
  import PhotosUI
#endif

#if canImport(UIKit)
  import UIKit
#endif

// MARK: - Storage Demo

struct StorageDemo: SwiftUICaseStudy {
  var caseStudyTitle: String { "Storage" }

  var readMe: String {
    """
    This CaseStudy demonstrates file uploads and previews using InstantDB Storage (`$files`)
    with SharingInstant's Shared-based ergonomics.

    Goals:
    - No per-view “state soup” to manage uploading/deleting rows.
    - Optimistic previews: new uploads appear immediately using a local preview while
      the server `$files` subscription catches up.
    - Reactive feeds: the grid is driven by `@SharedReader(.storageFeed(...))`.

    APIs demonstrated:
    - `@SharedReader(.instantStorage)` for mutation-style upload/delete/retry.
    - `@SharedReader(.storageFeed(scope: .user))` for a merged feed (server `$files` + local optimistic state).
    - `StorageMediaView(item:)` for text/image/video previews.

    Notes:
    - Storage access is permission-gated by `$files`. A common pattern is to restrict access
      to an auth-id prefix: `data.path.startsWith(auth.id + '/')`.
    - Demo size limits are arbitrary and exist only to keep this CaseStudy fast/stable.
    """
  }

  var body: some View {
    StorageDemoView()
      .onAppear { InstantLogger.viewAppeared("StorageDemo") }
      .onDisappear { InstantLogger.viewDisappeared("StorageDemo") }
  }
}

// MARK: - StorageDemoView

private struct StorageDemoView: View {
  @SharedReader(.instantAuthState)
  private var authState: AuthState

  @SharedReader(.instantStorage)
  private var storage: InstantStorageClient

  @SharedReader(.storageFeed(scope: .user))
  private var feed: IdentifiedArrayOf<StorageItem>

  @State private var folder: String = "case-studies/storage"
  @State private var screenshotWatcherEnabled = false
  @State private var lastUploadedPath: String?
  @State private var errorMessage: String?

  @State private var isShowingFileImporter = false

  @State private var textFilename = "note.txt"
  @State private var textToUpload = """
  Hello from SharingInstant!

  This file was uploaded using @SharedReader(.instantStorage) and rendered via $files.url.
  """

  #if os(iOS) && canImport(PhotosUI)
    @State private var selectedPhotosItem: PhotosPickerItem?
  #endif

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        authCard
        uploadCard

        #if os(iOS) && canImport(PhotosUI)
          screenshotWatcherCard
        #endif

        feedCard
      }
      .padding()
    }
    .fileImporter(
      isPresented: $isShowingFileImporter,
      allowedContentTypes: [.text, .image, .movie],
      allowsMultipleSelection: false,
      onCompletion: handleFileImporterResult
    )
    .alert(
      "Storage Error",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { isPresented in
          if !isPresented { errorMessage = nil }
        }
      )
    ) {
      Button("OK", role: .cancel) {
        errorMessage = nil
      }
    } message: {
      Text(errorMessage ?? "")
    }
    #if os(iOS) && canImport(PhotosUI)
      .onChange(of: selectedPhotosItem) { newItem in
        guard let newItem else { return }
        Task { @MainActor in
          await handlePhotosPickerSelection(newItem)
          selectedPhotosItem = nil
        }
      }
      .onChange(of: screenshotWatcherEnabled) { enabled in
        guard enabled else { return }
        Task { @MainActor in
          await ensureScreenshotAccessOrDisable()
        }
      }
      .task(id: screenshotWatcherEnabled) {
        guard screenshotWatcherEnabled else { return }
        for await _ in NotificationCenter.default.notifications(named: UIApplication.userDidTakeScreenshotNotification) {
          await uploadLatestScreenshot()
        }
      }
    #endif
  }

  // MARK: - Cards

  private var authCard: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        switch authState {
        case .loading:
          HStack(spacing: 8) {
            ProgressView()
            Text("Loading auth…")
          }

        case .unauthenticated:
          Text("Not signed in.")
            .foregroundStyle(.secondary)

          Button("Sign in as Guest") {
            Task { @MainActor in
              do {
                let client = InstantClientFactory.makeClient()
                _ = try await client.authManager.signInAsGuest()
              } catch {
                errorMessage = error.localizedDescription
              }
            }
          }

        case .guest(let user):
          LabeledContent("User", value: user.id)
          LabeledContent("Session", value: "Guest")
          signOutButton

        case .authenticated(let user):
          LabeledContent("User", value: user.id)
          LabeledContent("Session", value: "Authenticated")
          signOutButton
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Label("Auth", systemImage: "person.crop.circle")
    }
  }

  private var signOutButton: some View {
    Button("Sign out") {
      Task { @MainActor in
        do {
          let client = InstantClientFactory.makeClient()
          try await client.authManager.signOut()
        } catch {
          errorMessage = error.localizedDescription
        }
      }
    }
  }

  private var uploadCard: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        Text(
          """
          Upload a file and it appears in the grid immediately with a local preview.

          Demo limits (arbitrary):
          • Text: \(DemoLimits.textLimitString)
          • Images: \(DemoLimits.imageLimitString)
          • Videos: \(DemoLimits.videoLimitString)
          """
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        TextField("Folder (under <user-id>/…)", text: $folder)
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
          #endif

        HStack(spacing: 12) {
          #if os(iOS) && canImport(PhotosUI)
            PhotosPicker(selection: $selectedPhotosItem, matching: .any(of: [.images, .videos])) {
              Label("Pick Photo/Video", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(!authState.isSignedIn)
          #endif

          Button {
            isShowingFileImporter = true
          } label: {
            Label("Pick File", systemImage: "doc")
          }
          .disabled(!authState.isSignedIn)
        }

        Divider()

        Text("Upload text")
          .font(.headline)

        TextField("Filename", text: $textFilename)
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
          #endif

        TextEditor(text: $textToUpload)
          .frame(minHeight: 120)
          .font(.system(.body, design: .monospaced))

        Button {
          Task { @MainActor in
            uploadText()
          }
        } label: {
          Label("Upload Text", systemImage: "arrow.up.doc")
        }
        .disabled(!authState.isSignedIn)

        if let lastUploadedPath {
          HStack(spacing: 8) {
            Text("Last upload:")
              .foregroundStyle(.secondary)
            Text(lastUploadedPath)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .font(.caption)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Label("Upload", systemImage: "square.and.arrow.up")
    }
  }

  #if os(iOS) && canImport(PhotosUI)
    private var screenshotWatcherCard: some View {
      GroupBox {
        VStack(alignment: .leading, spacing: 12) {
          Toggle(isOn: $screenshotWatcherEnabled) {
            Text("Upload screenshots automatically")
              .font(.headline)
          }

          Text(
            """
            When enabled, taking a screenshot triggers an upload and the screenshot appears in the grid.

            Requires Photos access to locate the most recent screenshot in your library.
            """
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } label: {
        Label("Screenshot Watcher", systemImage: "camera.viewfinder")
      }
    }
  #endif

  private var feedCard: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text("Feed")
            .font(.headline)

          Spacer()

          Text("\(feed.count) files")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if !authState.isSignedIn {
          ContentUnavailableView {
            Label("Sign in to view your uploads", systemImage: "person.crop.circle")
          } description: {
            Text("This CaseStudy uses `.storageFeed(scope: .user)` which scopes remote files to your auth id prefix.")
          }
        } else if feed.isEmpty {
          ContentUnavailableView {
            Label("No files yet", systemImage: "doc")
          } description: {
            Text("Pick a photo/video or file above and it will appear here immediately.")
          }
        } else {
          StorageFeedGrid(items: Array(feed), folder: folder)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Label("Files", systemImage: "square.grid.2x2")
    }
  }

  // MARK: - Actions

  @MainActor
  private func uploadText() {
    guard authState.isSignedIn else { return }

    let filename = textFilename
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty ? "note.txt" : textFilename

    guard let data = textToUpload.data(using: .utf8) else { return }
    guard DemoLimits.isAllowed(sizeBytes: Int64(data.count), kind: .text) else {
      errorMessage = DemoLimits.errorMessage(kind: .text, sizeBytes: Int64(data.count))
      return
    }

    let ref = storage.upload(
      data: data,
      filename: filename,
      contentType: "text/plain",
      contentDisposition: "inline",
      folder: folder,
      scope: .user
    )

    lastUploadedPath = ref.path
  }

  private func handleFileImporterResult(_ result: Result<[URL], any Error>) {
    Task { @MainActor in
      switch result {
      case .success(let urls):
        guard let url = urls.first else { return }
        await uploadFile(url: url)
      case .failure(let error):
        errorMessage = error.localizedDescription
      }
    }
  }

  @MainActor
  private func uploadFile(url: URL) async {
    guard authState.isSignedIn else { return }

    let needsAccess = url.startAccessingSecurityScopedResource()
    defer {
      if needsAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    let kind = StorageKind.infer(path: url.lastPathComponent, contentType: contentType)

    guard kind != .binary else {
      errorMessage = DemoLimits.unsupportedTypeMessage(filename: url.lastPathComponent)
      return
    }

    if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) {
      guard DemoLimits.isAllowed(sizeBytes: size, kind: kind) else {
        errorMessage = DemoLimits.errorMessage(kind: kind, sizeBytes: size)
        return
      }
    }

    let ref = storage.upload(
      fileURL: url,
      contentType: contentType,
      contentDisposition: "inline",
      folder: folder,
      scope: .user
    )

    lastUploadedPath = ref.path
  }

  #if os(iOS) && canImport(PhotosUI)
    @MainActor
    private func handlePhotosPickerSelection(_ item: PhotosPickerItem) async {
      guard authState.isSignedIn else { return }

      do {
        let types = item.supportedContentTypes
        let type = types.first(where: { $0.conforms(to: .movie) })
          ?? types.first(where: { $0.conforms(to: .video) })
          ?? types.first(where: { $0.conforms(to: .image) })
          ?? types.first
          ?? .item

        let contentType = type.preferredMIMEType
        let kind = StorageKind.infer(path: "media.\(type.preferredFilenameExtension ?? "bin")", contentType: contentType)

        guard kind != .binary else {
          errorMessage = DemoLimits.unsupportedTypeMessage(filename: "Selected media")
          return
        }

        if kind == .video {
          let fileURL = try await item.loadFileURL()

          if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) {
            guard DemoLimits.isAllowed(sizeBytes: size, kind: .video) else {
              try? FileManager.default.removeItem(at: fileURL)
              errorMessage = DemoLimits.errorMessage(kind: .video, sizeBytes: size)
              return
            }
          }

          let ref = storage.upload(
            fileURL: fileURL,
            contentType: contentType,
            contentDisposition: "inline",
            folder: folder,
            scope: .user
          )

          lastUploadedPath = ref.path
          return
        }

        guard let data = try await item.loadTransferable(type: Data.self) else {
          throw DemoLimits.DemoError.failedToLoadFromPhotos
        }

        guard DemoLimits.isAllowed(sizeBytes: Int64(data.count), kind: kind) else {
          errorMessage = DemoLimits.errorMessage(kind: kind, sizeBytes: Int64(data.count))
          return
        }

        let ext = type.preferredFilenameExtension ?? (kind == .image ? "jpg" : "txt")
        let filename = "\(kind.rawValue)-\(UUID().uuidString.lowercased()).\(ext)"

        let ref = storage.upload(
          data: data,
          filename: filename,
          contentType: contentType,
          contentDisposition: "inline",
          folder: folder,
          scope: .user
        )

        lastUploadedPath = ref.path
      } catch {
        errorMessage = error.localizedDescription
      }
    }

    @MainActor
    private func ensureScreenshotAccessOrDisable() async {
      let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      if status == .authorized || status == .limited { return }

      let newStatus = await withCheckedContinuation { continuation in
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
          continuation.resume(returning: status)
        }
      }

      if newStatus != .authorized && newStatus != .limited {
        screenshotWatcherEnabled = false
        errorMessage = """
        Screenshot watcher requires Photos access.

        WHAT HAPPENED:
          iOS did not grant permission to read screenshots from your Photos library.

        WHY THIS EXISTS:
          This CaseStudy locates the most recent screenshot using PhotoKit so it can upload it.

        HOW TO FIX:
          Enable Photos access for this app in Settings, then re-enable the toggle.
        """
      }
    }

    @MainActor
    private func uploadLatestScreenshot() async {
      guard authState.isSignedIn else { return }
      guard screenshotWatcherEnabled else { return }

      let fetchOptions = PHFetchOptions()
      fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
      fetchOptions.fetchLimit = 1

      let screenshotBitmask = PHAssetMediaSubtype.photoScreenshot.rawValue
      fetchOptions.predicate = NSPredicate(format: "(mediaSubtype & %d) != 0", screenshotBitmask)

      let result = PHAsset.fetchAssets(with: .image, options: fetchOptions)
      guard let asset = result.firstObject else { return }

      do {
        let image = try await asset.loadImage()
        let ref = storage.upload(
          image: image,
          filename: "screenshot.jpg",
          jpegQuality: 0.85,
          contentDisposition: "inline",
          folder: folder,
          scope: .user
        )
        lastUploadedPath = ref.path
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  #endif
}

// MARK: - StorageFeedGrid

private struct StorageFeedGrid: View {
  let items: [StorageItem]
  let folder: String

  @SharedReader(.instantStorage)
  private var storage: InstantStorageClient

  private let columns: [GridItem] = [
    GridItem(.adaptive(minimum: 160), spacing: 12)
  ]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 12) {
      ForEach(items) { item in
        StorageFeedCell(item: item, folder: folder)
      }
    }
    .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop(providers:))
  }

  private func handleDrop(providers: [NSItemProvider]) -> Bool {
    let didAccept = providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    guard didAccept else { return false }

    for provider in providers {
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        let url: URL?

        if let urlValue = item as? URL {
          url = urlValue
        } else if let nsURL = item as? NSURL {
          url = nsURL as URL
        } else if let data = item as? Data {
          url = URL(dataRepresentation: data, relativeTo: nil)
        } else {
          url = nil
        }

        guard let url else { return }

        Task { @MainActor in
          _ = storage.upload(fileURL: url, folder: folder, scope: .user)
        }
      }
    }

    return true
  }
}

// MARK: - StorageFeedCell

private struct StorageFeedCell: View {
  let item: StorageItem
  let folder: String

  @SharedReader(.instantStorage)
  private var storage: InstantStorageClient

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      StorageMediaView(item: item)
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 16))

      Text(item.ref.path)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)

      if let failure = item.status.failure {
        Text(failure.message)
          .font(.caption2)
          .foregroundStyle(.red)
          .lineLimit(2)
      }
    }
    .contextMenu {
      if item.status.isFailed {
        Button("Retry Upload") {
          Task { @MainActor in
            storage.retry(item.ref)
          }
        }
      }

      if let url = item.url {
        Button("Copy URL") {
          copyToPasteboard(url.absoluteString)
        }
      }

      Button("Copy Path") {
        copyToPasteboard(item.ref.path)
      }

      Button("Delete", role: .destructive) {
        Task { @MainActor in
          storage.delete(item.ref)
        }
      }
    }
  }

  private func copyToPasteboard(_ string: String) {
    #if canImport(UIKit)
      UIPasteboard.general.string = string
    #elseif canImport(AppKit)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(string, forType: .string)
    #else
      _ = string
    #endif
  }
}

// MARK: - DemoLimits

private enum DemoLimits {
  static let maxTextBytes: Int64 = 1 * 1024 * 1024
  static let maxImageBytes: Int64 = 10 * 1024 * 1024
  static let maxVideoBytes: Int64 = 25 * 1024 * 1024

  static let textLimitString = ByteCountFormatter.string(fromByteCount: maxTextBytes, countStyle: .file)
  static let imageLimitString = ByteCountFormatter.string(fromByteCount: maxImageBytes, countStyle: .file)
  static let videoLimitString = ByteCountFormatter.string(fromByteCount: maxVideoBytes, countStyle: .file)

  static func isAllowed(sizeBytes: Int64, kind: StorageKind) -> Bool {
    guard let max = maxBytes(for: kind) else { return false }
    return sizeBytes <= max
  }

  static func maxBytes(for kind: StorageKind) -> Int64? {
    switch kind {
    case .text:
      return maxTextBytes
    case .image:
      return maxImageBytes
    case .video:
      return maxVideoBytes
    case .binary:
      return nil
    }
  }

  static func errorMessage(kind: StorageKind, sizeBytes: Int64) -> String {
    let sizeString = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    let maxString = ByteCountFormatter.string(fromByteCount: maxBytes(for: kind) ?? 0, countStyle: .file)

    return """
    File is too large for this CaseStudy.

    WHAT HAPPENED:
      The selected file is \(sizeString), but this demo caps uploads at \(maxString).

    WHY THIS EXISTS:
      This CaseStudy loads files into memory to keep the preview code simple.
      Large media files can make the demo slow or unstable on devices.

    HOW TO FIX:
      Pick a smaller file, or adjust DemoLimits in StorageDemo.swift.
    """
  }

  static func unsupportedTypeMessage(filename: String) -> String {
    """
    Unsupported file type: \(filename)

    WHAT HAPPENED:
      This CaseStudy currently supports text, image, and video uploads only.

    WHY THIS EXISTS:
      We keep the supported surface area intentionally small while we iterate on the storage API ergonomics.

    HOW TO FIX:
      Pick a .txt/.md/.json file, an image (png/jpg/heic), or a video (mov/mp4).
    """
  }

  enum DemoError: LocalizedError {
    case failedToLoadFromPhotos

    var errorDescription: String? {
      switch self {
      case .failedToLoadFromPhotos:
        return """
        Failed to load the selected photo/video.

        WHAT HAPPENED:
          PhotosPicker returned an item, but the app could not load its bytes.

        WHY THIS HAPPENS:
          The Photos library may still be downloading the media, the item may be in an unsupported representation,
          or iOS denied access.

        HOW TO FIX:
          Try selecting a different item, or try again after the media has fully downloaded.
        """
      }
    }
  }
}

// MARK: - iOS: Screenshot + PhotosPicker Helpers

#if os(iOS) && canImport(PhotosUI)
  private struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
      FileRepresentation(contentType: .movie) { video in
        SentTransferredFile(video.url)
      } importing: { received in
        let filename = UUID().uuidString.lowercased()
        let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
        let destinationURL = FileManager.default.temporaryDirectory
          .appendingPathComponent(filename)
          .appendingPathExtension(ext)

        try FileManager.default.copyItem(at: received.file, to: destinationURL)
        return VideoTransferable(url: destinationURL)
      }
    }
  }

  private extension PhotosPickerItem {
    func loadFileURL() async throws -> URL {
      guard let video = try await loadTransferable(type: VideoTransferable.self) else {
        throw DemoLimits.DemoError.failedToLoadFromPhotos
      }
      return video.url
    }
  }

  private extension PHAsset {
    func loadImage() async throws -> UIImage {
      try await withCheckedThrowingContinuation { continuation in
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false

        PHImageManager.default().requestImageDataAndOrientation(for: self, options: options) { data, _, _, _ in
          guard let data, let image = UIImage(data: data) else {
            continuation.resume(throwing: DemoLimits.DemoError.failedToLoadFromPhotos)
            return
          }
          continuation.resume(returning: image)
        }
      }
    }
  }
#endif

#Preview {
  NavigationStack {
    CaseStudyView {
      StorageDemo()
    }
  }
}
