// Checks DayCalendar parsing, auto-start, and the back-to-back split rule against
// the real sources. Synthetic meetings only — never commit real calendar data.
//
//   cd macos
//   swiftc -parse-as-library -o /tmp/repro_day_calendar scripts/repro_day_calendar.swift \
//     Sources/Cue/DayCalendar.swift Sources/Cue/PrepStore.swift Sources/Cue/GrokBotHook.swift Sources/Cue/DotEnv.swift
//   /tmp/repro_day_calendar           # offline checks
//   /tmp/repro_day_calendar --fire    # also POST the calendar webhook from .env and wait for today's file

import Foundation

@main
struct ReproDayCalendar {
    static func main() async {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        let iso = ISO8601DateFormatter()
        func at(_ time: String) -> Date { iso.date(from: "2026-09-23T\(time)-04:00")! }
        func meeting(_ title: String, _ start: String, _ end: String) -> PrepStore.Schedule {
            PrepStore.Schedule(title: title, start: at(start), end: at(end))
        }

        let file = """
        ```json
        {"date": "2026-09-23", "meetings": [
          {"title": "Late sync", "start": "2026-09-23T17:00:00-04:00", "end": "2026-09-23T17:30:00-04:00"},
          {"title": "Backwards", "start": "2026-09-23T12:30:00-04:00", "end": "2026-09-23T12:00:00-04:00"},
          {"title": null, "start": "2026-09-23T16:00:00.000-04:00", "end": "2026-09-23T16:30:00.000-04:00"},
          {"title": "No times"}
        ]}
        ```
        """
        let parsed = DayCalendar.parse(Data(file.utf8))
        check("parse: fenced JSON, bad rows dropped, sorted", parsed.map(\.title) == ["Meeting", "Late sync"])
        check("parse: fractional seconds", parsed.first?.start == at("16:00:00"))
        check("parse: garbage is no meetings", DayCalendar.parse(Data("not json".utf8)).isEmpty)
        check("dayKey is local yyyy-MM-dd", DayCalendar.dayKey(at("12:00:00")) == "2026-09-23")

        // Back-to-back: Listen at 16:06 in A; Zoom let go at 16:30:03 and took the mic back at 16:30:19 for B.
        let a = meeting("Customer A", "16:00:00", "16:30:00")
        let b = meeting("Customer B", "16:30:00", "17:00:00")
        let day = [a, b]
        check("Listen mid-meeting binds to it", DayCalendar.meeting(at: at("16:06:27"), in: day) == a)
        check("touching windows: the later meeting owns the boundary", DayCalendar.meeting(at: at("16:30:00"), in: day) == b)
        check("Listen a few minutes early binds to the upcoming meeting", DayCalendar.meeting(at: at("15:55:00"), in: day) == a)
        check("nothing within 10 min: no meeting", DayCalendar.meeting(at: at("15:40:00"), in: day) == nil)
        check("just after the last meeting: still that one (running over)", DayCalendar.meeting(at: at("17:05:00"), in: day) == b)
        let short = meeting("Short", "15:30:00", "15:50:00")
        check("an upcoming meeting beats one that just ended", DayCalendar.meeting(at: at("15:52:00"), in: [short, a]) == a)

        check("hop into the next meeting splits", DayCalendar.isNextCall(at: at("16:30:19"), after: a, in: day))
        check("rejoin mid-meeting does not split", !DayCalendar.isNextCall(at: at("16:15:00"), after: a, in: day))
        check("leaving 3 min early for the next meeting splits", DayCalendar.isNextCall(at: at("16:27:00"), after: a, in: day))
        check("a drop 10 min before the next meeting does not split", !DayCalendar.isNextCall(at: at("16:20:00"), after: a, in: day))

        // No calendar, only the brief's 15:00–15:30; the app took the mic back at 15:32.
        let brief = meeting("From the brief", "15:00:00", "15:30:00")
        check("brief only: hop after its end splits", DayCalendar.isNextCall(at: at("15:32:07"), after: brief, in: []))
        check("brief only: hop before its end does not", !DayCalendar.isNextCall(at: at("15:20:00"), after: brief, in: []))

        // Auto-start: once per calendar slot; Stop or Not now marks the slot done.
        check("auto-start: joining a scheduled meeting starts it",
              DayCalendar.autoStartMeeting(at: at("16:01:35"), in: day, skipping: nil) == a)
        check("auto-start: not again after listening to or skipping that meeting",
              DayCalendar.autoStartMeeting(at: at("16:12:00"), in: day, skipping: a) == nil)
        check("auto-start: the brief's copy of the slot counts as the same meeting",
              DayCalendar.autoStartMeeting(at: at("16:12:00"), in: day, skipping: meeting("Brief title", "16:00:00", "16:30:00")) == nil)
        check("auto-start: the next meeting starts once the last one is over",
              DayCalendar.autoStartMeeting(at: at("16:31:00"), in: day, skipping: a) == b)
        check("auto-start: joining the next room early waits for its start time",
              DayCalendar.autoStartMeeting(at: at("16:26:00"), in: day, skipping: a) == nil
                  && DayCalendar.autoStartMeeting(at: at("16:30:00"), in: day, skipping: a) == b)
        check("auto-start: calls not on the calendar never start on their own",
              DayCalendar.autoStartMeeting(at: at("14:00:00"), in: day, skipping: nil) == nil)

        let workshop = meeting("Workshop", "10:00:00", "12:00:00")
        let overlap = meeting("Double-booked", "10:30:00", "11:00:00")
        check("a double-booking that already ended does not split a long meeting",
              !DayCalendar.isNextCall(at: at("11:30:00"), after: workshop, in: [workshop, overlap]))

        if CommandLine.arguments.contains("--fire") {
            failures += await fire()
        }
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// End to end: the real request path, then wait for the bot to write today's file.
    static func fire() async -> Int {
        guard GrokBotHook.isCalendarConfigured else {
            print("FAIL GROK_BOT_CALENDAR_URL / GROK_BOT_CALENDAR_KEY not found in .env")
            return 1
        }
        let target = DayCalendar.file(for: Date())
        func written() -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: target.path))?[.modificationDate] as? Date
        }
        let before = written()
        do {
            let response = try await GrokBotHook.requestDay()
            print("fired run=\(response.runUuid ?? "?")")
        } catch {
            print("FAIL webhook: \(error.localizedDescription)")
            return 1
        }
        for _ in 0..<120 {
            try? await Task.sleep(for: .seconds(5))
            guard let stamp = written(), stamp != before else { continue }
            try? await Task.sleep(for: .seconds(2))
            let meetings = DayCalendar.meetings()
            let bytes = (try? Data(contentsOf: target))?.count ?? 0
            print("landed \(target.lastPathComponent) (\(bytes) bytes): \(meetings.count) meetings")
            for m in meetings {
                print("  \(m.start.formatted(date: .omitted, time: .shortened))–\(m.end.formatted(date: .omitted, time: .shortened))  \(m.title)")
            }
            return 0
        }
        print("FAIL nothing written to \(target.path) within 10 min")
        return 1
    }
}
