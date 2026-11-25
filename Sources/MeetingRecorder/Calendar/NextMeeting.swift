import EventKit
import Foundation
import MeetingCore
import MeetingEngine

/// The next meeting on today's calendar, for the menu bar: "Design review · in 12m".
///
/// Reads every calendar macOS knows about (System Settings › Internet Accounts), skips all-day events and
/// anything cancelled or declined, and re-checks every 20 seconds and whenever the calendar database changes.
/// Titles are shortened by the model once and cached, so the menu bar stays readable.
@MainActor
final class NextMeeting: ObservableObject {
    struct Upcoming: Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
    }

    /// Nil when there's nothing left today, the feature is off, or calendar access isn't granted.
    @Published private(set) var upcoming: Upcoming?
    /// The menu bar text, e.g. "Design review · in 12m". Nil = icon only.
    @Published private(set) var label: String?
    @Published private(set) var needsAccess = false
    /// True from a minute before the meeting until a minute after it starts — "get off whatever you're doing".
    @Published private(set) var flashing = false
    /// Flips every second while `flashing`; the label swaps between its normal and highlighted look on it.
    @Published private(set) var flashPhase = false

    private let settings: AppSettings
    private let calendar = CalendarService.shared
    private let shortener: TitleShortener
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    /// One-shot, fires when the next flash window opens (the 20 s refresh is too coarse to catch it on time).
    private var flashWake: Timer?
    /// Once a second in a meeting's last minute: redraws the seconds countdown and flips the flash.
    private var flashTick: Timer?
    /// The meeting whose flash was dismissed from the menu; it stays quiet, the next one still flashes.
    private var dismissedFlash: String?

    /// How long before the start the label starts flashing, and how long after it keeps going.
    static let flashLead: TimeInterval = 60
    static let flashTrail: TimeInterval = 60

    /// A meeting that started this recently still shows, as "now".
    private let graceAfterStart: TimeInterval = 5 * 60

    init(settings: AppSettings) {
        self.settings = settings
        self.shortener = TitleShortener(settings: settings)
        shortener.onUpdate = { [weak self] in self?.render() }
    }

    func start() {
        guard settings.showNextMeeting else { stop(); return }
        Task {
            // Asking is a one-time system prompt; after that the answer lives in System Settings.
            if calendar.eventAccess == .notDetermined { _ = await calendar.requestAccess(.calendar) }
            refresh()
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: calendar.store,
                                                              queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        if timer == nil {
            let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
            t.tolerance = 2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        stopTicking()
        flashWake?.invalidate(); flashWake = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        upcoming = nil
        label = nil
    }

    func requestAccess() {
        Task {
            if calendar.eventAccess == .notDetermined {
                _ = await calendar.requestAccess(.calendar)
            } else {
                CalendarService.openPrivacySettings(.calendar)
            }
            refresh()
        }
    }

    func refresh() {
        guard settings.showNextMeeting else { stop(); return }
        calendar.refreshAccess()
        needsAccess = !calendar.canReadEvents
        guard calendar.canReadEvents else { upcoming = nil; label = nil; scheduleFlash(); return }

        let now = Date()
        let cal = Calendar.current
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) else { return }
        let predicate = calendar.store.predicateForEvents(withStart: now.addingTimeInterval(-graceAfterStart),
                                                          end: endOfDay, calendars: nil)
        let events = calendar.store.events(matching: predicate).filter { Self.counts($0, now: now, grace: graceAfterStart) }
        let next = events
            .filter { $0.startDate < endOfDay }
            .min { ($0.startDate, $0.title ?? "") < ($1.startDate, $1.title ?? "") }

        upcoming = next.map {
            Upcoming(id: $0.calendarItemIdentifier, title: Self.title(of: $0), start: $0.startDate, end: $0.endDate)
        }
        // Shorten the whole rest of the day in one go, so the next one is ready before it's needed.
        shortener.prepare(events.map { Self.title(of: $0) })
        render()
        scheduleFlash()
    }

    // MARK: The last minute

    // From `flashLead` before the start to `flashTrail` after it, a one-second tick keeps the seconds
    // countdown moving. Flashing rides on that tick, but it's optional: switched off in Settings or
    // dismissed for this meeting, the countdown still ticks and only the red goes away.

    /// Start or stop the tick for the current `upcoming`, or set an alarm for when its last minute begins.
    private func scheduleFlash() {
        flashWake?.invalidate(); flashWake = nil
        guard let upcoming else { stopTicking(); return }
        let now = Date()
        let opens = upcoming.start.addingTimeInterval(-Self.flashLead)
        let closes = upcoming.start.addingTimeInterval(Self.flashTrail)
        if now >= opens && now < closes {
            startTicking()
            updateFlashing()
        } else {
            stopTicking()
            if now < opens {
                let t = Timer(fire: opens, interval: 0, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                }
                RunLoop.main.add(t, forMode: .common)
                flashWake = t
            }
        }
    }

    /// "Stop flashing" in the menu: quiet for this meeting only. The countdown carries on.
    func dismissFlash() {
        guard let upcoming else { return }
        dismissedFlash = Self.flashKey(upcoming)
        updateFlashing()
    }

    /// A moved meeting is a new reminder, so the start time is part of the key.
    private static func flashKey(_ m: Upcoming) -> String { "\(m.id)@\(m.start.timeIntervalSince1970)" }

    private var shouldFlash: Bool {
        guard flashTick != nil, settings.flashBeforeMeeting, let upcoming else { return false }
        return Self.flashKey(upcoming) != dismissedFlash
    }

    private func updateFlashing() {
        let on = shouldFlash
        if on && !flashing { flashing = true; flashPhase = true }
        if !on && flashing { flashing = false; flashPhase = false }
    }

    private func startTicking() {
        guard flashTick == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        flashTick = t
    }

    private func tick() {
        guard let upcoming, Date() < upcoming.start.addingTimeInterval(Self.flashTrail) else { refresh(); return }
        updateFlashing()
        if flashing { flashPhase.toggle() }
        render()
    }

    private func stopTicking() {
        flashTick?.invalidate(); flashTick = nil
        updateFlashing()
    }

    private func render() {
        guard let upcoming else { label = nil; return }
        let short = shortener.shortTitle(for: upcoming.title)
        label = "\(short) · \(MenuBarTitle.countdown(to: upcoming.start, from: Date()))"
    }

    private static func title(of event: EKEvent) -> String {
        let t = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Meeting" : t
    }

    /// Timed, not cancelled, not declined, and not already well under way.
    private static func counts(_ e: EKEvent, now: Date, grace: TimeInterval) -> Bool {
        if e.isAllDay || e.status == .canceled { return false }
        if e.endDate <= now { return false }
        if e.startDate < now.addingTimeInterval(-grace) { return false }
        if let me = e.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined { return false }
        if let t = e.title?.lowercased(), t.hasPrefix("canceled:") || t.hasPrefix("cancelled:") { return false }
        return true
    }
}

/// Calendar titles → menu-bar-sized labels. The heuristic answers immediately; the model's answer replaces it
/// when it arrives and is remembered on disk, so each title costs one call, ever.
@MainActor
final class TitleShortener {
    var onUpdate: (() -> Void)?

    private let settings: AppSettings
    private var cache: [String: String]
    private var inFlight: Set<String> = []
    /// Titles the model failed on this session — don't keep asking.
    private var failed: Set<String> = []

    init(settings: AppSettings) {
        self.settings = settings
        cache = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: Self.cacheURL))) ?? [:]
    }

    func shortTitle(for title: String) -> String {
        if let cached = cache[title] { return cached }
        // Short already: leave it alone.
        if title.count <= MenuBarTitle.maxLength { return title }
        return MenuBarTitle.heuristic(title)
    }

    /// Ask the model about any long titles not seen before.
    func prepare(_ titles: [String]) {
        let todo = Array(Set(titles.filter {
            $0.count > MenuBarTitle.maxLength && cache[$0] == nil && !inFlight.contains($0) && !failed.contains($0)
        })).sorted()
        guard !todo.isEmpty else { return }
        inFlight.formUnion(todo)
        let summarizer = ClaudeCLISummarizer(claudePath: settings.claudePath, model: "haiku")
        Task {
            defer { inFlight.subtract(todo) }
            do {
                let reply = try await summarizer.complete(CompletionRequest(
                    system: MenuBarTitle.shortenSystem, user: MenuBarTitle.shortenUser(todo),
                    schema: MenuBarTitle.shortenSchema, instruction: MenuBarTitle.shortenInstruction,
                    maxTokens: 512, label: "menu-bar-titles"))
                let labels = try LLMOutput.decode(MenuBarTitle.Labels.self, from: reply, label: "menu-bar-titles").labels
                guard labels.count == todo.count else {
                    throw SummarizerError.badOutput("asked for \(todo.count) labels, got \(labels.count)")
                }
                for (title, label) in zip(todo, labels) {
                    let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    cache[title] = MenuBarTitle.truncate(clean.isEmpty ? MenuBarTitle.heuristic(title) : clean)
                }
                save()
                onUpdate?()
            } catch {
                failed.formUnion(todo)
                Log.summarizer.warning("couldn't shorten menu bar titles: \(error.localizedDescription)")
            }
        }
    }

    private func save() {
        // Keep the file small: recurring meetings repeat, one-offs don't need remembering forever.
        if cache.count > 500 { cache = Dictionary(uniqueKeysWithValues: cache.suffix(400).map { ($0.key, $0.value) }) }
        do {
            try FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: Self.cacheURL, options: .atomic)
        } catch {
            Log.summarizer.warning("couldn't save menu bar titles: \(error.localizedDescription)")
        }
    }

    private static var cacheURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MeetingRecorder/short-titles.json")
    }
}
