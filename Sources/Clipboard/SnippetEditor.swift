import AppKit

final class SnippetEditor: NSWindowController {
    private let name = NSTextField()
    private let text = NSTextView()
    private let error = NSTextField(wrappingLabelWithString: "")
    var onSave: ((String, String) -> String?)?
    var onClose: (() -> Void)?

    init(title: String, name: String, text: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        super.init(window: window)
        self.name.stringValue = name
        self.name.placeholderString = "名称（可选）"
        self.text.string = text
        self.text.isRichText = false
        self.text.isAutomaticQuoteSubstitutionEnabled = false
        self.text.isAutomaticDashSubstitutionEnabled = false
        self.text.isAutomaticTextReplacementEnabled = false
        self.text.isAutomaticSpellingCorrectionEnabled = false
        self.text.font = .systemFont(ofSize: 13)
        self.text.textContainerInset = NSSize(width: 10, height: 10)
        self.text.isHorizontallyResizable = false
        self.text.isVerticallyResizable = true
        self.text.autoresizingMask = [.width]
        self.text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        self.text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = self.text; scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false; scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        error.font = .systemFont(ofSize: 11); error.textColor = .systemRed
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal; buttons.spacing = 10
        let stack = NSStackView(views: [self.name, scroll, error, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.distribution = .fill; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            self.name.heightAnchor.constraint(equalToConstant: 26),
            error.heightAnchor.constraint(equalToConstant: 28),
            buttons.heightAnchor.constraint(equalToConstant: 30)
        ])
        for view in [self.name, scroll, error, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    func showSheet(for parent: NSWindow) {
        parent.beginSheet(window!)
        window?.makeFirstResponder(text)
    }
    @objc private func save() {
        do { _ = try SnippetStore.validatedTitle(name.stringValue, text: text.string) }
        catch { self.error.stringValue = error.localizedDescription; return }
        if let message = onSave?(name.stringValue, text.string) { error.stringValue = message; return }
        cancel()
    }
    @objc private func cancel() {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        window?.orderOut(nil)
        onClose?()
    }
}
