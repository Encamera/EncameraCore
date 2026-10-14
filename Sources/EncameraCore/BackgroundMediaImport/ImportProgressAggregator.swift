import Foundation

/// Folds the progress of every item in an import into one fraction for the
/// whole import, and decides which changes are worth publishing.
///
/// Items imported concurrently each contribute their own fraction, so the
/// total is the sum of what has finished plus what is in flight, not whichever
/// item reported last. An item's fraction never moves backwards, and updates
/// that arrive after it finished are ignored: encryptors report from other
/// queues, so a late update can land after the item's save returned.
///
/// Encryptors report every block, thousands of times per file. Publishing all
/// of them floods the main thread, so a change is only published once it moves
/// the total by `minimumStep` or `minimumInterval` has passed since the last.
@MainActor
final class ImportProgressAggregator {
    private let totalItems: Int
    private let minimumStep: Double
    private let minimumInterval: TimeInterval
    private let now: () -> Date

    private var inFlight: [Int: Double] = [:]
    private var finished = Set<Int>()
    private var lastPublishedFraction: Double?
    private var lastPublishedAt: Date?

    init(totalItems: Int,
         minimumStep: Double = 0.005,
         minimumInterval: TimeInterval = 0.1,
         now: @escaping () -> Date = Date.init) {
        self.totalItems = totalItems
        self.minimumStep = minimumStep
        self.minimumInterval = minimumInterval
        self.now = now
    }

    /// The import's overall fraction, 0...1.
    var fraction: Double {
        guard totalItems > 0 else { return 1.0 }
        let total = Double(finished.count) + inFlight.values.reduce(0, +)
        return min(1.0, total / Double(totalItems))
    }

    /// The fraction recorded for one item.
    func fraction(ofItem index: Int) -> Double {
        finished.contains(index) ? 1.0 : inFlight[index] ?? 0.0
    }

    /// Records an item's progress. Returns whether the change should be published.
    func update(item index: Int, fraction itemFraction: Double) -> Bool {
        guard !finished.contains(index) else { return false }
        let clamped = min(max(itemFraction, 0.0), 1.0)
        guard clamped > inFlight[index] ?? 0.0 else { return false }
        inFlight[index] = clamped
        return shouldPublish(force: false)
    }

    /// Marks an item done, whether it imported or failed. Always publishes the
    /// first time, so the total lands on each item boundary.
    @discardableResult
    func finish(item index: Int) -> Bool {
        guard !finished.contains(index) else { return false }
        inFlight[index] = nil
        finished.insert(index)
        return shouldPublish(force: true)
    }

    private func shouldPublish(force: Bool) -> Bool {
        let current = fraction
        let date = now()
        if !force, let lastFraction = lastPublishedFraction, let lastAt = lastPublishedAt {
            let movedEnough = current - lastFraction >= minimumStep
            let waitedEnough = date.timeIntervalSince(lastAt) >= minimumInterval
            guard movedEnough || waitedEnough else { return false }
        }
        lastPublishedFraction = current
        lastPublishedAt = date
        return true
    }
}

/// Maps each component's own 0...1 progress onto its share of the whole item,
/// so a Live Photo — a photo and a video saved one after the other — reports
/// one run from 0 to 1 instead of starting over for the video. Shares follow
/// file size, since that is what the encryptors' progress measures; when a size
/// is unknown, every component gets an equal share.
public struct ComponentProgressWeights: Sendable {
    private let starts: [Double]
    private let shares: [Double]

    public init(byteCounts: [Int64?]) {
        let count = byteCounts.count
        let sizes = byteCounts.compactMap { $0 }
        let total = sizes.reduce(0, +)
        let shares: [Double]
        if count == 0 {
            shares = []
        } else if sizes.count == count, total > 0 {
            shares = byteCounts.map { Double($0 ?? 0) / Double(total) }
        } else {
            shares = Array(repeating: 1.0 / Double(count), count: count)
        }
        var running = 0.0
        self.starts = shares.map { share in
            defer { running += share }
            return running
        }
        self.shares = shares
    }

    public init(urls: [URL?]) {
        self.init(byteCounts: urls.map { $0?.fileSizeBytes() })
    }

    /// The whole item's fraction while component `index` is at `fraction`.
    public func overall(component index: Int, fraction: Double) -> Double {
        guard starts.indices.contains(index) else { return min(max(fraction, 0), 1) }
        return min(1.0, starts[index] + shares[index] * min(max(fraction, 0), 1))
    }
}
