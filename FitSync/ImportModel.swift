import Foundation
import HealthKit
import Observation

@MainActor
@Observable
final class ImportModel {
    enum State: Equatable {
        case idle
        case loaded
        case saving
        case saved
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var fileName: String?
    /// The activity as parsed from the file.
    private(set) var activity: FITActivity?
    private(set) var overlapping: [String] = []

    /// A user-chosen start time that replaces the file's, shifting the whole activity.
    var startOverride: Date? {
        didSet { Task { await checkForOverlaps() } }
    }

    /// The activity that will be saved: the parsed one, moved to `startOverride` if set.
    var effectiveActivity: FITActivity? {
        guard let activity else { return nil }
        guard let startOverride, let start = activity.startDate else { return activity }
        return activity.shifted(by: startOverride.timeIntervalSince(start))
    }

    private let writer = HealthWriter()

    func load(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        fileName = url.lastPathComponent
        overlapping = []
        startOverride = nil
        do {
            let data = try Data(contentsOf: url)
            let parsed = try FITParser.parse(data)
            guard parsed.startDate != nil, !parsed.records.isEmpty else {
                throw ImportError.empty
            }
            activity = parsed
            state = .loaded
        } catch {
            activity = nil
            state = .failed(error.localizedDescription)
        }

        // Files opened from other apps are copied into Documents/Inbox; don't keep them.
        if url.path.contains("/Documents/Inbox/") {
            try? FileManager.default.removeItem(at: url)
        }

        if activity != nil {
            Task { await checkForOverlaps() }
        }
    }

    func save() async {
        guard let activity = effectiveActivity else { return }
        state = .saving
        do {
            try await writer.requestAuthorization()
            _ = try await writer.save(activity)
            state = .saved
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func reset() {
        state = .idle
        fileName = nil
        activity = nil
        overlapping = []
        startOverride = nil
    }

    private func checkForOverlaps() async {
        guard HealthWriter.isAvailable, let start = effectiveActivity?.startDate, let end = effectiveActivity?.endDate else {
            overlapping = []
            return
        }
        try? await writer.requestAuthorization()
        overlapping = await writer.overlappingWorkouts(start: start, end: end)
    }
}

enum ImportError: LocalizedError {
    case empty

    var errorDescription: String? {
        switch self {
        case .empty: "This .fit file has no activity records."
        }
    }
}
