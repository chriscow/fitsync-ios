import CoreLocation
import Foundation
import HealthKit

/// Writes a parsed FIT activity to Apple Health as a workout with its route,
/// heart rate, distance, energy and (for rides) power and cadence samples.
@MainActor
final class HealthWriter {
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let store = HKHealthStore()

    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceSwimming),
            HKQuantityType(.distanceDownhillSnowSports),
        ]
        types.insert(HKQuantityType(.cyclingPower))
        types.insert(HKQuantityType(.cyclingCadence))
        return types
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: shareTypes, read: [HKObjectType.workoutType()])
    }

    /// Workouts already in Health that overlap the given interval, described as
    /// "Source – Activity, start time". Returns an empty list if read access was denied.
    func overlappingWorkouts(start: Date, end: Date) async -> [String] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        guard let workouts = try? await descriptor.result(for: store) else { return [] }
        return workouts.map { workout in
            let source = workout.sourceRevision.source.name
            let time = workout.startDate.formatted(date: .omitted, time: .shortened)
            return "\(source) – \(workout.workoutActivityType.displayName), \(time)"
        }
    }

    /// Saves the activity and returns the created workout.
    func save(_ activity: FITActivity) async throws -> HKWorkout {
        guard let start = activity.startDate, let end = activity.endDate, end > start else {
            throw HealthWriterError.noTimeRange
        }
        let sport = activity.sessions.first
        let activityType = workoutActivityType(sport: sport?.sport ?? 0, subSport: sport?.subSport)
        let indoor = isIndoor(subSport: sport?.subSport) || !activity.hasGPS

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activityType
        configuration.locationType = indoor ? .indoor : .outdoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        try await builder.beginCollection(at: start)

        let samples = makeSamples(for: activity, activityType: activityType, start: start, end: end)
        if !samples.isEmpty {
            try await builder.addSamples(samples)
        }
        try await builder.addMetadata([
            HKMetadataKeyIndoorWorkout: indoor,
            HKMetadataKeyWasUserEntered: false,
        ])
        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else {
            throw HealthWriterError.workoutNotCreated
        }

        let locations = activity.records.compactMap(\.location)
        if !locations.isEmpty {
            let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
            // HealthKit recommends inserting route data in batches.
            for batch in stride(from: 0, to: locations.count, by: 500) {
                try await routeBuilder.insertRouteData(Array(locations[batch..<min(batch + 500, locations.count)]))
            }
            try await routeBuilder.finishRoute(with: workout, metadata: nil)
        }
        return workout
    }

    // MARK: - Samples

    private func makeSamples(for activity: FITActivity, activityType: HKWorkoutActivityType, start: Date, end: Date) -> [HKSample] {
        var samples: [HKSample] = []
        let records = activity.records

        let bpm = HKUnit.count().unitDivided(by: .minute())
        for record in records {
            guard let hr = record.heartRate, hr > 0 else { continue }
            samples.append(quantitySample(.heartRate, Double(hr), bpm, record.timestamp, record.timestamp))
        }

        if let distanceID = distanceType(for: activityType) {
            samples += intervalSamples(records, id: distanceID, unit: .meter(), value: \.distance, cumulative: true)
        }

        if activityType == .cycling {
            samples += intervalSamples(records, id: .cyclingPower, unit: .watt(), value: { $0.power.map(Double.init) }, cumulative: false)
            samples += intervalSamples(records, id: .cyclingCadence, unit: bpm, value: { $0.cadence.map(Double.init) }, cumulative: false)
        }

        let calories = activity.sessions.compactMap(\.totalCalories).reduce(0, +)
        if calories > 0 {
            samples.append(quantitySample(.activeEnergyBurned, calories, .kilocalorie(), start, end))
        }
        return samples
    }

    /// Groups records into ~10 s buckets. Cumulative values (distance) become the
    /// delta across the bucket; instantaneous values (power, cadence) the average.
    private func intervalSamples(
        _ records: [FITRecord],
        id: HKQuantityTypeIdentifier,
        unit: HKUnit,
        value: (FITRecord) -> Double?,
        cumulative: Bool
    ) -> [HKSample] {
        let points = records.compactMap { record in value(record).map { (record.timestamp, $0) } }
        guard points.count > 1 else { return [] }

        var samples: [HKSample] = []
        var bucketStart = 0
        for i in 1..<points.count {
            let isLast = i == points.count - 1
            guard isLast || points[i].0.timeIntervalSince(points[bucketStart].0) >= 10 else { continue }
            let from = points[bucketStart].0, to = points[i].0
            if to > from {
                let amount: Double
                if cumulative {
                    amount = points[i].1 - points[bucketStart].1
                } else {
                    let slice = points[bucketStart...i]
                    amount = slice.map(\.1).reduce(0, +) / Double(slice.count)
                }
                if amount > 0 {
                    samples.append(quantitySample(id, amount, unit, from, to))
                }
            }
            bucketStart = i
        }
        return samples
    }

    private func quantitySample(_ id: HKQuantityTypeIdentifier, _ value: Double, _ unit: HKUnit, _ start: Date, _ end: Date) -> HKQuantitySample {
        HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: value), start: start, end: end)
    }

    private func distanceType(for type: HKWorkoutActivityType) -> HKQuantityTypeIdentifier? {
        switch type {
        case .cycling: .distanceCycling
        case .running, .walking, .hiking: .distanceWalkingRunning
        case .swimming: .distanceSwimming
        case .downhillSkiing, .snowboarding, .crossCountrySkiing: .distanceDownhillSnowSports
        default: nil
        }
    }
}

enum HealthWriterError: LocalizedError {
    case noTimeRange
    case workoutNotCreated

    var errorDescription: String? {
        switch self {
        case .noTimeRange: "The file has no usable start and end time."
        case .workoutNotCreated: "Health did not create the workout."
        }
    }
}

// MARK: - FIT → HealthKit mapping

/// Maps FIT `sport` / `sub_sport` enum values to a HealthKit activity type.
func workoutActivityType(sport: UInt8, subSport: UInt8?) -> HKWorkoutActivityType {
    switch sport {
    case 1: .running
    case 2, 21: .cycling                         // cycling, e-biking
    case 4 where subSport == 6: .cycling         // fitness equipment / indoor cycling
    case 4 where subSport == 1: .running         // fitness equipment / treadmill
    case 4 where subSport == 14: .rowing         // fitness equipment / indoor rowing
    case 5: .swimming
    case 10: .traditionalStrengthTraining
    case 11: .walking
    case 12: .crossCountrySkiing
    case 13: .downhillSkiing
    case 14: .snowboarding
    case 15: .rowing
    case 17: .hiking
    case 19, 37, 41: .paddleSports               // paddling, SUP, kayaking
    default: .other
    }
}

/// FIT sub_sports that are indoor: treadmill, indoor cycling, indoor rowing,
/// virtual activity, indoor running, indoor walking.
func isIndoor(subSport: UInt8?) -> Bool {
    guard let subSport else { return false }
    return [1, 6, 14, 58, 45, 27].contains(subSport)
}

extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running: "Run"
        case .cycling: "Ride"
        case .walking: "Walk"
        case .hiking: "Hike"
        case .swimming: "Swim"
        case .rowing: "Row"
        case .crossCountrySkiing: "Nordic Ski"
        case .downhillSkiing: "Ski"
        case .snowboarding: "Snowboard"
        case .paddleSports: "Paddle"
        case .traditionalStrengthTraining: "Strength"
        default: "Workout"
        }
    }
}

// MARK: - FIT convenience

extension FITActivity {
    var startDate: Date? {
        sessions.compactMap(\.startTime).min() ?? records.first?.timestamp
    }

    var endDate: Date? {
        let recordEnd = records.last?.timestamp
        let sessionEnd = sessions.compactMap { session -> Date? in
            guard let start = session.startTime, let elapsed = session.totalElapsedTime else { return nil }
            return start.addingTimeInterval(elapsed)
        }.max()
        return [recordEnd, sessionEnd].compactMap { $0 }.max()
    }

    var totalDistance: Double? {
        let fromSessions = sessions.compactMap(\.totalDistance).reduce(0, +)
        return fromSessions > 0 ? fromSessions : records.last(where: { $0.distance != nil })?.distance
    }

    var hasGPS: Bool { records.contains { $0.location != nil } }

    /// A copy with every timestamp moved by `offset` seconds, for files whose clock is wrong.
    func shifted(by offset: TimeInterval) -> FITActivity {
        var copy = self
        copy.records = records.map { record in
            var record = record
            record.timestamp += offset
            return record
        }
        copy.sessions = sessions.map { session in
            var session = session
            session.startTime = session.startTime.map { $0 + offset }
            return session
        }
        return copy
    }

    var averageHeartRate: Int? {
        let values = records.compactMap(\.heartRate).filter { $0 > 0 }
        return values.isEmpty ? nil : values.reduce(0, +) / values.count
    }
}

extension FITRecord {
    var location: CLLocation? {
        guard let latitude, let longitude, latitude != 0 || longitude != 0 else { return nil }
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude ?? 0,
            horizontalAccuracy: 5,
            verticalAccuracy: altitude == nil ? -1 : 5,
            course: -1,
            speed: speed ?? -1,
            timestamp: timestamp
        )
    }
}
