import AppKit
import ServiceManagement
import WebKit

let popoverWidth: CGFloat = 900
/// The dashboard is laid out for a browser window; scale it down to fit the popover.
let pageZoom: CGFloat = 0.78
let maxPopoverHeight: CGFloat = 720
let appScheme = "agentsmonitor"
let statusItemName = "AgentsMonitor"
/// Distance from the right screen edge, in points.
let defaultStatusItemPosition = 220

/// Serves index.html and the /api/* routes to the embedded web view, mirroring server.js.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    private let monitor: Monitor
    private var activeTasks = Set<ObjectIdentifier>()

    init(monitor: Monitor) {
        self.monitor = monitor
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        activeTasks.insert(ObjectIdentifier(task))
        guard let url = task.request.url else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let param = { (name: String) in query.first { $0.name == name }?.value }
        let method = task.request.httpMethod ?? "GET"

        switch (method, url.path) {
        case ("GET", "/"), ("GET", ""):
            let file = Bundle.main.url(forResource: "index", withExtension: "html")
            let html = file.flatMap { try? Data(contentsOf: $0) } ?? Data("index.html missing".utf8)
            respond(task, data: html, contentType: "text/html; charset=utf-8")

        case ("GET", "/api/state"):
            respondJSON(task, monitor.publicState())

        case ("GET", "/api/candidates"):
            respondJSON(task, ["candidates": monitor.candidates(for: param("provider").flatMap(Provider.init(rawValue:)) ?? .claude)])

        case ("POST", "/api/accounts"):
            guard let dir = param("configDir"), !dir.isEmpty else {
                return respondJSON(task, ["error": "configDir is required"], status: 400)
            }
            let provider = param("provider").flatMap(Provider.init(rawValue:)) ?? .claude
            monitor.addAccount(provider: provider, dir: dir) { error in
                if let error {
                    self.respondJSON(task, ["error": error], status: 400)
                } else {
                    self.respondJSON(task, self.monitor.publicState(), status: 201)
                }
            }

        case ("DELETE", "/api/accounts"):
            if monitor.removeAccount(param("configDir") ?? "") {
                respondJSON(task, monitor.publicState())
            } else {
                respondJSON(task, ["error": "Unknown account"], status: 404)
            }

        case ("POST", "/api/refresh"):
            monitor.refreshAll()
            respondJSON(task, ["ok": true], status: 202)

        case ("GET", "/api/app"):
            respondJSON(task, ["launchAtLogin": SMAppService.mainApp.status == .enabled])

        case ("POST", "/api/launch-at-login"):
            do {
                if param("enabled") == "1" {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                respondJSON(task, ["launchAtLogin": SMAppService.mainApp.status == .enabled])
            } catch {
                respondJSON(task, ["error": error.localizedDescription], status: 500)
            }

        case ("POST", "/api/quit"):
            respondJSON(task, ["ok": true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }

        default:
            respondJSON(task, ["error": "Not found"], status: 404)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(task))
    }

    private func respondJSON(_ task: WKURLSchemeTask, _ object: Any, status: Int = 200) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        respond(task, data: data, contentType: "application/json", status: status)
    }

    private func respond(_ task: WKURLSchemeTask, data: Data, contentType: String, status: Int = 200) {
        // Calling into a task WebKit already stopped raises an exception.
        guard activeTasks.remove(ObjectIdentifier(task)) != nil, let url = task.request.url else { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType, "Cache-Control": "no-store"]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKUIDelegate {
    private let monitor = Monitor()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var webView: WKWebView!
    private var schemeHandler: SchemeHandler!
    private var timers: [Timer] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--enable-launch-at-login` registers the login item and quits (for scripted installs).
        if CommandLine.arguments.contains("--enable-launch-at-login") {
            do {
                try SMAppService.mainApp.register()
            } catch {
                FileHandle.standardError.write(Data("Could not register login item: \(error.localizedDescription)\n".utf8))
            }
            exit(SMAppService.mainApp.status == .enabled ? 0 : 1)
        }

        installEditMenu()
        setUpWebView()

        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentSize = NSSize(width: popoverWidth, height: 300)
        let controller = NSViewController()
        controller.view = webView
        popover.contentViewController = controller

        // New status items are inserted at the far left, which menu bar managers like
        // Thaw treat as their hidden section. Start near the right edge instead; macOS
        // remembers wherever the user drags it afterwards.
        let positionKey = "NSStatusItem Preferred Position \(statusItemName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(defaultStatusItemPosition, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = statusItemName
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        updateStatusItem()

        monitor.onChange = { [weak self] in self?.updateStatusItem() }
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.monitor.tick()
        })
        // Blocked accounts become usable again purely by time passing.
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateStatusItem()
        })
        monitor.tick()
    }

    // Accessory apps have no menu bar, so copy/paste shortcuts need a hidden Edit menu.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func setUpWebView() {
        let configuration = WKWebViewConfiguration()
        schemeHandler = SchemeHandler(monitor: monitor)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: appScheme)
        configuration.userContentController.add(self, name: "resize")

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: 300), configuration: configuration)
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.pageZoom = pageZoom
        webView.load(URLRequest(url: URL(string: "\(appScheme)://app/?embedded=1")!))
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        webView.evaluateJavaScript("load()")
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Status item

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let bars = monitor.accounts.map { account in
            (headroom: account.headroom, blocked: account.isBlocked)
        }
        button.image = Self.renderBars(bars)
        button.toolTip = monitor.accounts.map { account in
            let name = "\(account.provider.displayName) · \(account.displayName)"
            if account.isBlocked { return "\(name): blocked" }
            guard let headroom = account.headroom else { return "\(name): no data" }
            return "\(name): \(Int(headroom.rounded()))% left"
        }.joined(separator: "\n")
    }

    /// One vertical bar per account, filled to its lowest remaining account-wide limit.
    private static func renderBars(_ bars: [(headroom: Double?, blocked: Bool)]) -> NSImage {
        let barWidth: CGFloat = 4
        let gap: CGFloat = 3
        let height: CGFloat = 16
        let count = max(bars.count, 1)
        let width = CGFloat(count) * barWidth + CGFloat(count - 1) * gap

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            for (index, bar) in bars.enumerated() {
                let x = CGFloat(index) * (barWidth + gap)
                let track = NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barWidth, height: height), xRadius: 1.5, yRadius: 1.5)
                (bar.blocked ? NSColor.systemRed.withAlphaComponent(0.55) : NSColor.labelColor.withAlphaComponent(0.35)).setFill()
                track.fill()

                guard !bar.blocked, let headroom = bar.headroom else { continue }
                let fillHeight = max(2, height * CGFloat(headroom) / 100)
                let fill = NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barWidth, height: fillHeight), xRadius: 1.5, yRadius: 1.5)
                let color: NSColor = headroom <= 25 ? .systemRed : headroom <= 50 ? .systemOrange : .systemGreen
                color.setFill()
                fill.fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Web view bridge

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "resize", let cssHeight = (message.body as? NSNumber)?.doubleValue else { return }
        let height = CGFloat(cssHeight) * pageZoom
        popover.contentSize = NSSize(width: popoverWidth, height: min(height, maxPopoverHeight))
        writeSnapshotIfRequested(height: height)
    }

    /// `--snapshot <path>` renders the popover content to a PNG and quits (used for visual checks).
    private var snapshotScheduled = false

    private func writeSnapshotIfRequested(height: CGFloat) {
        webView.frame.size = NSSize(width: popoverWidth, height: min(height, maxPopoverHeight))
        let arguments = CommandLine.arguments
        guard !snapshotScheduled, let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count else { return }
        snapshotScheduled = true
        let path = arguments[flag + 1]
        if let image = statusItem.button?.image, let tiff = image.tiffRepresentation {
            try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path + ".status.png"))
        }
        // Give every account time to finish its first fetch, then re-render and capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            self.webView.evaluateJavaScript("load()")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.webView.takeSnapshot(with: nil) { image, _ in
                    if let tiff = image?.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
