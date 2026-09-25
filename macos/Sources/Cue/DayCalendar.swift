import Foundation

/// Today's meetings, as the Grok Bot calendar automation writes them
/// (`GrokBotHook.requestDay`) to Application Support/Cue/calendar/<yyyy-MM-dd>.json:
///
///   {"date": "2026-09-25", "meetings": [{"title": "…", "start": "<ISO 8601>", "end": "<ISO 8601>"}]}
///
/// The schedule is what tells the next back-to-back meeting apart from a
/// rejoin of the current one when the meeting app drops the mic and takes it back.
enum DayCalendar {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cue/calendar", isDirectory: true)
    }

    static func file(for day: Date) -> URL {
        directory.appendingPathComponent("\(dayKey(day)).json")
    }

    static func dayKey(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    static func meetings(on day: Date = Date()) -> [PrepStore.Schedule] {
        guard let data = try? Data(contentsOf: file(for: day)) else { return [] }
        return parse(data)
    }

    /// No read for today yet, or it's old enough that meetings may have been added or moved.
    static func isStale(now: Date = Date(), maxAge: TimeInterval = 2 * 3600) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file(for: now).path)
        guard let written = attributes?[.modificationDate] as? Date else { return true }
        return now.timeIntervalSince(written) > maxAge
    }

    private struct Payload: Decodable {
        struct Row: Decodable {
            let title: String?
            let start: String?
            let end: String?
        }
        let meetings: [Row]
    }

    static func parse(_ data: Data) -> [PrepStore.Schedule] {
        // Agents sometimes wrap the JSON in a markdown fence despite being asked not to.
        guard let text = String(data: data, encoding: .utf8),
              let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let payload = try? JSONDecoder().decode(Payload.self, from: Data(text[open...close].utf8))
        else { return [] }
        return payload.meetings.compactMap { row -> PrepStore.Schedule? in
            guard let start = row.start.flatMap(isoDate), let end = row.end.flatMap(isoDate), end > start
            else { return nil }
            let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return PrepStore.Schedule(title: title.isEmpty ? "Meeting" : title, start: start, end: end)
        }
        .sorted { $0.start < $1.start }
    }

    private static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// The meeting a moment belongs to: the one in progress (the later start
    /// wins where back-to-back or double-booked windows overlap), else the next
    /// one starting within `slack`, else one that ended within `slack` and is
    /// probably running over.
    static func meeting(
        at date: Date, in meetings: [PrepStore.Schedule], slack: TimeInterval = 10 * 60
    ) -> PrepStore.Schedule? {
        if let live = meetings.filter({ $0.start <= date && date < $0.end }).max(by: { $0.start < $1.start }) {
            return live
        }
        let upcoming = meetings.filter { $0.start > date && $0.start.timeIntervalSince(date) <= slack }
        if let next = upcoming.min(by: { $0.start < $1.start }) {
            return next
        }
        return meetings.filter { $0.end <= date && date.timeIntervalSince($0.end) <= slack }.max { $0.end < $1.end }
    }

    /// The calendar meeting to start listening to at `date`: whatever
    /// `meeting(at:)` says is on, unless that slot was already listened to or
    /// skipped (`done` may be the brief's copy of it, under another title).
    static func autoStartMeeting(
        at date: Date, in meetings: [PrepStore.Schedule], skipping done: PrepStore.Schedule?
    ) -> PrepStore.Schedule? {
        guard let meeting = meeting(at: date, in: meetings) else { return nil }
        if let done, done.start == meeting.start, done.end == meeting.end { return nil }
        return meeting
    }

    /// The meeting app let go of the mic and took it back at `date`. That is
    /// the next call rather than a rejoin once `current` is scheduled to be
    /// over, or when a later meeting is under way or starts within `lead`
    /// (leaving early to join it).
    static func isNextCall(
        at date: Date, after current: PrepStore.Schedule, in meetings: [PrepStore.Schedule],
        lead: TimeInterval = 5 * 60
    ) -> Bool {
        if date >= current.end { return true }
        return meetings.contains {
            $0.start > current.start && $0.start.timeIntervalSince(date) <= lead && $0.end > date
        }
    }
}
