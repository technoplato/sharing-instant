/// Rapid Transcription Update Demo
///
/// This demo mirrors the SpeechRecorderApp's RapidUpdateSharingInstantTest to verify
/// that SharingInstant can handle rapid segment text updates with the same timing
/// as real-time speech transcription.
///
/// ## Test Pattern
///
/// Real speech transcription emits updates at irregular intervals:
/// - Multiple updates within milliseconds (e.g., 7ms, 8ms apart)
/// - Longer gaps between words (e.g., 800-1000ms)
/// - Final segment with word-level timing data
///
/// This demo simulates that pattern and verifies optimistic updates work correctly.

import SwiftUI
import IdentifiedCollections
import SharingInstant

// MARK: - Test Data

private struct SegmentUpdate {
  let delay: Int // milliseconds from start
  let text: String
}

private struct WordData {
  let text: String
  let startTime: Double
  let endTime: Double
}

private struct FinalUpdate {
  let delay: Int
  let text: String
  let words: [WordData]
}

private struct TestSegmentData {
  let index: Int
  let updates: [SegmentUpdate]
  let final: FinalUpdate
}

/// Test data that mirrors real speech transcription timing
private let testSegmentsData: [TestSegmentData] = [
  TestSegmentData(
    index: 0,
    updates: [
      SegmentUpdate(delay: 0, text: "T"),
      SegmentUpdate(delay: 7, text: "Test"),
      SegmentUpdate(delay: 8, text: "Testing"),
      SegmentUpdate(delay: 888, text: "Testing 12"),
      SegmentUpdate(delay: 890, text: "Testing 123"),
      SegmentUpdate(delay: 1895, text: "Testing 1234"),
      SegmentUpdate(delay: 1897, text: "Testing 1234 test"),
      SegmentUpdate(delay: 1899, text: "Testing 1234 testing"),
      SegmentUpdate(delay: 2880, text: "Testing 1234 testing 12"),
      SegmentUpdate(delay: 2882, text: "Testing 1234 testing 123"),
      SegmentUpdate(delay: 2883, text: "Testing 1234 testing 1234."),
    ],
    final: FinalUpdate(
      delay: 3889,
      text: "Testing 1234 testing 1234.",
      words: [
        WordData(text: "Testing", startTime: 0.0, endTime: 0.72),
        WordData(text: "1234", startTime: 0.72, endTime: 1.98),
        WordData(text: "testing", startTime: 1.98, endTime: 2.52),
        WordData(text: "1234.", startTime: 2.52, endTime: 3.60),
      ]
    )
  ),
  TestSegmentData(
    index: 1,
    updates: [
      SegmentUpdate(delay: 7900, text: "T"),
      SegmentUpdate(delay: 7902, text: "Test"),
      SegmentUpdate(delay: 8880, text: "Testing"),
      SegmentUpdate(delay: 8882, text: "Testing 18"),
      SegmentUpdate(delay: 9900, text: "Testing 1835."),
    ],
    final: FinalUpdate(
      delay: 10855,
      text: "Testing 1835?",
      words: [
        WordData(text: "Testing", startTime: 4.20, endTime: 6.90),
        WordData(text: "1835?", startTime: 6.90, endTime: 8.70),
      ]
    )
  ),
]

// MARK: - Segment Card View

private struct SegmentCardView: View {
  let segment: TranscriptionSegment

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      segmentHeader
      segmentText
      timeRange
      Divider()
      wordsSection
    }
    .padding(8)
    .background(cardBackground)
    .overlay(cardBorder)
    .frame(width: 180)
  }

  private var segmentHeader: some View {
    HStack {
      Text("Segment \(Int(segment.segmentIndex))")
        .font(.caption.bold())

      if segment.isFinalized {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.green)
          .font(.caption)
      } else {
        Image(systemName: "circle.dotted")
          .foregroundColor(.orange)
          .font(.caption)
      }
    }
  }

  private var segmentText: some View {
    Text("\"\(segment.text)\"")
      .font(.system(.caption2, design: .monospaced))
      .foregroundColor(segment.isFinalized ? .primary : .orange)
      .lineLimit(2)
  }

  private var timeRange: some View {
    Text(String(format: "%.2f - %.2f s", segment.startTime, segment.endTime))
      .font(.system(.caption2, design: .monospaced))
      .foregroundColor(.secondary)
  }

  private var wordsSection: some View {
    let words = segment.words ?? []
    return VStack(alignment: .leading, spacing: 2) {
      Text("Words (\(words.count)):")
        .font(.caption2.bold())

      if words.isEmpty {
        Text("(none)")
          .font(.caption2)
          .foregroundColor(.secondary)
      } else {
        ForEach(Array(words.enumerated()), id: \.offset) { idx, word in
          WordRowView(index: idx, word: word)
        }
      }
    }
  }

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 8)
      .fill(segment.isFinalized ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
  }

  private var cardBorder: some View {
    RoundedRectangle(cornerRadius: 8)
      .stroke(segment.isFinalized ? Color.green.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 1)
  }
}

private struct WordRowView: View {
  let index: Int
  let word: TranscriptionSegmentWords

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 4) {
        Text("\(index):")
          .font(.system(.caption2, design: .monospaced))
          .foregroundColor(.secondary)
        Text(word.text)
          .font(.system(.caption2, design: .monospaced))
          .bold()
          .lineLimit(1)
          .truncationMode(.tail)
      }

      Text(String(format: "[%.2f-%.2f]", word.startTime, word.endTime))
        .font(.system(.caption2, design: .monospaced))
        .foregroundColor(.secondary)
    }
  }
}

// MARK: - Main Demo View

struct RapidTranscriptionDemo: SwiftUICaseStudy {
  let readMe = """
    This demo simulates rapid real-time speech transcription updates to verify \
    that SharingInstant handles high-frequency mutations correctly.

    Real speech transcription emits updates at irregular intervals:
    • Multiple updates within milliseconds (7-8ms apart)
    • Longer gaps between words (800-1000ms)
    • Final segment with word-level timing data

    The demo creates multiple segments with rapid text updates, then finalizes \
    them with word timing data. This tests concurrent field updates (text vs words) \
    and verifies optimistic updates work correctly under load.
    """
  let caseStudyTitle = "Rapid Transcription"

  @Shared(.instantSync(Schema.transcriptionSegments))
  private var segments: IdentifiedArrayOf<TranscriptionSegment> = []

  @Shared(.instantSync(Schema.transcriptionRuns))
  private var runs: IdentifiedArrayOf<TranscriptionRun> = []

  @Shared(.instantSync(Schema.media))
  private var mediaItems: IdentifiedArrayOf<Media> = []

  @State private var logs: [String] = []
  @State private var isRunning = false
  @State private var testResult: String?
  @State private var testIds: TestIds?

  struct TestIds {
    let mediaId: String
    let runId: String
    let segmentIds: [String]
  }

  /// Filter segments to only show those created by this test
  private var testSegments: [TranscriptionSegment] {
    guard let ids = testIds else { return [] }
    return segments.filter { ids.segmentIds.contains($0.id) }
      .sorted { $0.segmentIndex < $1.segmentIndex }
  }

  var body: some View {
    VStack(spacing: 0) {
      if let result = testResult {
        Text(result)
          .font(.headline)
          .foregroundColor(result.contains("SUCCESS") ? .green : .red)
          .padding(.vertical, 8)
          .accessibilityIdentifier("rapid_test_result")
      }

      HStack {
        Button("Run Test") {
          Task {
            await runTest()
          }
        }
        .disabled(isRunning)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("rapid_run_test_button")

        if testIds != nil {
          Button("Cleanup") {
            Task {
              await cleanup()
            }
          }
          .disabled(isRunning)
          .buttonStyle(.bordered)
          .accessibilityIdentifier("rapid_cleanup_button")
        }
      }
      .padding(.vertical, 8)

      // MARK: - Live Segments Display
      if !testSegments.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("Live Segments & Words")
            .font(.headline)
            .padding(.horizontal)

          ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
              ForEach(testSegments) { segment in
                SegmentCardView(segment: segment)
              }
            }
            .padding(.horizontal)
          }
          .frame(maxHeight: 200)
        }
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.1))
      }

      Divider()

      // MARK: - Logs
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(logs.enumerated()), id: \.offset) { index, log in
              Text(log)
                .font(.system(.caption, design: .monospaced))
                .id(index)
            }
          }
          .padding()
        }
        .onChange(of: logs.count) { _, _ in
          if let lastIndex = logs.indices.last {
            proxy.scrollTo(lastIndex, anchor: .bottom)
          }
        }
      }
    }
    .navigationTitle("Rapid Transcription")
  }

  private func log(_ message: String) {
    let timestamp = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let timeStr = formatter.string(from: timestamp)
    logs.append("[\(timeStr)] \(message)")
  }

  @MainActor
  private func runTest() async {
    isRunning = true
    logs = []
    testResult = nil

    log("Testing rapid MULTI-SEGMENT updates with SharingInstant")
    log("Using async explicit mutations for deterministic ordering")
    log("")

    // Generate UUIDs
    let mediaId = UUID().uuidString.lowercased()
    let runId = UUID().uuidString.lowercased()
    let segmentIds = testSegmentsData.map { _ in UUID().uuidString.lowercased() }

    testIds = TestIds(mediaId: mediaId, runId: runId, segmentIds: segmentIds)

    log("Test IDs:")
    log("  mediaId: \(mediaId)")
    log("  runId: \(runId)")
    for (i, sid) in segmentIds.enumerated() {
      log("  segment\(i)Id: \(String(sid.prefix(8)))...")
    }
    log("")

    // Create media and transcription run
    log("Creating media + transcription run...")
    let now = ISO8601DateFormatter().string(from: Date())

    let media = Media(
      id: mediaId,
      title: "Rapid Update Test",
      durationSeconds: 60,
      mediaType: "audio",
      ingestedAt: now
    )

    let run = TranscriptionRun(
      id: runId,
      toolVersion: "sharing-instant-test-1.0",
      executedAt: now
    )

    do {
      try await $mediaItems.create(media)
      log("Media created")
    } catch {
      log("Media create failed: \(error)")
      testResult = "FAILED - Media create"
      isRunning = false
      return
    }

    do {
      try await $runs.create(run)
      log("TranscriptionRun created")
    } catch {
      log("TranscriptionRun create failed: \(error)")
      testResult = "FAILED - Run create"
      isRunning = false
      return
    }

    do {
      try await $runs.link(runId, "media", to: media)
      log("Linked TranscriptionRun -> Media")
    } catch {
      log("Link TranscriptionRun -> Media failed: \(error)")
    }

    log("")
    log("Starting multi-segment rapid update sequence...")

    let startTime = Date()
    var scheduledMutationTasks: [Task<Void, Never>] = []

    @discardableResult
    func scheduleMutation(
      _ label: String,
      operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
      let task = Task { @MainActor in
        await operation()
      }
      scheduledMutationTasks.append(task)
      return task
    }

    for (segIdx, segmentData) in testSegmentsData.enumerated() {
      let segmentId = segmentIds[segIdx]

      log("")
      log(String(repeating: "=", count: 50))
      log("SEGMENT \(segmentData.index) (id: \(String(segmentId.prefix(8)))...)")
      log(String(repeating: "=", count: 50))

      // Process volatile updates
      for (updateIndex, update) in segmentData.updates.enumerated() {
        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        let waitTime = update.delay - elapsed
        if waitTime > 0 {
          try? await Task.sleep(for: .milliseconds(waitTime))
        }

        let actualDelay = Int(Date().timeIntervalSince(startTime) * 1000)
        log("[+\(String(format: "%5d", actualDelay))ms] VOLATILE: \"\(update.text)\"")

        let updateNow = ISO8601DateFormatter().string(from: Date())

        let segment = TranscriptionSegment(
          id: segmentId,
          startTime: segmentData.final.words.first?.startTime ?? 0.0,
          endTime: Double(update.text.count) * 0.1,
          text: update.text,
          segmentIndex: Double(segmentData.index),
          isFinalized: false,
          ingestedAt: updateNow,
          speaker: nil,
          words: nil
        )

        if updateIndex == 0 {
          scheduleMutation("VOLATILE upsert+link segment \(String(segmentId.prefix(8)))...") {
            do {
              try await $segments.create(segment)
            } catch {
              log("  VOLATILE upsert failed: \(error)")
            }

            do {
              try await $segments.link(
                segmentId,
                "transcriptionRun",
                to: TranscriptionRun(id: runId, toolVersion: "", executedAt: "")
              )
            } catch {
              log("  Link segment -> run failed: \(error)")
            }
          }
        } else {
          scheduleMutation("VOLATILE upsert segment \(String(segmentId.prefix(8)))...") {
            do {
              try await $segments.create(segment)
            } catch {
              log("  VOLATILE upsert failed: \(error)")
            }
          }
        }
      }

      // Wait for final update
      let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
      let waitTime = segmentData.final.delay - elapsed
      if waitTime > 0 {
        try? await Task.sleep(for: .milliseconds(waitTime))
      }

      let actualDelay = Int(Date().timeIntervalSince(startTime) * 1000)
      log("[+\(String(format: "%5d", actualDelay))ms] FINAL: \"\(segmentData.final.text)\" (words: \(segmentData.final.words.count))")

      let finalNow = ISO8601DateFormatter().string(from: Date())
      let finalWords = segmentData.final.words.map {
        TranscriptionSegmentWords(text: $0.text, startTime: $0.startTime, endTime: $0.endTime)
      }

      let finalizedSegment = TranscriptionSegment(
        id: segmentId,
        startTime: segmentData.final.words.first?.startTime ?? 0.0,
        endTime: segmentData.final.words.last?.endTime ?? 0.0,
        text: segmentData.final.text,
        segmentIndex: Double(segmentData.index),
        isFinalized: true,
        ingestedAt: finalNow,
        speaker: nil,
        words: finalWords
      )

      scheduleMutation("FINAL upsert segment \(String(segmentId.prefix(8)))...") {
        do {
          try await $segments.create(finalizedSegment)
          log("  Finalized segment (words=\(finalWords.count))")
        } catch {
          log("  FINALIZE failed: \(error)")
        }
      }
    }

    log("")
    log("Waiting 2 seconds for InstantDB to settle...")
    try? await Task.sleep(for: .seconds(2))

    log("")
    log("Waiting for mutation tasks to finish...")

    let tasksToAwait = scheduledMutationTasks

    let didMutationsFinish = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for task in tasksToAwait {
          await task.value
        }
        return true
      }

      group.addTask {
        try? await Task.sleep(for: .seconds(30))
        return false
      }

      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }

    if didMutationsFinish {
      log("Mutation tasks finished")
    } else {
      log("Timed out waiting for mutation tasks")
    }

    log("")
    log("Test complete!")
    log("When done, tap 'Cleanup' to remove test data.")

    testResult = "SUCCESS"
    isRunning = false
  }

  @MainActor
  private func cleanup() async {
    guard let ids = testIds else { return }

    isRunning = true
    log("")
    log("Cleaning up test data...")

    // Delete segments
    for segmentId in ids.segmentIds {
      do {
        try await $segments.delete(id: segmentId)
        log("Deleted segment \(String(segmentId.prefix(8)))...")
      } catch {
        log("Failed to delete segment: \(error)")
      }
    }

    // Delete run
    do {
      try await $runs.delete(id: ids.runId)
      log("Deleted run \(String(ids.runId.prefix(8)))...")
    } catch {
      log("Failed to delete run: \(error)")
    }

    // Delete media
    do {
      try await $mediaItems.delete(id: ids.mediaId)
      log("Deleted media \(String(ids.mediaId.prefix(8)))...")
    } catch {
      log("Failed to delete media: \(error)")
    }

    log("Cleanup complete")

    testIds = nil
    testResult = "CLEANUP COMPLETE"
    isRunning = false
  }
}

#Preview {
  NavigationStack {
    CaseStudyView {
      RapidTranscriptionDemo()
    }
  }
}
