import AppKit
import FtopCore

/// Compact native rule editor. It owns presentation and drafts only; the app
/// supplies permission requests, persistence, and verified system transactions.
@MainActor
public final class DNSWiFiRulesPanel: NSObject, NSWindowDelegate {
    public typealias SaveHandler = @MainActor (
        DNSWiFiRulesConfiguration
    ) async throws -> DNSWiFiRulesConfiguration
    public typealias Action = @MainActor () async throws -> Void

    public var onSaveConfiguration: SaveHandler?
    public var onRequestWiFiAccess: Action?
    public var onClosed: (() -> Void)?
    public var isBusy: Bool { actionBusy || externallyBusy }
    public var isShown: Bool { window.isVisible }

    let content = DNSWiFiRulesContent()
    private let window = DNSWiFiRulesWindow()
    private(set) var configuration = DNSWiFiRulesConfiguration.defaults
    private(set) var status = DNSWiFiRulesStatus()
    private var session: UUID?
    private var operation: UUID?
    private var actionBusy = false
    private var externallyBusy = false

    public override init() {
        super.init()
        window.delegate = self
        window.contentView = content
        content.onChange = { [weak self] in
            self?.updateControls()
            self?.fit(keepingTop: true)
        }
        content.onAction = { [weak self] action in self?.activate(action) }
    }

    public func present(
        configuration: DNSWiFiRulesConfiguration,
        status: DNSWiFiRulesStatus, palette: PaletteID, busy: Bool = false
    ) {
        prepare(
            configuration: configuration, status: status, palette: palette,
            busy: busy)
        window.appearance = NSApp.effectiveAppearance
        fit(keepingTop: isShown)
        if !isShown { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func refresh(
        configuration: DNSWiFiRulesConfiguration,
        status: DNSWiFiRulesStatus, palette: PaletteID, busy: Bool = false
    ) {
        guard session != nil else { return }
        externallyBusy = busy
        self.configuration = configuration
        self.status = status
        content.applyPalette(palette)
        if !content.isDirty { content.load(configuration) }
        content.update(status)
        updateControls()
        fit(keepingTop: true)
    }

    public func showError(_ message: String) {
        guard session != nil else { return }
        content.setNotice(String(message.prefix(500)), error: true)
        fit(keepingTop: true)
    }

    @discardableResult
    public func dismiss() -> Bool {
        guard !isBusy else { return false }
        window.close()
        endSession()
        return true
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool { !isBusy }

    public func windowWillClose(_ notification: Notification) {
        if !isBusy { endSession() }
    }

    /// Test/reference entry point that does not order a desktop window.
    func prepare(
        configuration: DNSWiFiRulesConfiguration,
        status: DNSWiFiRulesStatus, palette: PaletteID = .sea,
        busy: Bool = false
    ) {
        externallyBusy = busy
        if session == nil {
            session = UUID()
            content.load(configuration)
        } else if !content.isDirty {
            content.load(configuration)
        }
        self.configuration = configuration
        self.status = status
        content.applyPalette(palette)
        content.update(status)
        updateControls()
        fit(keepingTop: false)
    }

    private func endSession() {
        guard session != nil else { return }
        session = nil
        operation = nil
        onClosed?()
    }

    private func activate(_ action: DNSWiFiRulesContent.Action) {
        switch action {
        case .save: saveConfiguration()
        case .close: _ = dismiss()
        case .requestWiFiAccess: run(onRequestWiFiAccess)
        }
    }

    func saveConfiguration() {
        guard !isBusy, session != nil, let onSaveConfiguration else { return }
        let draft: DNSWiFiRulesConfiguration
        do { draft = try content.draft() } catch {
            showError(Self.message(error))
            return
        }
        actionBusy = true
        let token = UUID()
        operation = token
        content.setNotice(
            Strings.pick(
                "Saving rules and checking the current Wi-Fi…",
                "正在保存规则并检查当前 Wi-Fi…"),
            error: false)
        updateControls()
        Task { [weak self] in
            guard let self else { return }
            defer {
                if operation == token { operation = nil }
                actionBusy = false
                updateControls()
                fit(keepingTop: true)
            }
            do {
                let saved = try await onSaveConfiguration(draft)
                guard operation == token else { return }
                configuration = saved
                content.load(saved)
                content.update(status)
                content.setNotice(
                    Strings.pick(
                        "Rules saved. The status above shows whether the current Wi-Fi could be checked; future matching is event-driven.",
                        "规则已保存；上方状态会显示当前 Wi-Fi 是否已检查，后续匹配由网络事件触发。"),
                    error: false)
            } catch {
                guard operation == token else { return }
                showError(Self.message(error))
            }
        }
    }

    private func run(_ action: Action?) {
        guard !isBusy, session != nil, let action else { return }
        actionBusy = true
        let token = UUID()
        operation = token
        updateControls()
        Task { [weak self] in
            guard let self else { return }
            defer {
                if operation == token { operation = nil }
                actionBusy = false
                updateControls()
                fit(keepingTop: true)
            }
            do { try await action() } catch {
                guard operation == token else { return }
                showError(Self.message(error))
            }
        }
    }

    private func updateControls() {
        content.setControls(
            busy: isBusy, canSave: onSaveConfiguration != nil,
            canGrant: onRequestWiFiAccess != nil)
        window.standardWindowButton(.closeButton)?.isEnabled = !isBusy
    }

    private func fit(keepingTop: Bool) {
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let width = min(
            PanelStyle.dnsRulesWidth,
            (visible?.width ?? PanelStyle.dnsRulesWidth)
                - PanelStyle.dnsRulesPadding * 2)
        let availableHeight =
            (visible?.height ?? .greatestFiniteMagnitude)
            - PanelStyle.dnsRulesPadding * 2
            - (window.frame.height
                - window.contentRect(forFrameRect: window.frame).height)
        let size = content.fittedSize(
            width: width, maximumHeight: availableHeight)
        let top = window.frame.maxY
        window.setContentSize(size)
        if keepingTop {
            window.setFrameTopLeftPoint(
                NSPoint(x: window.frame.minX, y: top))
        }
        if let visible {
            let frame = DNSChangePresentation.constrainedFrame(
                window.frame, to: visible,
                padding: PanelStyle.dnsRulesPadding)
            if frame != window.frame { window.setFrame(frame, display: false) }
        }
    }

    static func message(_ error: Error) -> String {
        guard Strings.chinese,
            let validation = error as? DNSWiFiRulesValidationError
        else { return DNSChangePresentation.message(for: error) }
        switch validation {
        case .emptySSID: return "请为每条规则填写 Wi-Fi 名称。"
        case .invalidSSID:
            return "Wi-Fi 名称不能包含换行、制表符或其他控制字符。"
        case .duplicateID: return "规则标识重复，请删除重复项后重新添加。"
        case .duplicateSSID(let ssid):
            return "Wi-Fi 名称“\(String(ssid.prefix(80)))”重复，请保留一条规则。"
        case .unsupportedVersion:
            return "规则格式不受支持，原有设置已保留。"
        }
    }
}

private final class DNSWiFiRulesWindow: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false)
        title = Strings.pick("Wi-Fi DNS Rules", "Wi-Fi DNS 规则")
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = false
        setAccessibilityIdentifier("ftop.dns.rules")
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
