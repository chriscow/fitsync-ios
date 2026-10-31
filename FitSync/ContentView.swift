import HealthKit
import MapKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let model: ImportModel
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            Group {
                if let activity = model.effectiveActivity {
                    ActivityView(model: model, activity: activity)
                } else {
                    emptyState
                }
            }
            .navigationTitle("FitSync")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Open File", systemImage: "folder") { showingImporter = true }
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.fitFile, .data]) { result in
                if case .success(let url) = result { model.load(url: url) }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Activity", systemImage: "figure.outdoor.cycle")
        } description: {
            if case .failed(let message) = model.state {
                Text(message).foregroundStyle(.red)
            } else {
                Text("Share a .fit file to FitSync from Strava, Wahoo, Garmin or Files, or open one here. It will be saved to Apple Health with its route and heart rate.")
            }
        } actions: {
            Button("Open .fit File") { showingImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct ActivityView: View {
    let model: ImportModel
    let activity: FITActivity

    private var coordinates: [CLLocationCoordinate2D] {
        activity.records.compactMap { $0.location?.coordinate }
    }

    private var activityType: HKWorkoutActivityType {
        let session = activity.sessions.first
        return workoutActivityType(sport: session?.sport ?? 0, subSport: session?.subSport)
    }

    var body: some View {
        List {
            if !coordinates.isEmpty {
                Section {
                    Map(interactionModes: []) {
                        MapPolyline(coordinates: coordinates)
                            .stroke(.orange, lineWidth: 4)
                    }
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
                }
            }

            Section(model.fileName ?? "Activity") {
                LabeledContent("Type", value: activityType.displayName)
                if let start = activity.startDate, let end = activity.endDate {
                    LabeledContent("Duration", value: Duration.seconds(end.timeIntervalSince(start)).formatted(.time(pattern: .hourMinuteSecond)))
                }
                if let distance = activity.totalDistance {
                    LabeledContent("Distance", value: Measurement(value: distance, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
                }
                if let hr = activity.averageHeartRate {
                    LabeledContent("Avg Heart Rate", value: "\(hr) bpm")
                }
                LabeledContent("GPS Points", value: coordinates.count.formatted())
            }

            timeSection

            if !model.overlapping.isEmpty {
                Section {
                    ForEach(model.overlapping, id: \.self) { Text($0) }
                } header: {
                    Label("Already in Health", systemImage: "exclamationmark.triangle")
                } footer: {
                    Text("Saving will create a second workout. You can delete the other one in the Health app (Browse → Activity → Workouts).")
                }
            }

            Section {
                switch model.state {
                case .saving:
                    HStack { ProgressView(); Text("Saving…") }
                case .saved:
                    Label("Saved to Apple Health", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Done") { model.reset() }
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                    saveButton
                default:
                    saveButton
                }
            }
        }
    }

    /// Start time is editable because some exporters write the clock wrong
    /// (e.g. a time zone applied twice); changing it shifts the whole activity.
    @ViewBuilder
    private var timeSection: some View {
        if let start = activity.startDate, let end = activity.endDate {
            Section {
                DatePicker(
                    "Start",
                    selection: Binding(get: { start }, set: { model.startOverride = $0 }),
                    displayedComponents: [.date, .hourAndMinute]
                )
                LabeledContent("End", value: end.formatted(date: .abbreviated, time: .shortened))
                if model.startOverride != nil {
                    Button("Use Time from File") { model.startOverride = nil }
                }
            } header: {
                Text("Time")
            } footer: {
                if end > .now {
                    Label("This activity ends in the future, so the file's clock is probably wrong. Set the correct start time before saving.", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var saveButton: some View {
        Button {
            Task { await model.save() }
        } label: {
            Label("Save to Apple Health", systemImage: "heart.fill")
        }
        .disabled(!HealthWriter.isAvailable)
    }
}

extension UTType {
    static let fitFile = UTType(importedAs: "com.garmin.fit")
}
