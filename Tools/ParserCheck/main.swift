import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: ParserCheck file.fit"); exit(2) }
guard let data = FileManager.default.contents(atPath: args[1]) else { print("cannot read \(args[1])"); exit(2) }
do {
    let a = try FITParser.parse(data)
    let iso = ISO8601DateFormatter()
    print("sessions: \(a.sessions.count)")
    for s in a.sessions {
        print("  sport=\(s.sport) sub=\(s.subSport.map(String.init) ?? "nil") start=\(s.startTime.map { iso.string(from: $0) } ?? "nil")")
        print("  elapsed=\(s.totalElapsedTime ?? -1) timer=\(s.totalTimerTime ?? -1) dist=\(s.totalDistance ?? -1) kcal=\(s.totalCalories ?? -1)")
    }
    print("records: \(a.records.count)")
    func d(_ r: FITRecord) -> String {
        "\(iso.string(from: r.timestamp)) lat=\(r.latitude.map { String(format: "%.6f", $0) } ?? "nil") lon=\(r.longitude.map { String(format: "%.6f", $0) } ?? "nil") alt=\(r.altitude.map { String(format: "%.1f", $0) } ?? "nil") hr=\(r.heartRate.map(String.init) ?? "nil") cad=\(r.cadence.map(String.init) ?? "nil") pwr=\(r.power.map(String.init) ?? "nil") spd=\(r.speed.map { String(format: "%.3f", $0) } ?? "nil") dist=\(r.distance.map { String(format: "%.2f", $0) } ?? "nil")"
    }
    if let f = a.records.first { print("first: \(d(f))") }
    if let l = a.records.last { print("last:  \(d(l))") }
    print("with GPS: \(a.records.filter { $0.latitude != nil && $0.longitude != nil }.count)")
    print("with HR: \(a.records.filter { $0.heartRate != nil }.count)")
    print("with power: \(a.records.filter { $0.power != nil }.count)")
} catch {
    print("ERROR (thrown): \(error.localizedDescription)")
    exit(1)
}
