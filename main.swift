import AppKit
import Foundation

// AI usage menu bar item: Claude Code monthly credit + LiteLLM budget in one item.
// - Claude Code: OAuth token from the macOS Keychain ("Claude Code-credentials"),
//   fetched from https://claude.ai/api/oauth/usage (same as ~/claude-usage.sh).
// - LiteLLM: LITELLM_BASE_URL / LITELLM_API_KEY from ~/.config/litellm/env,
//   fetched from /v1/usage (same as litellm-budget.sh).
// - Each source is fetched and fails independently.
// - Shown as:  CC 21% · LL 6%   (a source shows "—" when unavailable);
//   plus MO = share of the current month elapsed;
//   the menu has the dollar amounts and last update time of each.

let ENV_FILE = (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/litellm/env").path)
let CLAUDE_USAGE_URL = URL(string: "https://claude.ai/api/oauth/usage")!
let KEYCHAIN_SERVICE = "Claude Code-credentials"
let REFRESH_INTERVAL: TimeInterval = 300 // 5 minutes

// One budget reading: spend and (optional) limit in USD, plus percent if known.
struct Usage {
    let percent: Double?
    let used: Double
    let limit: Double?
}

final class AIStatusItem: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let claudeItem = NSMenuItem(title: "Claude Code  …", action: nil, keyEquivalent: "")
    let litellmItem = NSMenuItem(title: "LiteLLM  …", action: nil, keyEquivalent: "")
    let monthItem = NSMenuItem(title: "Month  …", action: nil, keyEquivalent: "")

    // Last bar text for each source; nil = loading, "—" = unavailable.
    private var claudeShort: String?
    private var litellmShort: String?

    // Cached LiteLLM credentials (parsed from env file at startup, refreshed on demand).
    private var baseURL: String?
    private var apiKey: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        updateTitle()

        // Clicking a detail line refreshes just that source.
        let menu = NSMenu()
        for (item, action) in [(claudeItem, #selector(refreshClaude)),
                               (litellmItem, #selector(refreshLiteLLM)),
                               (monthItem, #selector(refreshMonth))] {
            item.action = action
            item.target = self
        }
        menu.addItem(claudeItem)
        menu.addItem(litellmItem)
        menu.addItem(monthItem)
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        refreshNow()
        let t = Timer.scheduledTimer(withTimeInterval: REFRESH_INTERVAL, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        RunLoop.main.add(t, forMode: .common)
    }

    // Fraction of the current calendar month elapsed (0-100), by time, not whole days.
    private func monthPercent(now: Date = Date()) -> Double {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: now) else { return 0 }
        return now.timeIntervalSince(interval.start) / interval.duration * 100
    }

    private func updateTitle() {
        let month = monthPercent()
        monthItem.title = String(format: "Month  %.1f%% elapsed", month)
        statusItem.button?.title = ""
        statusItem.button?.image = stackedImage([
            ("CC", claudeShort ?? "…"),
            ("LL", litellmShort ?? "…"),
            ("MO", String(format: "%.0f%%", month)),
        ])
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.sizeToFit()
    }

    // Render columns of small label on top / bold value below as one template
    // image (the menu bar title is single-line, so two lines need drawing).
    private func stackedImage(_ columns: [(label: String, value: String)]) -> NSImage {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor.black,
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let gap: CGFloat = 10
        let height: CGFloat = 22
        let cells = columns.map { col -> (NSAttributedString, NSAttributedString, CGFloat) in
            let l = NSAttributedString(string: col.label, attributes: labelAttrs)
            let v = NSAttributedString(string: col.value, attributes: valueAttrs)
            return (l, v, ceil(max(l.size().width, v.size().width)))
        }
        let width = cells.reduce(0) { $0 + $1.2 } + gap * CGFloat(max(cells.count - 1, 0))

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            var x: CGFloat = 0
            for (l, v, w) in cells {
                l.draw(at: NSPoint(x: x + (w - l.size().width) / 2, y: -1))
                v.draw(at: NSPoint(x: x + (w - v.size().width) / 2, y: height - v.size().height + 1))
                x += w + gap
            }
            return true
        }
        image.isTemplate = true // follow menu bar light/dark appearance
        return image
    }

    @objc func refreshNow() {
        refreshClaude()
        refreshLiteLLM()
    }

    @objc func refreshClaude() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.fetchClaude { result in self?.apply(result, label: "Claude Code", item: self?.claudeItem) { self?.claudeShort = $0 } }
        }
    }

    @objc func refreshLiteLLM() {
        loadCredentials()
        fetchLiteLLM { [weak self] result in self?.apply(result, label: "LiteLLM", item: self?.litellmItem) { self?.litellmShort = $0 } }
    }

    // Month is computed locally, so "refreshing" it is just a redraw.
    @objc func refreshMonth() {
        updateTitle()
    }

    // Update the menu line and bar text of one source, on the main thread.
    private func apply(_ result: Result<Usage, Error>, label: String, item: NSMenuItem?, setShort: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            switch result {
            case .success(let u):
                let limit = u.limit.map { String(format: "$%.2f", $0) } ?? "∞"
                let pct = u.percent.map { String(format: "%.1f%% · ", $0) } ?? ""
                item?.title = String(format: "%@  $%.2f / %@  (%@updated %@)", label, u.used, limit, pct, time)
                setShort(u.percent.map { String(format: "%.0f%%", $0) } ?? String(format: "$%.2f", u.used))
            case .failure(let error):
                item?.title = "\(label)  unavailable (\((error as NSError).code)) · \(time)"
                setShort("—")
            }
            self.updateTitle()
        }
    }

    // MARK: - Claude Code

    // Token is re-read on every refresh: Claude Code rotates it in the Keychain.
    // Uses /usr/bin/security (absolute path) so PATH does not matter.
    private func readAccessToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }

    private func fetchClaude(_ completion: @escaping (Result<Usage, Error>) -> Void) {
        guard let token = readAccessToken() else {
            completion(.failure(NSError(domain: "Claude", code: 1)))
            return
        }
        var req = URLRequest(url: CLAUDE_USAGE_URL)
        req.timeoutInterval = 6
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeCode/2.1.312", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, resp, error in
            guard error == nil, let data = data else {
                completion(.failure(error ?? NSError(domain: "Claude", code: 3)))
                return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                completion(.failure(NSError(domain: "Claude", code: http.statusCode)))
                return
            }
            // spend: { percent, used: { amount_minor, exponent }, limit: { amount_minor, exponent } }
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let spend = obj["spend"] as? [String: Any],
                  let pct = (spend["percent"] as? NSNumber)?.doubleValue else {
                completion(.failure(NSError(domain: "Claude", code: 4)))
                return
            }
            func usd(_ key: String) -> Double {
                let m = spend[key] as? [String: Any] ?? [:]
                let minor = (m["amount_minor"] as? NSNumber)?.doubleValue ?? 0
                let exp = (m["exponent"] as? NSNumber)?.intValue ?? 2
                return minor / pow(10, Double(exp))
            }
            completion(.success(Usage(percent: pct, used: usd("used"), limit: usd("limit"))))
        }.resume()
    }

    // MARK: - LiteLLM

    // Parse ~/.config/litellm/env lines of the form:  export LITELLM_BASE_URL=<v>
    private func loadCredentials() {
        guard let text = try? String(contentsOfFile: ENV_FILE, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("export ") { s = String(s.dropFirst(7)) }
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes.
            let cleaned = v.count >= 2 && (v.first == "\u{22}" || v.first == "\u{27}") && v.last == v.first
                ? String(v.dropFirst().dropLast())
                : v
            if key == "LITELLM_BASE_URL" { baseURL = cleaned }
            else if key == "LITELLM_API_KEY" { apiKey = cleaned }
        }
    }

    private func fetchLiteLLM(_ completion: @escaping (Result<Usage, Error>) -> Void) {
        guard let baseURL = baseURL, let apiKey = apiKey,
              !baseURL.isEmpty, !apiKey.isEmpty else {
            completion(.failure(NSError(domain: "LiteLLM", code: 1)))
            return
        }
        // Swap litellm.<host> -> api.<host>, strip any path suffix. Same transform as the shell script.
        let apiURL = baseURL.replacingOccurrences(of: #"^https?://litellm\."#, with: "https://api.", options: .regularExpression)
        guard let base = URL(string: apiURL), var url = URL(string: "v1/usage", relativeTo: base) else {
            completion(.failure(NSError(domain: "LiteLLM", code: 2)))
            return
        }
        url = url.absoluteURL

        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: req) { data, resp, error in
            guard error == nil, let data = data else {
                completion(.failure(error ?? NSError(domain: "LiteLLM", code: 3)))
                return
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let spend = (obj["spend"] as? NSNumber)?.doubleValue else {
                completion(.failure(NSError(domain: "LiteLLM", code: 4)))
                return
            }
            let budget = (obj["budget"] as? NSNumber)?.doubleValue
            let pct = budget.flatMap { $0 > 0 ? spend / $0 * 100 : nil }
            completion(.success(Usage(percent: pct, used: spend, limit: budget)))
        }.resume()
    }
}

let app = NSApplication.shared
let delegate = AIStatusItem()
app.delegate = delegate
app.setActivationPolicy(.accessory) // LSUIElement: no Dock icon, menu bar only
app.run()
