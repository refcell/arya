/// A charter's periodic report (connect lane): a digest of the outcome, its trend, and what
/// the steward did, sent on a cadence to people through their own person binding (the local
/// inbox, or their address on a relay).
public struct ReportConfig: Hashable, Sendable, Codable {
    public enum Cadence: String, Hashable, Sendable, Codable, CaseIterable {
        case daily, weekly
    }

    /// Person binding ids that receive it.
    public var to: [String]
    public var cadence: Cadence
    /// For a weekly report, the ISO weekday it goes out: 1 is Monday, 7 Sunday. Default 1.
    public var weekday: Int?
    /// The UTC hour it goes out, 0 to 23. Default 9.
    public var hour: Int?

    public init(to: [String], cadence: Cadence = .weekly, weekday: Int? = nil, hour: Int? = nil) {
        self.to = to
        self.cadence = cadence
        self.weekday = weekday
        self.hour = hour
    }

    /// The weekday it goes out (weekly reports).
    public var day: Int { weekday ?? 1 }
    /// The UTC hour it goes out.
    public var at: Int { hour ?? 9 }
    /// The days one report covers.
    public var days: Int { cadence == .weekly ? 7 : 1 }
}

extension Charter {
    func validateReport() -> [CharterIssue] {
        guard let report else { return [] }
        var issues: [CharterIssue] = []
        if report.to.isEmpty { issues.append(.init("report.to", "must name at least one person")) }
        for (i, id) in report.to.enumerated() where binding(id)?.kind != .person {
            issues.append(.init("report.to[\(i)]", "unknown person binding \(id)"))
        }
        if let day = report.weekday, !(1...7).contains(day) {
            issues.append(.init("report.weekday", "must be 1 (Monday) to 7 (Sunday)"))
        }
        if let hour = report.hour, !(0...23).contains(hour) {
            issues.append(.init("report.hour", "must be 0 to 23"))
        }
        return issues
    }
}
