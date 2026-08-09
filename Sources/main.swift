import Cocoa
import ServiceManagement

// MARK: - Model

struct LimitInfo {
    let label: String
    let percent: Double
    let resetsAt: Date?
}

struct Usage {
    let session: LimitInfo?
    let weekly: LimitInfo?
    /// Weekly limits that only cover one model (e.g. Fable). Which models get
    /// their own limit changes over time, so these are rendered as reported.
    let scoped: [LimitInfo]
    let fetchedAt: Date
}

enum FetchError: Error {
    case noToken
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    case http(Int)
    case badResponse

    var message: String {
        switch self {
        case .noToken: return "No Claude Code credentials found in Keychain"
        case .unauthorized: return "Token expired — use Claude Code once to refresh it"
        case .rateLimited: return "Rate-limited — will retry in a few minutes"
        case .network(let m): return "Network error: \(m)"
        case .http(let s): return "Usage API error (HTTP \(s))"
        case .badResponse: return "Unexpected response from usage API"
        }
    }
}

// MARK: - Helpers

func parseISODate(_ string: String?) -> Date? {
    guard var s = string else { return nil }
    // The API returns 6-digit fractional seconds, which ISO8601DateFormatter rejects.
    if let range = s.range(of: #"\.\d+"#, options: .regularExpression) {
        s.removeSubrange(range)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: s)
}

func countdownString(to date: Date) -> String {
    let seconds = max(0, Int(date.timeIntervalSinceNow))
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    if seconds >= 3600 { return "\(h)h\(String(format: "%02d", m))m" }
    if seconds >= 60 { return "\(m)m" }
    return "<1m"
}

func pad(_ label: String, to width: Int) -> String {
    label + String(repeating: " ", count: max(1, width - label.count))
}

func progressBar(_ percent: Double) -> String {
    let filled = min(10, max(0, Int((percent / 10.0).rounded())))
    return String(repeating: "█", count: filled) + String(repeating: "░", count: 10 - filled)
}

func colorFor(percent: Double) -> NSColor {
    if percent >= 95 { return .systemRed }
    if percent >= 80 { return .systemOrange }
    return .labelColor
}

// MARK: - Fetcher

final class UsageFetcher {
    private var cachedToken: String?

    private func readToken() -> String? {
        let credFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: credFile), let token = Self.extractToken(from: data) {
            return token
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return Self.extractToken(from: data)
    }

    private static func extractToken(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    func fetch(completion: @escaping (Result<Usage, FetchError>) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.attempt(allowRetry: true, completion: completion)
        }
    }

    private func attempt(allowRetry: Bool, completion: @escaping (Result<Usage, FetchError>) -> Void) {
        if cachedToken == nil { cachedToken = readToken() }
        guard let token = cachedToken else {
            completion(.failure(.noToken))
            return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                self.cachedToken = nil
                if allowRetry {
                    // Claude Code may have rotated the token — re-read it once.
                    DispatchQueue.global(qos: .utility).async {
                        self.attempt(allowRetry: false, completion: completion)
                    }
                } else {
                    completion(.failure(.unauthorized))
                }
                return
            }
            if status == 429 {
                let retryAfter = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                completion(.failure(.rateLimited(retryAfter: retryAfter)))
                return
            }
            guard status == 200 else {
                completion(.failure(.http(status)))
                return
            }
            guard let data, let usage = Self.parseUsage(data) else {
                completion(.failure(.badResponse))
                return
            }
            completion(.success(usage))
        }.resume()
    }

    private static func parseUsage(_ data: Data) -> Usage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let limits = obj["limits"] as? [[String: Any]], !limits.isEmpty {
            return parseLimits(limits)
        }
        return parseLegacyKeys(obj)
    }

    /// The `limits` array is the shape the usage page itself renders: one entry
    /// per limit, with per-model limits carrying a `scope`.
    private static func parseLimits(_ limits: [[String: Any]]) -> Usage {
        var session: LimitInfo?
        var weekly: LimitInfo?
        var scoped: [LimitInfo] = []

        for entry in limits {
            let percent = (entry["percent"] as? NSNumber)?.doubleValue ?? 0
            let resetsAt = parseISODate(entry["resets_at"] as? String)
            switch entry["kind"] as? String {
            case "session":
                session = LimitInfo(label: "Session", percent: percent, resetsAt: resetsAt)
            case "weekly_all":
                weekly = LimitInfo(label: "Week", percent: percent, resetsAt: resetsAt)
            case "weekly_scoped":
                let scope = entry["scope"] as? [String: Any]
                let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
                scoped.append(LimitInfo(label: model ?? surface ?? "Weekly",
                                        percent: percent, resetsAt: resetsAt))
            default:
                break
            }
        }
        return Usage(session: session, weekly: weekly, scoped: scoped, fetchedAt: Date())
    }

    /// Fallback for older responses that only had top-level per-limit objects.
    private static func parseLegacyKeys(_ obj: [String: Any]) -> Usage {
        func limit(_ key: String, _ label: String) -> LimitInfo? {
            guard let dict = obj[key] as? [String: Any] else { return nil }
            let percent = (dict["utilization"] as? NSNumber)?.doubleValue ?? 0
            return LimitInfo(label: label, percent: percent,
                             resetsAt: parseISODate(dict["resets_at"] as? String))
        }
        return Usage(
            session: limit("five_hour", "Session"),
            weekly: limit("seven_day", "Week"),
            scoped: [limit("seven_day_opus", "Opus"), limit("seven_day_sonnet", "Sonnet")].compactMap { $0 },
            fetchedAt: Date()
        )
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var screenChangeWorkItem: DispatchWorkItem?
    private let fetcher = UsageFetcher()
    private var usage: Usage?
    private var lastError: FetchError?
    private var backoffUntil: Date?

    private let sessionItem = NSMenuItem()
    private let weeklyItem = NSMenuItem()
    private var scopedItems: [NSMenuItem] = []
    private let updatedItem = NSMenuItem()
    private var loginItem: NSMenuItem!
    private var compactItem: NSMenuItem!
    private var compactMode = UserDefaults.standard.bool(forKey: "compactMode")

    private lazy var statusIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "asterisk", accessibilityDescription: "Claude usage")
        image?.isTemplate = true
        return image
    }()

    private let menuFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = buildMenu()
        setupStatusItem()
        refresh()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenConfigurationChanged()
        }

        let fetchTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        fetchTimer.tolerance = 30
        let tickTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.renderTitle()
        }
        tickTimer.tolerance = 2
        RunLoop.main.add(fetchTimer, forMode: .common)
        RunLoop.main.add(tickTimer, forMode: .common)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "ClaudeUsage"
        statusItem.isVisible = true
        statusItem.button?.imagePosition = .imageLeft
        statusItem.menu = menu
        renderTitle()
        renderMenu()
    }

    // macOS Tahoe can drop third-party status items from the menu bar when the
    // display configuration changes; re-assert the item once things settle.
    private func screenConfigurationChanged() {
        screenChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.statusItem.isVisible = true
            if self.statusItem.button?.window == nil {
                NSStatusBar.system.removeStatusItem(self.statusItem)
                self.setupStatusItem()
            }
        }
        screenChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for item in [sessionItem, weeklyItem] {
            item.isEnabled = true
            menu.addItem(item)
        }

        menu.addItem(.separator())

        updatedItem.isEnabled = false
        menu.addItem(updatedItem)

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        compactItem = NSMenuItem(title: "Compact Mode", action: #selector(toggleCompact), keyEquivalent: "")
        compactItem.target = self
        compactItem.state = compactMode ? .on : .off
        menu.addItem(compactItem)

        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        updateLoginItemState()

        let quitItem = NSMenuItem(title: "Quit Claude Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    // MARK: Refresh

    @objc private func refreshClicked() { refresh(force: true) }

    private func refresh(force: Bool = false) {
        if !force, let until = backoffUntil, Date() < until { return }
        fetcher.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let usage):
                    self.usage = usage
                    self.lastError = nil
                    self.backoffUntil = nil
                case .failure(let error):
                    self.lastError = error
                    if case .rateLimited(let retryAfter) = error {
                        self.backoffUntil = Date().addingTimeInterval(retryAfter ?? 600)
                    }
                }
                self.renderTitle()
                self.renderMenu()
            }
        }
    }

    // MARK: Rendering

    private func renderTitle() {
        guard let button = statusItem.button else { return }

        // Compact mode drops the icon and countdown to minimize menu bar
        // footprint — macOS silently hides items that don't fit.
        button.image = compactMode ? nil : statusIcon
        let prefix = compactMode ? "" : " "

        let text: String
        let color: NSColor
        if let session = usage?.session {
            var parts = ["\(Int(session.percent.rounded()))%"]
            if !compactMode, let resetsAt = session.resetsAt {
                parts.append(countdownString(to: resetsAt))
            }
            text = prefix + parts.joined(separator: " · ")
            color = colorFor(percent: session.percent)
        } else if lastError != nil {
            text = prefix + "—"
            color = .labelColor
        } else {
            text = prefix + "…"
            color = .labelColor
        }

        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ])
    }

    private func renderMenu() {
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short

        let dayFormatter = DateFormatter()
        dayFormatter.setLocalizedDateFormatFromTemplate("EEE d MMM HH:mm")

        let scoped = usage?.scoped ?? []
        // Keep the label column aligned however many scoped limits show up.
        let labelWidth = max(8, (scoped.map(\.label.count).max() ?? 0) + 1)

        func line(_ info: LimitInfo, _ formatter: DateFormatter, showCountdown: Bool) -> NSAttributedString {
            var text = pad(info.label, to: labelWidth)
                + progressBar(info.percent)
                + String(format: " %3d%%", Int(info.percent.rounded()))
            if let resetsAt = info.resetsAt {
                text += "   resets \(formatter.string(from: resetsAt))"
                if showCountdown {
                    text += " (\(countdownString(to: resetsAt)))"
                }
            }
            return NSAttributedString(string: text, attributes: [
                .font: menuFont,
                .foregroundColor: colorFor(percent: info.percent),
            ])
        }

        if let session = usage?.session {
            sessionItem.attributedTitle = line(session, timeFormatter, showCountdown: true)
        } else {
            sessionItem.attributedTitle = NSAttributedString(string: "Session: no data", attributes: [.font: menuFont])
        }

        if let weekly = usage?.weekly {
            weeklyItem.attributedTitle = line(weekly, dayFormatter, showCountdown: false)
            weeklyItem.isHidden = false
        } else {
            weeklyItem.isHidden = true
        }

        syncScopedItemCount(to: scoped.count)
        for (item, info) in zip(scopedItems, scoped) {
            item.attributedTitle = line(info, dayFormatter, showCountdown: false)
        }

        if let error = lastError {
            updatedItem.title = "⚠︎ \(error.message)"
        } else if let usage {
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .medium
            updatedItem.title = "Updated \(f.string(from: usage.fetchedAt))"
        } else {
            updatedItem.title = "Loading…"
        }
    }

    /// Adds or removes rows below "Week" so there is exactly one per scoped limit.
    private func syncScopedItemCount(to count: Int) {
        while scopedItems.count > count {
            menu.removeItem(scopedItems.removeLast())
        }
        while scopedItems.count < count {
            let item = NSMenuItem()
            item.isEnabled = true
            menu.insertItem(item, at: menu.index(of: weeklyItem) + scopedItems.count + 1)
            scopedItems.append(item)
        }
    }

    // MARK: Compact mode

    @objc private func toggleCompact() {
        compactMode.toggle()
        UserDefaults.standard.set(compactMode, forKey: "compactMode")
        compactItem.state = compactMode ? .on : .off
        renderTitle()
    }

    // MARK: Login item

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Login item toggle failed: \(error)")
        }
        updateLoginItemState()
    }

    private func updateLoginItemState() {
        guard #available(macOS 13.0, *) else {
            loginItem.isHidden = true
            return
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
