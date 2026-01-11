/// MemoryMonitor.swift
///
/// Programmatic memory monitoring for debugging memory issues without Instruments.
///
/// ## Usage
/// Add `MemoryMonitorView()` to your app to see live memory stats,
/// or use `MemoryMonitor.shared` directly to log memory usage.

import Foundation
import SwiftUI
import os

// MARK: - Memory Monitor

/// A singleton that tracks memory usage programmatically.
@MainActor
@Observable
public final class MemoryMonitor {
  public static let shared = MemoryMonitor()

  /// Current memory usage in bytes
  public private(set) var currentMemoryBytes: UInt64 = 0

  /// Peak memory usage observed in bytes
  public private(set) var peakMemoryBytes: UInt64 = 0

  /// Memory limit before iOS kills the app (approximate)
  public var memoryLimitBytes: UInt64 {
    // Get device physical memory
    ProcessInfo.processInfo.physicalMemory
  }

  /// Percentage of memory limit used
  public var usagePercentage: Double {
    guard memoryLimitBytes > 0 else { return 0 }
    return Double(currentMemoryBytes) / Double(memoryLimitBytes) * 100
  }

  /// Timer for periodic sampling
  private var timer: Timer?

  /// History of memory samples (time, bytes)
  public private(set) var history: [(Date, UInt64)] = []

  /// Maximum history entries to keep
  public var maxHistoryEntries: Int = 100

  private init() {}

  // MARK: - Public API

  /// Starts monitoring memory at the given interval.
  public func startMonitoring(interval: TimeInterval = 1.0) {
    stopMonitoring()

    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.sample()
      }
    }

    // Take initial sample
    sample()
  }

  /// Stops memory monitoring.
  public func stopMonitoring() {
    timer?.invalidate()
    timer = nil
  }

  /// Takes a single memory sample.
  public func sample() {
    currentMemoryBytes = getResidentMemory()

    if currentMemoryBytes > peakMemoryBytes {
      peakMemoryBytes = currentMemoryBytes
    }

    // Add to history
    history.append((Date(), currentMemoryBytes))

    // Trim history if needed
    if history.count > maxHistoryEntries {
      history.removeFirst(history.count - maxHistoryEntries)
    }
  }

  /// Logs current memory usage to the console.
  public func logMemoryUsage(label: String = "Memory") {
    let current = formatBytes(currentMemoryBytes)
    let peak = formatBytes(peakMemoryBytes)
    let limit = formatBytes(memoryLimitBytes)

    os_log("[%{public}@] Current: %{public}@ | Peak: %{public}@ | Limit: %{public}@ | Usage: %.1f%%",
           log: .default, type: .info,
           label, current, peak, limit, usagePercentage)
  }

  /// Resets peak memory tracking.
  public func resetPeak() {
    peakMemoryBytes = currentMemoryBytes
    history.removeAll()
  }

  // MARK: - Memory Reading

  /// Gets the current resident memory size using task_info.
  private func getResidentMemory() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }

    guard result == KERN_SUCCESS else {
      return 0
    }

    return info.resident_size
  }

  // MARK: - Formatting

  /// Formats bytes into human-readable string (KB, MB, GB).
  public func formatBytes(_ bytes: UInt64) -> String {
    let kb = Double(bytes) / 1024
    let mb = kb / 1024
    let gb = mb / 1024

    if gb >= 1 {
      return String(format: "%.2f GB", gb)
    } else if mb >= 1 {
      return String(format: "%.1f MB", mb)
    } else {
      return String(format: "%.0f KB", kb)
    }
  }
}

// MARK: - SwiftUI View

/// A debug overlay showing live memory stats.
public struct MemoryMonitorView: View {
  @State private var monitor = MemoryMonitor.shared
  @State private var isExpanded = false

  public init() {}

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: "memorychip")
        Text(monitor.formatBytes(monitor.currentMemoryBytes))
          .font(.system(.caption, design: .monospaced))

        Spacer()

        Button {
          isExpanded.toggle()
        } label: {
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
        }
        .buttonStyle(.plain)
      }

      if isExpanded {
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text("Peak:")
            Spacer()
            Text(monitor.formatBytes(monitor.peakMemoryBytes))
          }

          HStack {
            Text("Usage:")
            Spacer()
            Text(String(format: "%.1f%%", monitor.usagePercentage))
          }

          // Memory bar
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Rectangle()
                .fill(Color.gray.opacity(0.3))

              Rectangle()
                .fill(usageColor)
                .frame(width: geo.size.width * CGFloat(monitor.usagePercentage / 100))
            }
            .cornerRadius(4)
          }
          .frame(height: 8)

          Button("Reset Peak") {
            monitor.resetPeak()
          }
          .font(.caption)
        }
        .font(.system(.caption2, design: .monospaced))
      }
    }
    .padding(8)
    .background(.ultraThinMaterial)
    .cornerRadius(8)
    .onAppear {
      monitor.startMonitoring()
    }
    .onDisappear {
      monitor.stopMonitoring()
    }
  }

  private var usageColor: Color {
    if monitor.usagePercentage > 80 {
      return .red
    } else if monitor.usagePercentage > 50 {
      return .orange
    } else {
      return .green
    }
  }
}

// MARK: - Memory Spike Detection

extension MemoryMonitor {
  /// Checks if memory has grown significantly since last sample.
  /// Useful for detecting leaks.
  public func checkForMemorySpike(threshold: Double = 0.2) -> Bool {
    guard history.count >= 2 else { return false }

    let previous = history[history.count - 2].1
    let current = history[history.count - 1].1

    guard previous > 0 else { return false }

    let growth = Double(current - previous) / Double(previous)
    return growth > threshold
  }

  /// Returns the memory growth rate per second over the recent history.
  public func memoryGrowthRatePerSecond() -> Double? {
    guard history.count >= 2 else { return nil }

    let first = history.first!
    let last = history.last!

    let timeDelta = last.0.timeIntervalSince(first.0)
    guard timeDelta > 0 else { return nil }

    let memoryDelta = Double(last.1) - Double(first.1)
    return memoryDelta / timeDelta
  }
}
