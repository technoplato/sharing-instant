import IdentifiedCollections
import SharingInstant
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AVKit)
  import AVKit
#endif

#if os(iOS) && canImport(PhotosUI)
  import PhotosUI
#endif

#if canImport(AppKit)
  import AppKit
#endif

#if canImport(UIKit)
  import UIKit
#endif

// MARK: - Storage Demo

struct StorageDemo: SwiftUICaseStudy {
  var caseStudyTitle: String { "Storage" }

  var readMe: String {
    """
    This demo shows how to work with InstantDB file storage ($files) from SharingInstant.

    It demonstrates two complementary building blocks:

    1) Querying files (read-only)
       - Uses @SharedReader + Schema.instantFiles to subscribe to your files.
       - The UI updates automatically when uploads and deletes happen.

    2) Mutating files (upload / delete / link)
       - Uses InstantStorage, an ObservableObject that tracks mutation state:
         idle -> inFlight -> success/failure (similar to TanStack Query's useMutation).
       - You can call operations directly (uploadFile/link/deleteFile), or you can create a
         per-path handle via `storage.file(path)` and call `upload/link/delete` on it.

    Notes:
    - Storage access is gated by $files permissions. A safe default is to scope access
      to paths under your user id prefix: "<auth.id>/...".
    - The demo uploads plain text and arbitrary files picked from the system file picker.
      Images are previewed in-app; other file types show a signed download link.
    """
  }

  var body: some View {
    StorageDemoView()
      .onAppear {
        InstantLogger.viewAppeared("StorageDemo")
      }
      .onDisappear {
        InstantLogger.viewDisappeared("StorageDemo")
      }
  }
}

// MARK: - StorageDemoView

private struct StorageDemoView: View {
  @StateObject private var auth = InstantAuth()
  @StateObject private var storage = InstantStorage()

  @State.SharedReader private var files: IdentifiedArrayOf<InstantFile>

  @State private var baseFolder = "case-studies/storage"
  @State private var searchText = ""

  @State private var textToUpload = """
    Hello from SharingInstant!

    This is a demo text file uploaded via InstantStorage.
    """

  @State private var isShowingFileImporter = false
  @State private var selectedLocalFile: LocalFile?
  @State private var selectionErrorMessage: String?

  #if os(iOS) && canImport(PhotosUI)
    @State private var selectedMediaItem: PhotosPickerItem?
    @State private var isLoadingMediaItem = false
  #endif

  @State private var lastUploadedPath: String?

  init() {
    _files = State.SharedReader(.instantQuery(Schema.instantFiles.orderBy(\.path, .asc)))
  }

  var body: some View {
    List {
      authSection
      uploadTextSection
      uploadFromPickerSection
      if let lastUploadedPath {
        lastUploadedPreviewSection(path: lastUploadedPath)
      }
      filesSection
    }
    .searchable(text: $searchText, prompt: "Search file paths…")
    .animation(.default, value: files.count)
    .task {
      await configureFilesQueryIfPossible()
    }
    .onChange(of: auth.user?.id) { _, _ in
      Task { @MainActor in
        await configureFilesQueryIfPossible()
      }
    }
  }

  // MARK: - Sections

  private var authSection: some View {
    Section("Auth") {
      switch auth.state {
      case .loading:
        HStack {
          ProgressView()
          Text("Loading auth…")
        }

      case .unauthenticated:
        Text("Not signed in.")

        Button("Sign in as Guest") {
          Task { @MainActor in
            do {
              _ = try await auth.signInAsGuest()
            } catch {
              selectionErrorMessage = error.localizedDescription
            }
          }
        }

      case .guest(let user):
        LabeledContent("User", value: user.id)
        Button("Sign out") {
          Task { @MainActor in
            do {
              try await auth.signOut()
            } catch {
              selectionErrorMessage = error.localizedDescription
            }
          }
        }

      case .authenticated(let user):
        LabeledContent("User", value: user.id)
        Button("Sign out") {
          Task { @MainActor in
            do {
              try await auth.signOut()
            } catch {
              selectionErrorMessage = error.localizedDescription
            }
          }
        }
      }

      if let message = selectionErrorMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private var uploadTextSection: some View {
    Section("Upload a Text File") {
      TextField("Remote folder (under <user-id>/…)", text: $baseFolder)

      TextEditor(text: $textToUpload)
        .frame(minHeight: 120)

      Button {
        Task { @MainActor in
          await uploadTextFile()
        }
      } label: {
        Label("Upload Text", systemImage: "arrow.up.doc")
      }
      .disabled(auth.user?.id == nil)

      uploadStateView

      if let lastUploadedPath {
        LabeledContent("Last upload path", value: lastUploadedPath)
      }
    }
  }

  private var uploadFromPickerSection: some View {
    Section("Upload from Files") {
      let textLimit = ByteCountFormatter.string(fromByteCount: StorageDemoLimits.maxTextBytes, countStyle: .file)
      let imageLimit = ByteCountFormatter.string(fromByteCount: StorageDemoLimits.maxImageBytes, countStyle: .file)
      let videoLimit = ByteCountFormatter.string(fromByteCount: StorageDemoLimits.maxVideoBytes, countStyle: .file)

      Text(
        """
        Pick a text, image, or video file and upload it to InstantDB.

        Demo limits (arbitrary): text up to \(textLimit), images up to \(imageLimit), videos up to \(videoLimit).
        """
      )
        .font(.caption)
        .foregroundStyle(.secondary)

      #if os(iOS) && canImport(PhotosUI)
        PhotosPicker(selection: $selectedMediaItem, matching: .any(of: [.images, .videos])) {
          Label("Choose Photo or Video…", systemImage: "photo.on.rectangle.angled")
        }
      #endif

      Button {
        isShowingFileImporter = true
      } label: {
        Label("Choose File…", systemImage: "doc")
      }

      #if os(iOS) && canImport(PhotosUI)
        if isLoadingMediaItem {
          HStack(spacing: 8) {
            ProgressView()
            Text("Loading selection…")
          }
        }
      #endif

      if let selectedLocalFile {
        LabeledContent("Selected", value: selectedLocalFile.displayName)
        LabeledContent("Kind", value: selectedLocalFile.kindLabel)
        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: selectedLocalFile.sizeBytes, countStyle: .file))
        LabeledContent("MIME", value: selectedLocalFile.contentType ?? "application/octet-stream")

        GroupBox {
          LocalFilePreviewView(file: selectedLocalFile)
        } label: {
          Label("Preview", systemImage: "eye")
        }

        Button {
          Task { @MainActor in
            await uploadSelectedFile(selectedLocalFile)
          }
        } label: {
          Label("Upload Selected File", systemImage: "arrow.up.circle.fill")
        }
        .disabled(auth.user?.id == nil)
      }

      uploadStateView
    }
    .fileImporter(
      isPresented: $isShowingFileImporter,
      allowedContentTypes: [.text, .image, .movie],
      allowsMultipleSelection: false
    ) { result in
      Task { @MainActor in
        await handleFileImporterResult(result)
      }
    }
    #if os(iOS) && canImport(PhotosUI)
      .onChange(of: selectedMediaItem) { _, newItem in
        Task { @MainActor in
          await handlePhotosPickerSelection(newItem)
        }
      }
    #endif
  }

  private func lastUploadedPreviewSection(path: String) -> some View {
    Section("Last Uploaded Preview") {
      LabeledContent("Path", value: path)
      RemoteFilePreviewView(path: path, storage: storage)
    }
  }

  private var filesSection: some View {
    Section("My Files (\(filteredFiles.count))") {
      if auth.user?.id == nil {
        ContentUnavailableView {
          Label("Sign in to view your files", systemImage: "person.crop.circle")
        } description: {
          Text("Sign in as a guest above to scope $files access to your user id prefix.")
        }
      } else {
        HStack {
          Button {
            Task { @MainActor in
              try? await $files.load()
            }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }

          Spacer()

          if $files.isLoading {
            ProgressView()
          }
        }

        if let loadError = $files.loadError {
          ContentUnavailableView {
            Label("Failed to load files", systemImage: "xmark.circle")
          } description: {
            Text(loadError.localizedDescription)
          }
        } else if filteredFiles.isEmpty && $files.isLoading {
          HStack(spacing: 8) {
            ProgressView()
            Text("Loading files…")
          }
        } else if filteredFiles.isEmpty {
          ContentUnavailableView {
            Label("No Files", systemImage: "doc")
          } description: {
            Text("Upload a file above to see it appear here.")
          }
        } else {
          ForEach(filteredFiles) { file in
            NavigationLink {
              CaseStudyView {
                StorageFileDetailView(
                  file: file,
                  storage: storage
                )
              }
            } label: {
              StorageFileRow(file: file)
            }
          }
        }
      }
    }
  }

  private var uploadStateView: some View {
    Group {
      switch storage.uploadState {
      case .idle:
        EmptyView()

      case .inFlight:
        HStack(spacing: 8) {
          ProgressView()
          Text("Uploading…")
        }

      case .success(let uploaded, _):
        Text("Uploaded: \(uploaded.path)")
          .font(.caption)
          .foregroundStyle(.secondary)

      case .failure(let error, _):
        Text("Upload failed: \(error.localizedDescription)")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  // MARK: - Derived

  private var filteredFiles: [InstantFile] {
    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return Array(files)
    }

    return files.filter { file in
      file.path.localizedCaseInsensitiveContains(searchText)
    }
  }

  // MARK: - Actions

  @MainActor
  private func configureFilesQueryIfPossible() async {
    guard let userId = auth.user?.id else { return }

    let key = Schema.instantFiles
      .where(\.path, .startsWith("\(userId)/"))
      .orderBy(\.path, .asc)

    $files = SharedReader(.instantQuery(key))
    try? await $files.load()
  }

  @MainActor
  private func uploadTextFile() async {
    guard let userId = auth.user?.id else { return }
    guard let data = textToUpload.data(using: .utf8) else { return }

    let filename = "note-\(UUID().uuidString.lowercased()).txt"
    let path = buildPath(userId: userId, folder: baseFolder, filename: filename)

    do {
      let uploaded = try await storage.uploadFile(
        path: path,
        data: data,
        options: .init(contentType: "text/plain", contentDisposition: "inline")
      )
      lastUploadedPath = uploaded.path
      try? await $files.load()
    } catch {
      selectionErrorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func uploadSelectedFile(_ file: LocalFile) async {
    guard let userId = auth.user?.id else { return }

    let filename = file.displayName
    let path = buildPath(userId: userId, folder: baseFolder, filename: filename)

    do {
      let uploaded = try await storage.uploadFile(
        path: path,
        data: file.data,
        options: .init(contentType: file.contentType, contentDisposition: "inline")
      )
      lastUploadedPath = uploaded.path
      try? await $files.load()
    } catch {
      selectionErrorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func handleFileImporterResult(_ result: Result<[URL], any Error>) async {
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      do {
        selectedLocalFile = try LocalFile.load(from: url)
      } catch {
        selectionErrorMessage = error.localizedDescription
      }

    case .failure(let error):
      selectionErrorMessage = error.localizedDescription
    }
  }

  #if os(iOS) && canImport(PhotosUI)
    @MainActor
    private func handlePhotosPickerSelection(_ item: PhotosPickerItem?) async {
      guard let item else { return }

      isLoadingMediaItem = true
      selectionErrorMessage = nil

      do {
        selectedLocalFile = try await LocalFile.load(from: item)
      } catch {
        selectedLocalFile = nil
        selectionErrorMessage = error.localizedDescription
      }

      isLoadingMediaItem = false
    }
  #endif

  private func buildPath(userId: String, folder: String, filename: String) -> String {
    let sanitizedFolder = folder
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    let sanitizedFilename = filename
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "/", with: "-")

    if sanitizedFolder.isEmpty {
      return "\(userId)/\(sanitizedFilename)"
    }

    return "\(userId)/\(sanitizedFolder)/\(sanitizedFilename)"
  }
}

// MARK: - StorageFileRow

private struct StorageFileRow: View {
  let file: InstantFile

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      thumbnail

      VStack(alignment: .leading, spacing: 4) {
        Text(file.path)
          .font(.subheadline)

        Text(file.url)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
  }

  private var kind: StoragePreviewKind {
    StoragePreviewKind(path: file.path)
  }

  private var fileURL: URL? {
    URL(string: file.url)
  }

  @ViewBuilder
  private var thumbnail: some View {
    switch kind {
    case .text:
      Image(systemName: "doc.plaintext")
        .font(.system(size: 22))
        .frame(width: 44, height: 44)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))

    case .image:
      if let fileURL {
        if #available(iOS 15.0, macOS 12.0, *) {
          AsyncImage(url: fileURL) { phase in
            switch phase {
            case .empty:
              ProgressView()
                .frame(width: 44, height: 44)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            case .success(let image):
              image
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            case .failure:
              Image(systemName: "photo")
                .font(.system(size: 22))
                .frame(width: 44, height: 44)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            @unknown default:
              Image(systemName: "photo")
                .font(.system(size: 22))
                .frame(width: 44, height: 44)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
          }
        } else {
          Image(systemName: "photo")
            .font(.system(size: 22))
            .frame(width: 44, height: 44)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
      } else {
        Image(systemName: "photo")
          .font(.system(size: 22))
          .frame(width: 44, height: 44)
          .background(Color.secondary.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 10))
      }

    case .video:
      Image(systemName: "film")
        .font(.system(size: 22))
        .frame(width: 44, height: 44)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))

    case .unsupported:
      Image(systemName: "doc")
        .font(.system(size: 22))
        .frame(width: 44, height: 44)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
  }
}

// MARK: - StorageFileDetailView

private struct StorageFileDetailView: SwiftUICaseStudy {
  let file: InstantFile
  @ObservedObject var storage: InstantStorage

  var caseStudyTitle: String { "File" }

  var readMe: String {
    """
    This screen shows a single file in InstantDB storage.

    Actions:
    - Link: calls InstantStorage.link(path:) to generate a temporary signed download URL.
    - Download: downloads the bytes from the signed URL.
    - Delete: deletes the file by path.

    Preview:
    - Text files show decoded UTF-8.
    - Images show an in-app preview (when supported by the platform).
    - Videos stream in-app when supported (AVKit).
    """
  }

  @State private var signedURL: URL?
  @State private var downloadedData: Data?
  @State private var downloadErrorMessage: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Path", value: file.path)
            LabeledContent("ID", value: file.id)
            LabeledContent("DB URL", value: file.url)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
          Label("Metadata", systemImage: "doc")
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            Button {
              Task { @MainActor in
                await generateSignedURL()
              }
            } label: {
              Label("Generate Signed Download URL", systemImage: "link")
            }

            if let signedURL {
              SwiftUI.Link(destination: signedURL) {
                Label("Open Signed URL", systemImage: "arrow.up.right.square")
              }

              Button {
                Task { @MainActor in
                  await downloadPreview(from: signedURL)
                }
              } label: {
                Label("Download Preview", systemImage: "arrow.down.doc")
              }
            }

            Button(role: .destructive) {
              Task { @MainActor in
                await deleteFile()
              }
            } label: {
              Label("Delete File", systemImage: "trash")
            }

            deleteStateView
            linkStateView

            if let downloadErrorMessage {
              Text(downloadErrorMessage)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
          Label("Actions", systemImage: "bolt")
        }

        if signedURL != nil || downloadedData != nil {
          GroupBox {
            StorageSignedFilePreviewView(
              path: file.path,
              signedURL: signedURL,
              downloadedData: downloadedData
            )
          } label: {
            Label("Preview", systemImage: "eye")
          }
        }
      }
      .padding()
    }
  }

  private var linkStateView: some View {
    Group {
      switch storage.linkState {
      case .idle:
        EmptyView()
      case .inFlight:
        HStack(spacing: 8) {
          ProgressView()
          Text("Generating link…")
        }
      case .success(let link, _):
        Text("Signed URL ready for: \(link.path)")
          .font(.caption)
          .foregroundStyle(.secondary)
      case .failure(let error, _):
        Text("Link failed: \(error.localizedDescription)")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private var deleteStateView: some View {
    Group {
      switch storage.deleteState {
      case .idle:
        EmptyView()
      case .inFlight:
        HStack(spacing: 8) {
          ProgressView()
          Text("Deleting…")
        }
      case .success(let deleted, _):
        Text("Deleted: \(deleted.path)")
          .font(.caption)
          .foregroundStyle(.secondary)
      case .failure(let error, _):
        Text("Delete failed: \(error.localizedDescription)")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  @MainActor
  private func generateSignedURL() async {
    do {
      let link = try await storage.link(path: file.path)
      signedURL = link.url
      downloadErrorMessage = nil
    } catch {
      downloadErrorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func downloadPreview(from url: URL) async {
    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      downloadedData = data
      downloadErrorMessage = nil
    } catch {
      downloadErrorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func deleteFile() async {
    do {
      _ = try await storage.deleteFile(path: file.path)
    } catch {
      downloadErrorMessage = error.localizedDescription
    }
  }
}

// MARK: - StorageFilePreviewView

private struct StorageFilePreviewView: View {
  let path: String
  let data: Data

  var body: some View {
    if isTextFile, let string = String(data: data, encoding: .utf8) {
      Text(string)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
    } else if let image = decodeImage(data: data) {
      image
        .resizable()
        .scaledToFit()
        .frame(maxWidth: .infinity)
    } else {
      Text("Downloaded \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)).")
        .foregroundStyle(.secondary)
    }
  }

  private var isTextFile: Bool {
    let lowercased = path.lowercased()
    return lowercased.hasSuffix(".txt")
      || lowercased.hasSuffix(".md")
      || lowercased.hasSuffix(".json")
      || lowercased.hasSuffix(".csv")
      || lowercased.hasSuffix(".log")
  }

  private func decodeImage(data: Data) -> Image? {
    #if canImport(UIKit)
      if let uiImage = UIImage(data: data) {
        return Image(uiImage: uiImage)
      }
      return nil
    #elseif canImport(AppKit)
      if let nsImage = NSImage(data: data) {
        return Image(nsImage: nsImage)
      }
      return nil
    #else
      return nil
    #endif
  }
}

// MARK: - StoragePreviewKind

private enum StoragePreviewKind: Sendable, Equatable {
  case text
  case image
  case video
  case unsupported

  init(path: String, contentType: String? = nil) {
    if let contentType = contentType?.lowercased() {
      if contentType.hasPrefix("text/") {
        self = .text
        return
      }

      if contentType.hasPrefix("image/") {
        self = .image
        return
      }

      if contentType.hasPrefix("video/") {
        self = .video
        return
      }
    }

    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    switch ext {
    case "txt", "md", "json", "csv", "log":
      self = .text
    case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp":
      self = .image
    case "mov", "mp4", "m4v":
      self = .video
    default:
      self = .unsupported
    }
  }
}

// MARK: - StorageDemoLimits

private enum StorageDemoLimits {
  static let maxTextBytes: Int64 = 1 * 1024 * 1024
  static let maxImageBytes: Int64 = 10 * 1024 * 1024
  static let maxVideoBytes: Int64 = 25 * 1024 * 1024

  static func maxBytes(for kind: StoragePreviewKind) -> Int64? {
    switch kind {
    case .text:
      return maxTextBytes
    case .image:
      return maxImageBytes
    case .video:
      return maxVideoBytes
    case .unsupported:
      return nil
    }
  }
}

// MARK: - StorageSignedFilePreviewView

private struct StorageSignedFilePreviewView: View {
  let path: String
  let signedURL: URL?
  let downloadedData: Data?

  private var kind: StoragePreviewKind {
    StoragePreviewKind(path: path)
  }

  var body: some View {
    switch kind {
    case .text:
      if let downloadedData {
        StorageFilePreviewView(path: path, data: downloadedData)
      } else {
        Text("Tap \"Download Preview\" to render this text file in-app.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

    case .image:
      if let signedURL {
        if #available(iOS 15.0, macOS 12.0, *) {
          AsyncImage(url: signedURL) { phase in
            switch phase {
            case .empty:
              HStack(spacing: 8) {
                ProgressView()
                Text("Loading image…")
              }

            case .success(let image):
              image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)

            case .failure:
              Text("Failed to load image preview.")
                .font(.caption)
                .foregroundStyle(.secondary)

            @unknown default:
              Text("Unsupported image preview state.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        } else {
          Text("Image preview requires AsyncImage (iOS 15+/macOS 12+).")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        Text("Generate a signed URL to preview this image.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

    case .video:
      #if canImport(AVKit)
        if let signedURL {
          VideoPlayer(player: AVPlayer(url: signedURL))
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
          Text("Generate a signed URL to preview this video.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      #else
        Text("Video preview requires AVKit.")
          .font(.caption)
          .foregroundStyle(.secondary)
      #endif

    case .unsupported:
      Text("This demo previews text, image, and video files.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - RemoteFilePreviewView

private struct RemoteFilePreviewView: View {
  let path: String
  @ObservedObject var storage: InstantStorage

  @State private var signedURL: URL?
  @State private var downloadedData: Data?
  @State private var errorMessage: String?
  @State private var isLoading = false

  private var kind: StoragePreviewKind {
    StoragePreviewKind(path: path)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if isLoading {
        HStack(spacing: 8) {
          ProgressView()
          Text("Preparing preview…")
        }
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }

      if let signedURL {
        SwiftUI.Link(destination: signedURL) {
          Label("Open Signed URL", systemImage: "arrow.up.right.square")
        }
      }

      StorageSignedFilePreviewView(
        path: path,
        signedURL: signedURL,
        downloadedData: downloadedData
      )

      Button {
        Task { @MainActor in
          await refresh()
        }
      } label: {
        Label("Reload Preview", systemImage: "arrow.clockwise")
      }
      .disabled(isLoading)
    }
    .task(id: path) {
      await refresh()
    }
  }

  @MainActor
  private func refresh() async {
    isLoading = true
    errorMessage = nil
    downloadedData = nil
    signedURL = nil

    do {
      let link = try await storage.link(path: path)
      signedURL = link.url

      if kind == .text {
        let (data, _) = try await URLSession.shared.data(from: link.url)
        downloadedData = data
      }
    } catch {
      errorMessage = error.localizedDescription
    }

    isLoading = false
  }
}

// MARK: - LocalFilePreviewView

private struct LocalFilePreviewView: View {
  let file: LocalFile

  var body: some View {
    switch file.kind {
    case .text:
      StorageFilePreviewView(path: file.displayName, data: file.data)

    case .image:
      if let image = decodeImage(data: file.data) {
        image
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity)
      } else {
        Text("Could not decode image preview.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

    case .video:
      #if canImport(AVKit)
        if let previewURL = file.previewURL {
          VideoPlayer(player: AVPlayer(url: previewURL))
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
          Text("Video preview is unavailable for this selection.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      #else
        Text("Video preview requires AVKit.")
          .font(.caption)
          .foregroundStyle(.secondary)
      #endif

    case .unsupported:
      Text("This demo supports text, image, and video previews.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func decodeImage(data: Data) -> Image? {
    #if canImport(UIKit)
      if let uiImage = UIImage(data: data) {
        return Image(uiImage: uiImage)
      }
      return nil
    #elseif canImport(AppKit)
      if let nsImage = NSImage(data: data) {
        return Image(nsImage: nsImage)
      }
      return nil
    #else
      return nil
    #endif
  }
}

// MARK: - LocalFile

private struct LocalFile: Sendable, Equatable {
  let displayName: String
  let data: Data
  let contentType: String?
  let sizeBytes: Int64
  let kind: StoragePreviewKind
  let previewURL: URL?

  var kindLabel: String {
    switch kind {
    case .text:
      return "Text"
    case .image:
      return "Image"
    case .video:
      return "Video"
    case .unsupported:
      return "Unsupported"
    }
  }

  static func load(from url: URL) throws -> LocalFile {
    let needsAccess = url.startAccessingSecurityScopedResource()
    defer {
      if needsAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let type = UTType(filenameExtension: url.pathExtension)
    let contentType = type?.preferredMIMEType
    let kind = StoragePreviewKind(path: url.lastPathComponent, contentType: contentType)

    guard kind != .unsupported else {
      throw LocalFileLoadError.unsupportedType(filename: url.lastPathComponent)
    }

    let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
    let reportedSize = resourceValues?.fileSize.map(Int64.init)
    let sizeBytes = reportedSize ?? 0

    if let maxBytes = StorageDemoLimits.maxBytes(for: kind), sizeBytes > maxBytes {
      throw LocalFileLoadError.fileTooLarge(
        filename: url.lastPathComponent,
        sizeBytes: sizeBytes,
        maxBytes: maxBytes
      )
    }

    let data = try Data(contentsOf: url)
    if let maxBytes = StorageDemoLimits.maxBytes(for: kind), Int64(data.count) > maxBytes {
      throw LocalFileLoadError.fileTooLarge(
        filename: url.lastPathComponent,
        sizeBytes: Int64(data.count),
        maxBytes: maxBytes
      )
    }

    let previewURL: URL?
    if kind == .video {
      let filename = UUID().uuidString.lowercased()
      let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
      let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(filename)
        .appendingPathExtension(ext)
      try data.write(to: tempURL, options: [.atomic])
      previewURL = tempURL
    } else {
      previewURL = nil
    }

    return LocalFile(
      displayName: url.lastPathComponent,
      data: data,
      contentType: contentType,
      sizeBytes: Int64(data.count),
      kind: kind,
      previewURL: previewURL
    )
  }

  #if os(iOS) && canImport(PhotosUI)
    static func load(from item: PhotosPickerItem) async throws -> LocalFile {
      let supportedTypes = item.supportedContentTypes
      let type = supportedTypes.first(where: { $0.conforms(to: .movie) })
        ?? supportedTypes.first(where: { $0.conforms(to: .video) })
        ?? supportedTypes.first(where: { $0.conforms(to: .image) })
        ?? supportedTypes.first
        ?? .item

      let kind = StoragePreviewKind(path: "media", contentType: type.preferredMIMEType)

      guard kind != .unsupported else {
        throw LocalFileLoadError.unsupportedType(filename: "Selected media")
      }

      let ext = type.preferredFilenameExtension
      let filename = "media-\(UUID().uuidString.lowercased()).\(ext ?? "bin")"
      let contentType = type.preferredMIMEType

      if kind == .video {
        let fileURL = try await item.loadFileURL(for: type)

        let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        let sizeBytes = Int64(resourceValues?.fileSize ?? 0)

        if let maxBytes = StorageDemoLimits.maxBytes(for: kind), sizeBytes > maxBytes {
          try? FileManager.default.removeItem(at: fileURL)
          throw LocalFileLoadError.fileTooLarge(filename: filename, sizeBytes: sizeBytes, maxBytes: maxBytes)
        }

        let data = try Data(contentsOf: fileURL)
        let loadedSizeBytes = Int64(data.count)
        if let maxBytes = StorageDemoLimits.maxBytes(for: kind), loadedSizeBytes > maxBytes {
          try? FileManager.default.removeItem(at: fileURL)
          throw LocalFileLoadError.fileTooLarge(filename: filename, sizeBytes: loadedSizeBytes, maxBytes: maxBytes)
        }

        return LocalFile(
          displayName: filename,
          data: data,
          contentType: contentType,
          sizeBytes: loadedSizeBytes,
          kind: kind,
          previewURL: fileURL
        )
      }

      let data = try await item.loadData(for: type)

      let sizeBytes = Int64(data.count)
      if let maxBytes = StorageDemoLimits.maxBytes(for: kind), sizeBytes > maxBytes {
        throw LocalFileLoadError.fileTooLarge(filename: filename, sizeBytes: sizeBytes, maxBytes: maxBytes)
      }

      return LocalFile(
        displayName: filename,
        data: data,
        contentType: contentType,
        sizeBytes: sizeBytes,
        kind: kind,
        previewURL: nil
      )
    }
  #endif
}

// MARK: - LocalFileLoadError

private enum LocalFileLoadError: LocalizedError {
  case unsupportedType(filename: String)
  case fileTooLarge(filename: String, sizeBytes: Int64, maxBytes: Int64)
  case failedToLoadFromPhotos

  var errorDescription: String? {
    switch self {
    case .unsupportedType(let filename):
      return """
      Unsupported file type: \(filename)

      WHAT HAPPENED:
        This CaseStudy currently supports text, image, and video uploads only.

      WHY THIS EXISTS:
        The demo also renders in-app previews, and we keep the supported surface
        area intentionally small while we iterate on the storage API ergonomics.

      HOW TO FIX:
        Pick a .txt/.md/.json file, an image (png/jpg/heic), or a video (mov/mp4).
      """

    case .fileTooLarge(let filename, let sizeBytes, let maxBytes):
      let sizeString = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
      let maxString = ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)
      return """
      File is too large for this CaseStudy: \(filename)

      WHAT HAPPENED:
        The selected file is \(sizeString), but this demo caps uploads at \(maxString).

      WHY THIS EXISTS:
        This demo loads files into memory to provide simple previews. Large media files
        can make the CaseStudy slow or unstable on devices.

      HOW TO FIX:
        Pick a smaller file, or adjust the size limits in StorageDemo.swift.
      """

    case .failedToLoadFromPhotos:
      return """
      Failed to load the selected photo/video.

      WHAT HAPPENED:
        PhotosPicker returned an item, but the app could not load its bytes.

      WHY THIS HAPPENS:
        The Photos library may still be downloading the media, the item may be in an
        unsupported representation, or the OS denied access.

      HOW TO FIX:
        Try selecting a different item, or try again after the media has fully downloaded.
      """
    }
  }
}

// MARK: - PhotosPicker Helpers (iOS)

#if os(iOS) && canImport(PhotosUI)
  /// A Transferable type that loads video data as a file URL.
  ///
  /// ## Why This Exists
  /// PhotosPickerItem.loadTransferable(type:) works well for images using Data.self,
  /// but videos require file-based transfer to avoid loading large files entirely into memory.
  /// This type uses SentTransferredFile to receive the video as a temporary file URL.
  private struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
      FileRepresentation(contentType: .movie) { video in
        SentTransferredFile(video.url)
      } importing: { received in
        // Copy to a stable temp location since the received file may be deleted
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
    func loadData(for type: UTType) async throws -> Data {
      // Use loadTransferable with Data.self for images
      guard let data = try await loadTransferable(type: Data.self) else {
        throw LocalFileLoadError.failedToLoadFromPhotos
      }
      return data
    }

    func loadFileURL(for type: UTType) async throws -> URL {
      // Use the VideoTransferable type for videos to get a file URL
      guard let video = try await loadTransferable(type: VideoTransferable.self) else {
        throw LocalFileLoadError.failedToLoadFromPhotos
      }
      return video.url
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
