import AppKit

final class HistoryWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let search = NSSearchField()
    private let table = HistoryTable()
    private let preview = NSTextView()
    private let imagePreview = NSImageView()
    private let textDetail = NSScrollView()
    private let thumbnails = NSCache<NSString, NSImage>()
    private var previewedImage: String?
    private let count = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let section = NSSegmentedControl(labels: ["历史记录", "常用文本"], trackingMode: .selectOne, target: nil, action: nil)
    private let saveSnippetButton = NSButton(title: "存为常用文本", target: nil, action: nil)
    private let addSnippetButton = NSButton(title: "新增", target: nil, action: nil)
    private let editSnippetButton = NSButton(title: "编辑", target: nil, action: nil)
    private let deleteSnippetButton = NSButton(title: "删除", target: nil, action: nil)
    private var snippets: [TextSnippet] = []
    private var snippetEditor: SnippetEditor?
    private var showingSnippets: Bool { section.selectedSegment == 1 }
    private let help = NSTextField(labelWithString: "↑↓ 选择  ·  Return 复制  ·  ⌘F 搜索  ·  Esc 关闭")
    private var entries: [HistoryEntry] = []
    private var all: [HistoryEntry] = []
    var onCopy: ((HistoryEntry) -> Void)?
    var onDismiss: (() -> Void)?
    var onSaveSnippet: ((UUID?, String, String) -> String?)?
    var onDeleteSnippet: ((UUID) -> String?)?
    init() {
        let panelSize = NSSize(width: 760, height: 620)
        let window = HistoryPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "剪贴板历史"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear; window.isOpaque = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.animationBehavior = .utilityWindow
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        backdrop.material = .hudWindow; backdrop.blendingMode = .withinWindow; backdrop.state = .active
        backdrop.wantsLayer = true; backdrop.layer?.cornerRadius = 14; backdrop.layer?.masksToBounds = true
        window.contentView = backdrop

        window.onCommand = { [weak self] event in
            guard let self else { return false }
            guard self.window?.attachedSheet == nil else { return false }
            if event.keyCode == 53 { self.dismiss(); return true }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                if event.charactersIgnoringModifiers == "f" {
                    self.window?.makeFirstResponder(self.search); return true
                }
                if event.charactersIgnoringModifiers == "c", self.window?.firstResponder === self.table {
                    self.copySelected(); return true
                }
            }
            return false
        }
        search.placeholderString = "搜索文本、图片和尺寸…"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        section.selectedSegment = 0; section.target = self; section.action = #selector(changeSection)
        saveSnippetButton.target = self; saveSnippetButton.action = #selector(saveSelectedAsSnippet)
        addSnippetButton.target = self; addSnippetButton.action = #selector(addSnippet)
        editSnippetButton.target = self; editSnippetButton.action = #selector(editSnippet)
        deleteSnippetButton.target = self; deleteSnippetButton.action = #selector(deleteSnippet)
        let actions = NSStackView(views: [saveSnippetButton, addSnippetButton, editSnippetButton, deleteSnippetButton, NSView()])
        actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 8
        let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        textColumn.width = 320
        textColumn.resizingMask = .autoresizingMask
        table.addTableColumn(textColumn)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.style = .plain
        table.headerView = nil
        table.rowHeight = 68
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(copySelected)
        table.onCopy = { [weak self] in self?.copySelected() }
        table.onDismiss = { [weak self] in self?.dismiss() }
        let list = NSScrollView()
        list.hasVerticalScroller = true; list.documentView = table
        for scrollView in [list, textDetail] {
            scrollView.hasHorizontalScroller = false
            scrollView.horizontalScrollElasticity = .none
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
        }
        list.drawsBackground = false; list.contentView.drawsBackground = false
        table.backgroundColor = .clear
        preview.isEditable = false
        preview.isSelectable = true
        preview.font = .systemFont(ofSize: 13)
        preview.textContainerInset = NSSize(width: 10, height: 10)
        preview.autoresizingMask = [.width]
        preview.isHorizontallyResizable = false
        preview.isVerticallyResizable = true
        preview.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        preview.textContainer?.widthTracksTextView = true
        textDetail.hasVerticalScroller = true; textDetail.documentView = preview
        textDetail.drawsBackground = false
        imagePreview.imageScaling = .scaleProportionallyUpOrDown
        imagePreview.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imagePreview.setContentHuggingPriority(.defaultLow, for: .vertical)
        imagePreview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imagePreview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imagePreview.isHidden = true
        imagePreview.setAccessibilityLabel("所选图片预览")
        imagePreview.wantsLayer = true
        imagePreview.layer?.cornerRadius = 10; imagePreview.layer?.masksToBounds = true
        thumbnails.countLimit = 100
        let detail = NSVisualEffectView()
        detail.material = .underWindowBackground; detail.blendingMode = .withinWindow; detail.state = .active
        detail.wantsLayer = true; detail.layer?.cornerRadius = 12; detail.layer?.masksToBounds = true
        detail.addSubview(textDetail); detail.addSubview(imagePreview)
        for view in [textDetail, imagePreview] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 8),
                view.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -8),
                view.topAnchor.constraint(equalTo: detail.topAnchor, constant: 8),
                view.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -8)
            ])
        }
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(list); body.addSubview(detail)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            list.topAnchor.constraint(equalTo: body.topAnchor),
            list.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            list.widthAnchor.constraint(equalTo: body.widthAnchor, multiplier: 0.46),
            detail.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            detail.topAnchor.constraint(equalTo: body.topAnchor),
            detail.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
        copyButton.title = "复制所选记录"
        copyButton.target = self; copyButton.action = #selector(copySelected)
        copyButton.bezelStyle = .rounded
        let footer = NSStackView(views: [help, NSView(), copyButton])
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 12
        count.textColor = .secondaryLabelColor; count.font = .systemFont(ofSize: 12)
        help.alignment = .left; help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        let symbol = NSImageView(image: NSImage(systemSymbolName: "clipboard.fill", accessibilityDescription: "剪贴板")!)
        symbol.contentTintColor = .controlAccentColor
        let heading = NSTextField(labelWithString: "剪贴板历史")
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        let titleStack = NSStackView(views: [symbol, heading])
        titleStack.orientation = .horizontal; titleStack.alignment = .centerY; titleStack.spacing = 9
        symbol.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let header = NSStackView(views: [titleStack, NSView(), section, count])
        header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 12

        let contentStack = NSStackView(views: [header, search, actions, body, footer])
        contentStack.orientation = .vertical; contentStack.alignment = .leading; contentStack.spacing = 12
        contentStack.distribution = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -24),
            contentStack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 18),
            contentStack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -18),
            header.heightAnchor.constraint(equalToConstant: 28),
            search.heightAnchor.constraint(equalToConstant: 36),
            actions.heightAnchor.constraint(equalToConstant: 28),
            footer.heightAnchor.constraint(equalToConstant: 30),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
        for view in [header, search, actions, body, footer] {
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Isolated in-process UI checks; never writes to the system clipboard.
    func runSmokeChecks() -> Bool {
        var sample = ["测试文本\n第二行", "Beta", "Alpha"].map {
            HistoryEntry(id: UUID(), text: $0, copiedAt: Date())
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<8 { for y in 0..<6 {
            bitmap.setColor(NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1), atX: x, y: y)
        } }
        guard let png = bitmap.representation(using: .png, properties: [:]),
              let image = ClipboardImage(data: png) else { print("FAIL: history window: PNG fixture"); return false }
        sample.append(HistoryEntry(id: UUID(), content: .image(image), copiedAt: Date()))
        show(entries: sample)
        guard table.numberOfRows == 4, preview.string == sample[0].text else { print("FAIL: history window: initial text preview"); return false }
        let editor = NSTextView()
        _ = control(search, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        guard table.selectedRow == 1, preview.string == "Beta" else { print("FAIL: history window: keyboard down selection"); return false }
        _ = control(search, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:)))
        guard table.selectedRow == 0 else { print("FAIL: history window: keyboard up selection"); return false }
        search.stringValue = "第二行"; filter()
        guard table.numberOfRows == 1, preview.string == sample[0].text else { print("FAIL: history window: text filtering"); return false }
        // Verify real menu routing rather than calling the text delegate directly.
        window?.makeFirstResponder(search)
        if let window, let editor = search.currentEditor() as? NSTextView {
            editor.selectedRange = NSRange(location: 0, length: 0)
            let selectAll = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            guard NSApp.mainMenu?.performKeyEquivalent(with: selectAll) == true,
                  editor.selectedRange.length == (search.stringValue as NSString).length else { print("FAIL: history window: select-all menu routing"); return false }
        } else { print("FAIL: history window: search field editor"); return false }
        var copied: HistoryEntry?
        let original = onCopy
        onCopy = { copied = $0 }
        _ = control(search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        onCopy = original
        guard copied == sample[0] else { print("FAIL: history window: text copy callback"); return false }
        search.stringValue = "missing"; filter()
        guard table.numberOfRows == 0 else { print("FAIL: history window: empty results"); return false }
        search.stringValue = "图片"; filter()
        guard table.numberOfRows == 1, imagePreview.image != nil, textDetail.isHidden else { print("FAIL: history window: image search and preview"); return false }
        onCopy = { copied = $0 }
        copySelected()
        onCopy = original
        guard copied == sample[3] else { print("FAIL: history window: image copy callback"); return false }
        guard runSnippetChecks() else { return false }
        guard runPreviewLayoutChecks(image: image) else { return false }
        guard runScrollChecks() else { return false }
        show(entries: sample)
        guard imagePreview.isHidden, !textDetail.isHidden else { print("FAIL: history window: reset selection on reopen"); return false }
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let content = window?.contentView else { print("FAIL: history window: content layout"); return false }
        let buttonFrame = copyButton.convert(copyButton.bounds, to: content)
        let helpFrame = help.convert(help.bounds, to: content)
        return search.frame.width > 0 && table.enclosingScrollView!.frame.height >= 150
            && buttonFrame.width > 0 && buttonFrame.height > 0 && content.bounds.contains(buttonFrame)
            && helpFrame.height > 0 && content.bounds.contains(helpFrame)
    }
    private func runSnippetChecks() -> Bool {
        let savedSnippets = snippets
        let savedSave = onSaveSnippet, savedDelete = onDeleteSnippet, savedCopy = onCopy
        defer { snippets = savedSnippets; onSaveSnippet = savedSave; onDeleteSnippet = savedDelete; onCopy = savedCopy }
        var memory: [TextSnippet] = []
        onSaveSnippet = { id, title, text in
            do {
                let item = TextSnippet(id: id ?? UUID(), title: try SnippetStore.validatedTitle(title, text: text), text: text, updatedAt: Date())
                if let index = memory.firstIndex(where: { $0.id == item.id }) { memory[index] = item }
                else { memory.insert(item, at: 0) }
                self.reloadSnippets(memory)
                return nil
            } catch { return error.localizedDescription }
        }
        onDeleteSnippet = { id in memory.removeAll { $0.id == id }; self.reloadSnippets(memory); return nil }
        snippets = []
        let history = HistoryEntry(id: UUID(), text: "完整正文\n第二行", copiedAt: Date())
        show(entries: [history])
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func editorFields() -> (NSTextField, NSTextView, NSButton)? {
            guard let root = snippetEditor?.window?.contentView else { return nil }
            let children = views(root)
            guard let name = children.compactMap({ $0 as? NSTextField }).first(where: \.isEditable),
                  let text = children.compactMap({ $0 as? NSTextView }).first,
                  let save = children.compactMap({ $0 as? NSButton }).first(where: { $0.title == "保存" }) else { return nil }
            return (name, text, save)
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        saveSelectedAsSnippet()
        guard let fields = editorFields(), fields.1.string == history.text else { print("FAIL: common text: save history editor"); return false }
        fields.0.stringValue = "常用问候"; fields.2.performClick(nil); settle()
        guard showingSnippets, memory.count == 1, entries.first?.text == history.text else { print("FAIL: common text: save history"); return false }
        search.stringValue = "问候"; filter()
        guard entries.count == 1 else { print("FAIL: common text: search name"); return false }
        search.stringValue = "第二行"; filter()
        guard entries.count == 1 else { print("FAIL: common text: search body"); return false }
        var copied: HistoryEntry?
        onCopy = { copied = $0 }; copySelected()
        guard copied?.text == history.text else { print("FAIL: common text: copy full body"); return false }
        search.stringValue = ""; filter()
        addSnippet()
        guard let addFields = editorFields() else { print("FAIL: common text: add editor, attached sheet \(window?.attachedSheet != nil)"); return false }
        addFields.2.performClick(nil)
        guard memory.count == 1 && snippetEditor != nil else { print("FAIL: common text: validate blank editor"); return false }
        addFields.1.string = "新增正文"
        let successfulSave = onSaveSnippet
        onSaveSnippet = { _, _, _ in "模拟写入失败" }
        addFields.2.performClick(nil)
        guard memory.count == 1, snippetEditor != nil, addFields.1.string == "新增正文" else { print("FAIL: common text: failed save preserves draft"); return false }
        onSaveSnippet = successfulSave
        addFields.2.performClick(nil); settle()
        guard memory.count == 2, entries.first?.text == "新增正文" else { print("FAIL: common text: add"); return false }
        let identity = entries[0].id
        editSnippet()
        guard let editFields = editorFields(), editFields.1.string == "新增正文" else { print("FAIL: common text: edit editor, attached sheet \(window?.attachedSheet != nil)"); return false }
        editFields.0.stringValue = "修改名称"; editFields.1.string = "修改正文"; editFields.2.performClick(nil); settle()
        guard memory.count == 2, entries[0].id == identity, entries[0].text == "修改正文" else { print("FAIL: common text: edit"); return false }
        deleteSnippet()
        guard let sheet = window?.attachedSheet,
              let confirm = views(sheet.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == "删除" }) else { print("FAIL: common text: delete confirmation, attached sheet \(window?.attachedSheet != nil)"); return false }
        confirm.performClick(nil); settle()
        guard memory.count == 1, all == [history] else { print("FAIL: common text: delete preserves history"); return false }
        show(entries: [history])
        guard !showingSnippets, entries == [history] else { print("FAIL: common text: default to history on reopen"); return false }
        return true
    }
    private func runPreviewLayoutChecks(image: ClipboardImage) -> Bool {
        let records = [HistoryEntry(id: UUID(), content: .image(image), copiedAt: Date()),
                       HistoryEntry(id: UUID(), text: "短文本", copiedAt: Date()),
                       HistoryEntry(id: UUID(), text: String(repeating: "长文本预览\n", count: 100), copiedAt: Date())]
            + (0..<15).map { HistoryEntry(id: UUID(), text: "记录 \($0)", copiedAt: Date()) }
        show(entries: records)
        guard let content = window?.contentView, let list = table.enclosingScrollView,
              let detail = textDetail.superview else { return false }
        content.layoutSubtreeIfNeeded()
        let listFrame = list.convert(list.bounds, to: content)
        let detailFrame = detail.convert(detail.bounds, to: content)
        let helpFrame = help.convert(help.bounds, to: content)
        let windowFrame = window!.frame
        for row in [1, 2, 0, 1] {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            content.layoutSubtreeIfNeeded()
            guard list.convert(list.bounds, to: content) == listFrame,
                  detail.convert(detail.bounds, to: content) == detailFrame,
                  help.convert(help.bounds, to: content) == helpFrame,
                  window!.frame == windowFrame else {
                print("FAIL: history window: preview selection changes list or footer layout"); return false
            }
        }
        return true
    }
    private func runScrollChecks() -> Bool {
        let longLine = "https://example.com/" + String(repeating: "abcdef0123456789", count: 40)
        let records = (0..<24).map {
            HistoryEntry(id: UUID(), text: "记录 \($0)\n" + String(repeating: longLine + "\n", count: 20), copiedAt: Date())
        }
        show(entries: records)
        guard let list = table.enclosingScrollView, let content = window?.contentView else { return false }
        // Both scroller styles must fit, including systems configured to always show scrollbars.
        for style: NSScroller.Style in [.legacy, .overlay] {
            list.scrollerStyle = style; textDetail.scrollerStyle = style
            content.layoutSubtreeIfNeeded()
            list.layoutSubtreeIfNeeded(); textDetail.layoutSubtreeIfNeeded()
            guard table.frame.width <= list.contentSize.width + 0.5,
                  preview.frame.width <= textDetail.contentSize.width + 0.5 else {
                print("FAIL: history window: horizontal overflow with long text"); return false
            }
        }
        table.scrollRowToVisible(records.count - 1)
        preview.scrollToEndOfDocument(nil)
        guard list.contentView.bounds.origin.y > 0,
              table.visibleRect.intersects(table.rect(ofRow: records.count - 1)),
              textDetail.contentView.bounds.origin.y > 0 else {
            print("FAIL: history window: vertical scrolling"); return false
        }
        return true
    }
    func show(entries: [HistoryEntry]) {
        section.selectedSegment = 0
        search.stringValue = ""
        table.deselectAll(nil)
        reload(entries)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
    }
    func windowWillClose(_ notification: Notification) { onDismiss?() }
    func reload(_ entries: [HistoryEntry]) { all = entries; filter() }
    func reloadSnippets(_ snippets: [TextSnippet]) { self.snippets = snippets; filter() }
    @objc private func changeSection() {
        search.stringValue = ""; table.deselectAll(nil)
        filter()
        if !entries.isEmpty { table.scrollRowToVisible(0) }
        window?.makeFirstResponder(search)
    }
    private func filter() {
        let selected = entries.indices.contains(table.selectedRow) ? entries[table.selectedRow].id : nil
        entries = showingSnippets ? snippets.filter { $0.matches(search.stringValue) }.map(\.entry)
            : all.filter { $0.matches(search.stringValue) }
        table.reloadData()
        let row = selected.flatMap { id in entries.firstIndex { $0.id == id } } ?? 0
        if !entries.isEmpty { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        count.stringValue = "\(entries.count) / \(showingSnippets ? snippets.count : all.count) 条"
        search.placeholderString = showingSnippets ? "搜索名称或常用文本…" : "搜索文本、图片和尺寸…"
        updatePreview()
    }
    func controlTextDidChange(_ obj: Notification) { filter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveDown(_:)) { move(1); return true }
        if selector == #selector(NSResponder.moveUp(_:)) { move(-1); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { copySelected(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { dismiss(); return true }
        return false
    }
    private func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), entries.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let snippet = showingSnippets ? snippets.first(where: { $0.id == entry.id }) : nil
        let title = snippet.map { $0.title + "\n" + $0.text.replacingOccurrences(of: "\n", with: "  ↵  ") }
            ?? entry.title.replacingOccurrences(of: "\n", with: "  ↵  ")
        let label = NSTextField(labelWithString: title)
        label.maximumNumberOfLines = 2; label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        let cell = NSTableCellView()
        let tile = NSVisualEffectView()
        tile.material = .underWindowBackground; tile.blendingMode = .withinWindow; tile.state = .active
        tile.wantsLayer = true; tile.layer?.cornerRadius = 9; tile.layer?.masksToBounds = true
        tile.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(tile)
        label.translatesAutoresizingMaskIntoConstraints = false; tile.addSubview(label)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            tile.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            tile.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            tile.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: entry.image == nil ? 14 : 132),
            label.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: tile.centerYAnchor)
        ])
        if let image = entry.image {
            let thumbnail = NSImageView()
            thumbnail.imageScaling = .scaleProportionallyUpOrDown
            if let cached = thumbnails.object(forKey: image.digest as NSString) { thumbnail.image = cached }
            else if let rendered = image.thumbnail(maxPixels: 112) {
                thumbnails.setObject(rendered, forKey: image.digest as NSString); thumbnail.image = rendered
            }
            thumbnail.wantsLayer = true; thumbnail.layer?.cornerRadius = 6; thumbnail.layer?.masksToBounds = true
            thumbnail.translatesAutoresizingMaskIntoConstraints = false; tile.addSubview(thumbnail)
            NSLayoutConstraint.activate([
                thumbnail.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 8),
                thumbnail.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
                thumbnail.widthAnchor.constraint(equalToConstant: 104),
                thumbnail.heightAnchor.constraint(equalToConstant: 56)
            ])
        }
        cell.textField = label
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updatePreview() }
    private func updatePreview() {
        let entry = entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
        copyButton.isEnabled = entry != nil
        saveSnippetButton.isHidden = showingSnippets
        saveSnippetButton.isEnabled = entry != nil && entry?.image == nil && onSaveSnippet != nil
        for button in [addSnippetButton, editSnippetButton, deleteSnippetButton] { button.isHidden = !showingSnippets }
        addSnippetButton.isEnabled = onSaveSnippet != nil
        editSnippetButton.isEnabled = entry != nil && onSaveSnippet != nil
        deleteSnippetButton.isEnabled = entry != nil && onDeleteSnippet != nil
        if let image = entry?.image {
            if previewedImage != image.digest { imagePreview.image = image.thumbnail(maxPixels: 1200) }
            previewedImage = image.digest
            imagePreview.isHidden = false; textDetail.isHidden = true
            return
        }
        previewedImage = nil; imagePreview.image = nil
        imagePreview.isHidden = true; textDetail.isHidden = false
        preview.string = entry?.text ?? (showingSnippets && snippets.isEmpty ? "点击「新增」保存常用文本，也可以从历史记录中「存为常用文本」。" : "没有匹配的记录")
        preview.scrollToBeginningOfDocument(nil)
    }
    @objc private func copySelected() {
        guard entries.indices.contains(table.selectedRow) else { NSSound.beep(); return }
        onCopy?(entries[table.selectedRow])
    }
    @objc private func saveSelectedAsSnippet() {
        guard !showingSnippets, entries.indices.contains(table.selectedRow), entries[table.selectedRow].image == nil else { return }
        showSnippetEditor(text: entries[table.selectedRow].text)
    }
    @objc private func addSnippet() { showSnippetEditor() }
    @objc private func editSnippet() {
        guard showingSnippets, entries.indices.contains(table.selectedRow),
              let snippet = snippets.first(where: { $0.id == entries[table.selectedRow].id }) else { return }
        showSnippetEditor(snippet: snippet, text: snippet.text)
    }
    private func showSnippetEditor(snippet: TextSnippet? = nil, text: String = "") {
        guard let window, window.attachedSheet == nil else { return }
        let editor = SnippetEditor(title: snippet == nil ? "新增常用文本" : "编辑常用文本", name: snippet?.title ?? "", text: text)
        snippetEditor = editor
        editor.onSave = { [weak self] title, text in
            guard let self, let save = self.onSaveSnippet else { return "常用文本存储不可用。" }
            if let message = save(snippet?.id, title, text) { return message }
            self.section.selectedSegment = 1; self.search.stringValue = ""; self.filter()
            if let id = snippet?.id, let row = self.entries.firstIndex(where: { $0.id == id }) {
                self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                self.table.scrollRowToVisible(row)
            } else if !self.entries.isEmpty {
                self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                self.table.scrollRowToVisible(0)
            }
            return nil
        }
        editor.onClose = { [weak self] in self?.snippetEditor = nil; self?.window?.makeFirstResponder(self?.search) }
        editor.showSheet(for: window)
    }
    @objc private func deleteSnippet() {
        guard showingSnippets, entries.indices.contains(table.selectedRow), let window, window.attachedSheet == nil else { return }
        let id = entries[table.selectedRow].id
        let alert = NSAlert()
        alert.messageText = "删除这条常用文本？"
        alert.informativeText = "删除后无法恢复，剪贴板历史中的记录会保留。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self, let remove = self.onDeleteSnippet else { return }
            if let message = remove(id) {
                let error = NSAlert(); error.messageText = "删除失败"; error.informativeText = message
                error.beginSheetModal(for: window)
            }
        }
    }
    private func dismiss() { window?.orderOut(nil); onDismiss?() }
}

private final class HistoryPanel: NSPanel {
    var onCommand: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onCommand?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
private final class HistoryTable: NSTableView {
    var onCopy: (() -> Void)?
    var onDismiss: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onCopy?(); return }
        if event.keyCode == 53 { onDismiss?(); return }
        super.keyDown(with: event)
    }
}
