import AppKit
import FtopCore

@MainActor
final class DNSWiFiRulesContent: NSView {
    enum Action { case save, close, requestWiFiAccess }

    var onAction: ((Action) -> Void)?
    var onChange: (() -> Void)?
    private(set) var isDirty = false
    private(set) var rows: [DNSWiFiRuleView] = []
    let defaultRule = DNSWiFiRuleView(defaultMode: .automatic)

    let enabled = NSSwitch(frame: .zero)
    let add = NSButton(
        title: Strings.pick("Add", "添加"), target: nil, action: nil)
    let useCurrent = NSButton(
        title: Strings.pick("Current Wi-Fi", "当前 Wi-Fi"), target: nil,
        action: nil)
    let grant = NSButton(
        title: Strings.pick("Wi-Fi Access…", "Wi-Fi 权限…"), target: nil,
        action: nil)
    let save = NSButton(
        title: Strings.pick("Save & Apply", "保存并应用"), target: nil, action: nil)
    let close = NSButton(
        title: Strings.pick("Close", "关闭"), target: nil, action: nil)
    let notice = NSTextField(wrappingLabelWithString: "")
    let phase = NSTextField(labelWithString: "")
    let rulesScroll = NSScrollView()

    private let statusCard = NSView()
    private let statusDot = NSView()
    private let identity = NSTextField(wrappingLabelWithString: "")
    private let dns = NSTextField(wrappingLabelWithString: "")
    private let statusMessage = NSTextField(wrappingLabelWithString: "")
    private let enabledLabel = NSTextField(
        labelWithString: Strings.pick(
            "Automatic switching", "自动切换"))
    private let ruleHelp = NSTextField(
        wrappingLabelWithString: Strings.pick(
            "Exact Wi-Fi rules override the default. An unreadable Wi-Fi name is left unchanged. Automatic removes only manual DNS addresses.",
            "精确 Wi-Fi 规则优先于默认规则；无法读取 Wi-Fi 名称时保持不变。“自动获取”只删除手动 DNS 地址。"
        ))
    private let stack = NSStackView()
    private let rules = NSStackView()
    private let empty = NSTextField(
        wrappingLabelWithString: Strings.pick(
            "No exact rules. The default rule handles every other identifiable Wi-Fi.",
            "没有精确规则。其他可识别的 Wi-Fi 均使用默认规则。"))
    private let progress = NSProgressIndicator()
    private var rulesHeight: NSLayoutConstraint!
    private var status = DNSWiFiRulesStatus()
    private var busy = false
    private var palette = PaletteID.sea
    var identityText: String { identity.stringValue }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PanelStyle.dnsRulesGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: PanelStyle.dnsRulesPadding),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -PanelStyle.dnsRulesPadding),
            stack.topAnchor.constraint(
                equalTo: topAnchor, constant: PanelStyle.dnsRulesPadding),
        ])

        configureStatusCard()
        addFullWidth(statusCard)

        defaultRule.onChange = { [weak self] in self?.changed() }
        addFullWidth(defaultRule)

        configure(add, action: #selector(addAction), identifier: "add")
        configure(
            useCurrent, action: #selector(useCurrentAction),
            identifier: "use-current")
        configure(
            grant, action: #selector(grantAction), identifier: "grant")
        let rulesTitle = heading(
            Strings.pick("Exact Wi-Fi rules", "精确 Wi-Fi 规则"))
        addFullWidth(rulesTitle)
        addFullWidth(horizontal([grant, spacer(), add, useCurrent]))

        rulesScroll.hasVerticalScroller = true
        rulesScroll.autohidesScrollers = true
        rulesScroll.borderType = .noBorder
        rulesScroll.drawsBackground = false
        rulesScroll.setAccessibilityIdentifier("ftop.dns.rules.list")
        addFullWidth(rulesScroll)
        rulesHeight = rulesScroll.heightAnchor.constraint(
            equalToConstant: PanelStyle.dnsRulesRulesHeight)
        rulesHeight.isActive = true

        let document = DNSWiFiRulesDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        rulesScroll.documentView = document
        rules.orientation = .vertical
        rules.alignment = .leading
        rules.spacing = PanelStyle.dnsRulesRuleGap
        rules.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rules)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(
                equalTo: rulesScroll.contentView.widthAnchor),
            rules.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rules.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rules.topAnchor.constraint(equalTo: document.topAnchor),
            rules.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        for label in [ruleHelp, notice] {
            label.font = .systemFont(ofSize: PanelStyle.controlValueSize)
            label.textColor = PanelStyle.secondaryColor
            label.maximumNumberOfLines = 3
            label.lineBreakMode = .byWordWrapping
        }
        notice.setAccessibilityIdentifier("ftop.dns.rules.notice")
        notice.isHidden = true
        addFullWidth(ruleHelp)
        addFullWidth(notice)

        configure(close, action: #selector(closeAction), identifier: "close")
        configure(save, action: #selector(saveAction), identifier: "save")
        close.keyEquivalent = "\u{1b}"
        save.keyEquivalent = "\r"
        addFullWidth(horizontal([spacer(), close, save]))
        updateEmptyState()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func applyPalette(_ value: PaletteID) {
        palette = value
        updateAppearance()
    }

    func load(_ configuration: DNSWiFiRulesConfiguration) {
        for row in rows {
            rules.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        rows = []
        enabled.state = configuration.enabled ? .on : .off
        defaultRule.loadMode(configuration.defaultMode)
        configuration.rules.forEach(append)
        isDirty = false
        setNotice("", error: false)
        updateEmptyState()
        layoutSubtreeIfNeeded()
        rulesScroll.contentView.scroll(to: .zero)
        rulesScroll.reflectScrolledClipView(rulesScroll.contentView)
    }

    func draft() throws -> DNSWiFiRulesConfiguration {
        try DNSWiFiRulesConfiguration(
            enabled: enabled.state == .on,
            defaultMode: try defaultRule.modeValue(),
            rules: rows.map { try $0.rule() }
        ).validated()
    }

    func update(_ status: DNSWiFiRulesStatus) {
        self.status = status
        phase.stringValue = Self.phaseName(status.phase)
        phase.textColor = Self.phaseColor(status.phase)
        statusDot.layer?.backgroundColor = Self.phaseColor(status.phase).cgColor

        let ssid =
            status.ssid.map { "\u{201c}\($0)\u{201d}" }
            ?? Strings.pick("Unknown Wi-Fi", "未知 Wi-Fi")
        let matched =
            status.usesDefault
            ? Strings.pick("Default DNS", "默认 DNS")
            : status.matchedSSID.map { "\u{201c}\($0)\u{201d}" }
                ?? Strings.pick("Waiting", "等待匹配")
        identity.stringValue =
            Strings.pick("Wi-Fi: ", "Wi-Fi：") + ssid + "  ·  "
            + Strings.pick("Rule: ", "规则：") + matched
        identity.toolTip = identity.stringValue

        var shown = status.servers.prefix(3).joined(separator: ", ")
        if status.servers.count > 3 {
            shown += Strings.pick(
                " (+\(status.servers.count - 3) more)",
                "（另 \(status.servers.count - 3) 项）")
        }
        dns.stringValue =
            Strings.pick("Current DNS: ", "当前 DNS：")
            + (shown.isEmpty ? Strings.pick("Unavailable", "不可用") : shown)
        dns.toolTip = status.servers.joined(separator: "\n")
        statusMessage.stringValue = String(status.message.prefix(500))
        statusMessage.toolTip = status.message
        statusMessage.isHidden = status.message.isEmpty
        useCurrent.isEnabled = !busy && status.ssid?.isEmpty == false
        if status.phase == .applying || busy {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
    }

    func setControls(busy: Bool, canSave: Bool, canGrant: Bool) {
        self.busy = busy
        enabled.isEnabled = !busy
        add.isEnabled = !busy
        useCurrent.isEnabled = !busy && status.ssid?.isEmpty == false
        grant.isEnabled = canGrant && !busy
        save.isEnabled = canSave && !busy
        close.isEnabled = !busy
        defaultRule.setEnabled(!busy)
        rows.forEach { $0.setEnabled(!busy) }
        if status.phase == .applying || busy {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
    }

    func setNotice(_ text: String, error: Bool) {
        notice.stringValue = text
        notice.toolTip = text
        notice.textColor =
            error
            ? PanelStyle.criticalColor : PanelStyle.secondaryColor
        notice.isHidden = text.isEmpty
        stack.invalidateIntrinsicContentSize()
    }

    func fittedSize(
        width: CGFloat, maximumHeight: CGFloat = .greatestFiniteMagnitude
    ) -> NSSize {
        enabledLabel.isHidden =
            width <= PanelStyle.dnsRulesCompactWidth + 1
        frame.size.width = width
        let textWidth = width - PanelStyle.dnsRulesPadding * 2
        defaultRule.prepareLayout(width: textWidth)
        for label in [identity, dns, statusMessage, ruleHelp, notice] {
            label.preferredMaxLayoutWidth = textWidth
        }
        rulesHeight.constant = min(
            PanelStyle.dnsRulesRulesHeight,
            max(
                PanelStyle.dnsRulesRulesMinimumHeight,
                rules.fittingSize.height))
        stack.invalidateIntrinsicContentSize()
        layoutSubtreeIfNeeded()
        var height = ceil(stack.fittingSize.height) + PanelStyle.dnsRulesPadding * 2
        if height > maximumHeight {
            rulesHeight.constant = max(
                PanelStyle.dnsRulesRulesMinimumHeight,
                rulesHeight.constant - (height - maximumHeight))
            stack.invalidateIntrinsicContentSize()
            layoutSubtreeIfNeeded()
            height = ceil(stack.fittingSize.height) + PanelStyle.dnsRulesPadding * 2
        }
        let size = NSSize(width: width, height: height)
        frame.size = size
        layoutSubtreeIfNeeded()
        defaultRule.syncTextGeometry()
        rows.forEach { $0.syncTextGeometry() }
        return size
    }

    func changed() {
        isDirty = true
        setNotice(
            Strings.pick(
                "Save to check the current Wi-Fi now. Exact rules win; every other identifiable Wi-Fi uses the default.",
                "保存后会立即检查当前 Wi-Fi。精确规则优先，其他可识别 Wi-Fi 使用默认规则。"),
            error: false)
        onChange?()
    }

    private func configureStatusCard() {
        statusCard.wantsLayer = true
        statusCard.layer?.cornerRadius = PanelStyle.dnsRulesCardCorner

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = PanelStyle.dnsRulesStatusDot / 2
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(
                equalToConstant: PanelStyle.dnsRulesStatusDot),
            statusDot.heightAnchor.constraint(
                equalToConstant: PanelStyle.dnsRulesStatusDot),
        ])

        phase.font = .systemFont(
            ofSize: PanelStyle.controlTitleSize, weight: .semibold)
        phase.lineBreakMode = .byTruncatingTail
        phase.maximumNumberOfLines = 1
        phase.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)
        phase.setAccessibilityIdentifier("ftop.dns.rules.phase")
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        NSLayoutConstraint.activate([
            progress.widthAnchor.constraint(
                equalToConstant: PanelStyle.dnsRulesProgressSize),
            progress.heightAnchor.constraint(
                equalToConstant: PanelStyle.dnsRulesProgressSize),
        ])

        enabledLabel.font = .systemFont(ofSize: PanelStyle.controlValueSize)
        enabled.target = self
        enabled.action = #selector(enabledChanged)
        enabled.setAccessibilityIdentifier("ftop.dns.rules.enabled")
        enabled.setAccessibilityLabel(
            Strings.pick("Automatic switching", "自动切换"))

        let heading = horizontal([
            statusDot, phase, spacer(), progress, enabledLabel, enabled,
        ])
        for label in [identity, dns, statusMessage] {
            label.font = .systemFont(ofSize: PanelStyle.controlValueSize)
            label.textColor = PanelStyle.secondaryColor
            label.maximumNumberOfLines = 3
            label.lineBreakMode = .byWordWrapping
        }
        identity.setAccessibilityIdentifier("ftop.dns.rules.identity")
        dns.setAccessibilityIdentifier("ftop.dns.rules.current-dns")
        statusMessage.setAccessibilityIdentifier("ftop.dns.rules.message")
        statusMessage.isHidden = true

        let cardStack = NSStackView(views: [heading, identity, dns, statusMessage])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = PanelStyle.controlLabelGap
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        statusCard.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.leadingAnchor.constraint(
                equalTo: statusCard.leadingAnchor,
                constant: PanelStyle.dnsRulesCardInset),
            cardStack.trailingAnchor.constraint(
                equalTo: statusCard.trailingAnchor,
                constant: -PanelStyle.dnsRulesCardInset),
            cardStack.topAnchor.constraint(
                equalTo: statusCard.topAnchor,
                constant: PanelStyle.dnsRulesCardInset),
            cardStack.bottomAnchor.constraint(
                equalTo: statusCard.bottomAnchor,
                constant: -PanelStyle.dnsRulesCardInset),
            heading.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            identity.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            dns.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            statusMessage.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
        ])
    }

    private func append(_ rule: DNSWiFiRule) {
        let row = DNSWiFiRuleView(rule)
        row.onChange = { [weak self] in self?.changed() }
        row.onDelete = { [weak self, weak row] in
            guard let self, let row else { return }
            rules.removeArrangedSubview(row)
            row.removeFromSuperview()
            rows.removeAll { $0 === row }
            updateEmptyState()
            changed()
        }
        rows.append(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        rules.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rules.widthAnchor).isActive = true
    }

    private func updateEmptyState() {
        if rows.isEmpty {
            if !rules.arrangedSubviews.contains(empty) {
                empty.font = .systemFont(ofSize: PanelStyle.controlValueSize)
                empty.textColor = PanelStyle.secondaryColor
                empty.alignment = .center
                empty.maximumNumberOfLines = 2
                empty.translatesAutoresizingMaskIntoConstraints = false
                rules.addArrangedSubview(empty)
                empty.widthAnchor.constraint(equalTo: rules.widthAnchor).isActive = true
                empty.heightAnchor.constraint(
                    greaterThanOrEqualToConstant:
                        PanelStyle.dnsRulesRulesMinimumHeight
                ).isActive = true
            }
        } else if rules.arrangedSubviews.contains(empty) {
            rules.removeArrangedSubview(empty)
            empty.removeFromSuperview()
        }
    }

    private func reveal(_ row: DNSWiFiRuleView) {
        layoutSubtreeIfNeeded()
        row.syncTextGeometry()
        _ = row.scrollToVisible(row.bounds)
        rulesScroll.reflectScrolledClipView(rulesScroll.contentView)
    }

    private func updateAppearance() {
        layer?.backgroundColor = PanelStyle.controlColor.cgColor
        statusCard.layer?.backgroundColor = PanelStyle.controlDiscColor.cgColor
        let accent = PanelStyle(palette: palette).performanceColor
        save.bezelColor = accent
        statusDot.layer?.backgroundColor = Self.phaseColor(status.phase).cgColor
        defaultRule.updateAppearance()
        rows.forEach { $0.updateAppearance() }
    }

    private func configure(
        _ button: NSButton, action: Selector, identifier: String
    ) {
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier("ftop.dns.rules." + identifier)
    }

    private func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(
            ofSize: PanelStyle.controlTitleSize, weight: .semibold)
        return label
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = PanelStyle.dnsRulesButtonGap
        return row
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func addFullWidth(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @objc private func enabledChanged() { changed() }

    @objc private func addAction() {
        append(DNSWiFiRule(ssid: "", mode: .automatic))
        updateEmptyState()
        changed()
        if let row = rows.last {
            reveal(row)
            window?.makeFirstResponder(row.ssid)
        }
    }

    @objc private func useCurrentAction() {
        guard let ssid = status.ssid, !ssid.isEmpty else { return }
        if let row = rows.first(where: { $0.ssid.stringValue == ssid }) {
            reveal(row)
            window?.makeFirstResponder(row.ssid)
            return
        }
        enabled.state = .on
        append(DNSWiFiRule(ssid: ssid, mode: .automatic))
        updateEmptyState()
        changed()
        if let row = rows.last {
            reveal(row)
            window?.makeFirstResponder(row.mode)
        }
    }

    @objc private func grantAction() { onAction?(.requestWiFiAccess) }
    @objc private func saveAction() { onAction?(.save) }
    @objc private func closeAction() { onAction?(.close) }

    static func phaseName(_ phase: DNSWiFiRulesStatus.Phase) -> String {
        switch phase {
        case .off: Strings.pick("Automatic DNS is off", "自动 DNS 已关闭")
        case .waiting: Strings.pick("Waiting for Wi-Fi", "等待 Wi-Fi")
        case .needsWiFiAccess:
            Strings.pick("Wi-Fi name access required", "需要读取 Wi-Fi 名称")
        case .needsNetworkAuthorization:
            Strings.pick("Network authorization required", "需要网络授权")
        case .applying: Strings.pick("Applying DNS…", "正在应用 DNS…")
        case .active: Strings.pick("Rule active", "规则已生效")
        case .blocked: Strings.pick("Automatic DNS stopped", "自动 DNS 已停止")
        }
    }

    static func phaseColor(_ phase: DNSWiFiRulesStatus.Phase) -> NSColor {
        switch phase {
        case .active: PanelStyle.normalColor
        case .blocked: PanelStyle.criticalColor
        case .needsWiFiAccess, .needsNetworkAuthorization:
            PanelStyle.warningColor
        default: PanelStyle.secondaryColor
        }
    }
}

private final class DNSWiFiRulesDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class DNSWiFiRuleView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    var onChange: (() -> Void)?
    var onDelete: (() -> Void)?
    let ssid: NSTextField
    let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    let addresses = NSTextView()
    let remove = NSButton(title: "−", target: nil, action: nil)
    let id: UUID
    let isDefault: Bool

    private let addressScroll = NSScrollView()
    private let defaultDescription = NSTextField(
        wrappingLabelWithString: Strings.pick(
            "Used when no exact Wi-Fi rule matches. This rule cannot be removed.",
            "未命中精确 Wi-Fi 规则时使用；此规则无法删除。"))
    let priorityHelp = NSTextField(
        wrappingLabelWithString: Strings.pick(
            "Put the preferred DNS first and the alternate second. macOS may choose any available resolver; strict failover is not guaranteed.",
            "第一行填写首选 DNS，第二行填写备用 DNS。macOS 可能选择任一可用解析器，不保证严格主备切换。"))
    private var enabled = true

    convenience init(_ rule: DNSWiFiRule) {
        self.init(rule: rule, isDefault: false)
    }

    convenience init(defaultMode: DNSManualMode) {
        self.init(
            rule: DNSWiFiRule(ssid: "", mode: defaultMode),
            isDefault: true)
    }

    private init(rule: DNSWiFiRule, isDefault: Bool) {
        id = rule.id
        self.isDefault = isDefault
        ssid =
            isDefault
            ? NSTextField(
                labelWithString: Strings.pick("Default DNS", "默认 DNS"))
            : NSTextField(string: rule.ssid)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = PanelStyle.dnsRulesCardCorner

        let identifier =
            isDefault
            ? "ftop.dns.rules.default"
            : "ftop.dns.rules.rule." + rule.id.uuidString
        if isDefault {
            ssid.font = .systemFont(
                ofSize: PanelStyle.controlTitleSize, weight: .semibold)
        } else {
            ssid.placeholderString = Strings.pick(
                "Exact Wi-Fi name", "Wi-Fi 名称（精确匹配）")
            ssid.delegate = self
        }
        ssid.setAccessibilityIdentifier(identifier + ".ssid")
        ssid.setAccessibilityLabel(
            isDefault
                ? Strings.pick("Default DNS rule", "默认 DNS 规则")
                : Strings.pick("Wi-Fi name", "Wi-Fi 名称"))
        ssid.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        remove.target = self
        remove.action = #selector(removeAction)
        remove.bezelStyle = .circular
        remove.setAccessibilityIdentifier(identifier + ".remove")
        remove.setAccessibilityLabel(Strings.pick("Remove rule", "删除规则"))
        remove.isHidden = isDefault
        NSLayoutConstraint.activate([
            remove.widthAnchor.constraint(equalToConstant: PanelStyle.controlDisc),
            remove.heightAnchor.constraint(equalToConstant: PanelStyle.controlDisc),
        ])
        let titleRow = NSStackView(
            views: isDefault ? [ssid] : [ssid, remove])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = PanelStyle.dnsRulesButtonGap

        mode.addItems(withTitles: [
            Strings.pick(
                "Automatic (remove manual addresses)",
                "自动获取（删除手动地址）"),
            Strings.pick("Custom DNS", "自定义 DNS"),
        ])
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setAccessibilityIdentifier(identifier + ".mode")
        mode.setAccessibilityLabel(Strings.pick("DNS mode", "DNS 获取方式"))

        addressScroll.borderType = .noBorder
        addressScroll.hasVerticalScroller = true
        addressScroll.autohidesScrollers = true
        addressScroll.drawsBackground = true
        addressScroll.backgroundColor = PanelStyle.cardColor
        addressScroll.documentView = addresses
        addresses.isRichText = false
        addresses.isAutomaticQuoteSubstitutionEnabled = false
        addresses.isAutomaticDashSubstitutionEnabled = false
        addresses.isAutomaticTextReplacementEnabled = false
        addresses.isAutomaticSpellingCorrectionEnabled = false
        addresses.isContinuousSpellCheckingEnabled = false
        addresses.isVerticallyResizable = true
        addresses.isHorizontallyResizable = false
        addresses.autoresizingMask = [.width]
        addresses.textContainer?.widthTracksTextView = true
        addresses.font = .monospacedSystemFont(
            ofSize: PanelStyle.dnsRulesAddressSize, weight: .regular)
        addresses.delegate = self
        addresses.setAccessibilityIdentifier(identifier + ".addresses")
        addresses.setAccessibilityLabel(
            Strings.pick("DNS server addresses", "DNS 服务器地址"))
        addressScroll.heightAnchor.constraint(
            equalToConstant: PanelStyle.dnsRulesAddressHeight
        ).isActive = true

        for label in [defaultDescription, priorityHelp] {
            label.font = .systemFont(ofSize: PanelStyle.controlValueSize)
            label.textColor = PanelStyle.secondaryColor
            label.maximumNumberOfLines = 3
            label.lineBreakMode = .byWordWrapping
        }
        defaultDescription.setAccessibilityIdentifier(
            identifier + ".description")
        priorityHelp.setAccessibilityIdentifier(identifier + ".priority-help")

        var contentViews: [NSView] = [titleRow]
        if isDefault { contentViews.append(defaultDescription) }
        contentViews.append(contentsOf: [mode, addressScroll])
        if isDefault { contentViews.append(priorityHelp) }
        let content = NSStackView(views: contentViews)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = PanelStyle.controlLabelGap
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: PanelStyle.dnsRulesCardInset),
            content.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -PanelStyle.dnsRulesCardInset),
            content.topAnchor.constraint(
                equalTo: topAnchor, constant: PanelStyle.dnsRulesCardInset),
            content.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -PanelStyle.dnsRulesCardInset),
            titleRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            mode.widthAnchor.constraint(equalTo: content.widthAnchor),
            addressScroll.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        if isDefault {
            NSLayoutConstraint.activate([
                defaultDescription.widthAnchor.constraint(
                    equalTo: content.widthAnchor),
                priorityHelp.widthAnchor.constraint(
                    equalTo: content.widthAnchor),
            ])
        }

        load(rule.mode)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func rule() throws -> DNSWiFiRule {
        precondition(!isDefault)
        let value = try modeValue()
        return DNSWiFiRule(id: id, ssid: ssid.stringValue, mode: value)
    }

    func modeValue() throws -> DNSManualMode {
        mode.indexOfSelectedItem == 0
            ? .automatic : .custom(try DNSAddressList.parse(addresses.string))
    }

    func loadMode(_ value: DNSManualMode) { load(value) }

    func setEnabled(_ value: Bool) {
        enabled = value
        ssid.isEnabled = isDefault || value
        remove.isEnabled = value && !isDefault
        mode.isEnabled = value
        updateEditing()
    }

    func syncTextGeometry() {
        addresses.minSize = NSSize(
            width: 0, height: addressScroll.contentSize.height)
        addresses.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        addresses.frame.size.width = addressScroll.contentSize.width
        addresses.textContainer?.containerSize = NSSize(
            width: addressScroll.contentSize.width,
            height: .greatestFiniteMagnitude)
        if let container = addresses.textContainer,
            let layout = addresses.layoutManager
        {
            layout.ensureLayout(for: container)
            addresses.frame.size.height = max(
                addressScroll.contentSize.height,
                ceil(layout.usedRect(for: container).maxY)
                    + addresses.textContainerInset.height * 2)
        }
    }

    func prepareLayout(width: CGFloat) {
        guard isDefault else { return }
        let textWidth = max(0, width - PanelStyle.dnsRulesCardInset * 2)
        defaultDescription.preferredMaxLayoutWidth = textWidth
        priorityHelp.preferredMaxLayoutWidth = textWidth
    }

    func updateAppearance() {
        layer?.backgroundColor = PanelStyle.controlDiscColor.cgColor
        addressScroll.backgroundColor = PanelStyle.cardColor
    }

    private func load(_ value: DNSManualMode) {
        switch value {
        case .automatic:
            mode.selectItem(at: 0)
            addresses.string = ""
        case .custom(let servers):
            mode.selectItem(at: 1)
            addresses.string = servers.joined(separator: "\n")
        }
        updateEditing()
    }

    private func updateEditing() {
        let custom = mode.indexOfSelectedItem == 1
        addressScroll.isHidden = !custom
        priorityHelp.isHidden = !isDefault || !custom
        addresses.isEditable = enabled && custom
        addresses.isSelectable = custom
        addresses.textColor = PanelStyle.inkColor
    }

    @objc private func modeChanged() {
        updateEditing()
        onChange?()
    }

    @objc private func removeAction() { onDelete?() }
    func controlTextDidChange(_ notification: Notification) { onChange?() }
    func textDidChange(_ notification: Notification) { onChange?() }
}
