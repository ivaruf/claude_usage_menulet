import Cocoa
import ServiceManagement

// MARK: - Model

struct LimitInfo {
    let percent: Double
    let resetsAt: Date?
}

struct Usage {
    let session: LimitInfo?
    let weekly: LimitInfo?
    let weeklyOpus: LimitInfo?
    let fetchedAt: Date
}

enum FetchError: Error {
    case noToken
    case unauthorized
    case network(String)
    case badResponse

    var message: String {
        switch self {
        case .noToken: return "No Claude Code credentials found in Keychain"
        case .unauthorized: return "Token expired — use Claude Code once to refresh it"
        case .network(let m): return "Network error: \(m)"
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
            guard status == 200, let data, let usage = Self.parseUsage(data) else {
                completion(.failure(.badResponse))
                return
            }
            completion(.success(usage))
        }.resume()
    }

    private static func parseUsage(_ data: Data) -> Usage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func limit(_ key: String) -> LimitInfo? {
            guard let dict = obj[key] as? [String: Any] else { return nil }
            let percent = (dict["utilization"] as? NSNumber)?.doubleValue ?? 0
            return LimitInfo(percent: percent, resetsAt: parseISODate(dict["resets_at"] as? String))
        }
        return Usage(
            session: limit("five_hour"),
            weekly: limit("seven_day"),
            weeklyOpus: limit("seven_day_opus"),
            fetchedAt: Date()
        )
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let fetcher = UsageFetcher()
    private var usage: Usage?
    private var lastError: FetchError?

    private let sessionItem = NSMenuItem()
    private let weeklyItem = NSMenuItem()
    private let opusItem = NSMenuItem()
    private let updatedItem = NSMenuItem()
    private var loginItem: NSMenuItem!

    private let menuFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "asterisk", accessibilityDescription: "Claude usage") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageLeft
            }
        }
        statusItem.menu = buildMenu()

        renderTitle()
        refresh()

        let fetchTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        fetchTimer.tolerance = 5
        let tickTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.renderTitle()
        }
        tickTimer.tolerance = 2
        RunLoop.main.add(fetchTimer, forMode: .common)
        RunLoop.main.add(tickTimer, forMode: .common)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for item in [sessionItem, weeklyItem, opusItem] {
            item.isEnabled = true
            menu.addItem(item)
        }
        opusItem.isHidden = true

        menu.addItem(.separator())

        updatedItem.isEnabled = false
        menu.addItem(updatedItem)

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        updateLoginItemState()

        let quitItem = NSMenuItem(title: "Quit Claude Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    // MARK: Refresh

    @objc private func refreshClicked() { refresh() }

    private func refresh() {
        fetcher.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let usage):
                    self.usage = usage
                    self.lastError = nil
                case .failure(let error):
                    self.lastError = error
                }
                self.renderTitle()
                self.renderMenu()
            }
        }
    }

    // MARK: Rendering

    private func renderTitle() {
        guard let button = statusItem.button else { return }

        let text: String
        let color: NSColor
        if let session = usage?.session {
            var parts = ["\(Int(session.percent.rounded()))%"]
            if let resetsAt = session.resetsAt {
                parts.append(countdownString(to: resetsAt))
            }
            text = " " + parts.joined(separator: " · ")
            color = colorFor(percent: session.percent)
        } else if lastError != nil {
            text = " —"
            color = .labelColor
        } else {
            text = " …"
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

        func line(_ label: String, _ info: LimitInfo, _ formatter: DateFormatter, showCountdown: Bool) -> NSAttributedString {
            var text = String(format: "%-8s", (label as NSString).utf8String!)
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
            sessionItem.attributedTitle = line("Session", session, timeFormatter, showCountdown: true)
        } else {
            sessionItem.attributedTitle = NSAttributedString(string: "Session: no data", attributes: [.font: menuFont])
        }

        if let weekly = usage?.weekly {
            weeklyItem.attributedTitle = line("Week", weekly, dayFormatter, showCountdown: false)
            weeklyItem.isHidden = false
        } else {
            weeklyItem.isHidden = true
        }

        if let opus = usage?.weeklyOpus {
            opusItem.attributedTitle = line("Opus", opus, dayFormatter, showCountdown: false)
            opusItem.isHidden = false
        } else {
            opusItem.isHidden = true
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
