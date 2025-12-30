#if canImport(SwiftUI)
  import SwiftUI

  #if canImport(AVKit)
    import AVKit
  #endif

  #if canImport(AppKit)
    import AppKit
  #endif

  #if canImport(UIKit)
    import UIKit
  #endif

  // MARK: - StorageMediaView

  /// Renders a storage item preview (text/image/video) using either a local preview or the
  /// server-provided `$files.url`.
  ///
  /// ## Why This Exists
  /// Storage UIs often devolve into "state soup" where each view tracks:
  /// - whether an upload is in flight,
  /// - the local preview to show while waiting,
  /// - the server URL when ready,
  /// - and failure/retry UI.
  ///
  /// SharingInstant's storage primitives (`StorageItem` + `StorageStatus`) centralize those
  /// concerns. This view focuses purely on rendering.
  public struct StorageMediaView: View {
    public let item: StorageItem

    public init(item: StorageItem) {
      self.item = item
    }

    public var body: some View {
      ZStack(alignment: .topTrailing) {
        media
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()

        StorageStatusBadge(status: item.status)
          .padding(8)
      }
    }

    @ViewBuilder
    private var media: some View {
      switch item.ref.kind {
      case .image:
        StorageImageView(item: item)
      case .video:
        StorageVideoView(item: item)
      case .text:
        StorageTextView(item: item)
      case .binary:
        StorageBinaryPlaceholder(item: item)
      }
    }
  }

  // MARK: - StorageStatusBadge

  public struct StorageStatusBadge: View {
    public let status: StorageStatus

    public init(status: StorageStatus) {
      self.status = status
    }

    public var body: some View {
      Group {
        switch status {
        case .idle, .uploaded:
          EmptyView()
        case .queued, .uploading:
          ProgressView()
            .progressViewStyle(.circular)
            .padding(8)
            .background(.ultraThinMaterial)
            .clipShape(Circle())
        case .deleting:
          Image(systemName: "trash")
            .font(.caption.weight(.semibold))
            .padding(8)
            .background(.ultraThinMaterial)
            .clipShape(Circle())
        case .deleted:
          Image(systemName: "checkmark")
            .font(.caption.weight(.semibold))
            .padding(8)
            .background(.ultraThinMaterial)
            .clipShape(Circle())
        case .failed:
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.yellow)
            .padding(8)
            .background(.ultraThinMaterial)
            .clipShape(Circle())
        }
      }
      .accessibilityHidden(status == .idle || status == .uploaded)
    }
  }

  // MARK: - Image

  private struct StorageImageView: View {
    let item: StorageItem

    var body: some View {
      if let localURL = item.localPreview?.fileURL, let image = decodeImage(fileURL: localURL) {
        image
          .resizable()
          .scaledToFill()
      } else if let remoteURL = item.url {
        AsyncImage(url: remoteURL) { phase in
          switch phase {
          case .empty:
            ZStack {
              Color.secondary.opacity(0.12)
              ProgressView()
            }
          case .success(let image):
            image
              .resizable()
              .scaledToFill()
          case .failure:
            StorageBinaryPlaceholder(item: item)
          @unknown default:
            StorageBinaryPlaceholder(item: item)
          }
        }
      } else {
        StorageBinaryPlaceholder(item: item)
      }
    }

    private func decodeImage(fileURL: URL) -> Image? {
      #if canImport(UIKit)
        if let uiImage = UIImage(contentsOfFile: fileURL.path) {
          return Image(uiImage: uiImage)
        }
        return nil
      #elseif canImport(AppKit)
        if let nsImage = NSImage(contentsOfFile: fileURL.path) {
          return Image(nsImage: nsImage)
        }
        return nil
      #else
        return nil
      #endif
    }
  }

  // MARK: - Video

  private struct StorageVideoView: View {
    let item: StorageItem

    var body: some View {
      #if canImport(AVKit)
        if let localURL = item.localPreview?.fileURL {
          VideoPlayer(player: AVPlayer(url: localURL))
        } else if let remoteURL = item.url {
          VideoPlayer(player: AVPlayer(url: remoteURL))
        } else {
          StorageBinaryPlaceholder(item: item)
        }
      #else
        StorageBinaryPlaceholder(item: item)
      #endif
    }
  }

  // MARK: - Text

  private struct StorageTextView: View {
    let item: StorageItem

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        Text(item.ref.displayName ?? URL(fileURLWithPath: item.ref.path).lastPathComponent)
          .font(.headline)

        if let localURL = item.localPreview?.fileURL,
           let data = try? Data(contentsOf: localURL),
           let string = String(data: data, encoding: .utf8) {
          Text(string.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.system(.subheadline, design: .monospaced))
            .lineLimit(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let remoteURL = item.url {
          Link(destination: remoteURL) {
            Label("Open file", systemImage: "arrow.up.right.square")
              .font(.subheadline)
          }
        } else {
          Text("No preview available.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.secondary.opacity(0.06))
    }
  }

  // MARK: - Binary Placeholder

  private struct StorageBinaryPlaceholder: View {
    let item: StorageItem

    var body: some View {
      ZStack {
        Color.secondary.opacity(0.12)
        VStack(spacing: 8) {
          Image(systemName: "doc")
            .font(.system(size: 28, weight: .semibold))
          Text(item.ref.displayName ?? URL(fileURLWithPath: item.ref.path).lastPathComponent)
            .font(.caption)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
        }
        .padding(16)
      }
    }
  }
#endif

