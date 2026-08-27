import AppKit
import Combine

private extension NSToolbarItem.Identifier {
    static let search = NSToolbarItem.Identifier("app.screensnipe.toolbar.search")
    static let undo = NSToolbarItem.Identifier("app.screensnipe.toolbar.undo")
    static let redo = NSToolbarItem.Identifier("app.screensnipe.toolbar.redo")
    static let toolPicker = NSToolbarItem.Identifier("app.screensnipe.toolbar.toolPicker")
    static let textCapture = NSToolbarItem.Identifier("app.screensnipe.toolbar.textCapture")
    static let cropPicker = NSToolbarItem.Identifier("app.screensnipe.toolbar.cropPicker")
    static let delete = NSToolbarItem.Identifier("app.screensnipe.toolbar.delete")
    static let save = NSToolbarItem.Identifier("app.screensnipe.toolbar.save")
    static let copy = NSToolbarItem.Identifier("app.screensnipe.toolbar.copy")
    static let share = NSToolbarItem.Identifier("app.screensnipe.toolbar.share")
    static let copyLink = NSToolbarItem.Identifier("app.screensnipe.toolbar.copyLink")
    static let inspector = NSToolbarItem.Identifier("app.screensnipe.toolbar.inspector")
    static let prevFrame = NSToolbarItem.Identifier("app.screensnipe.toolbar.prevFrame")
    static let nextFrame = NSToolbarItem.Identifier("app.screensnipe.toolbar.nextFrame")
    static let frameLabel = NSToolbarItem.Identifier("app.screensnipe.toolbar.frameLabel")
}

@MainActor
final class LibraryToolbarDelegate: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    private var cancellables: Set<AnyCancellable> = []

    private weak var undoItem: NSToolbarItem?
    private weak var redoItem: NSToolbarItem?
    private weak var deleteItem: NSToolbarItem?
    private weak var toolPickerGroup: NSToolbarItemGroup?
    private weak var cropPickerGroup: NSToolbarItemGroup?
    private weak var saveItem: NSToolbarItem?
    private weak var copyItem: NSToolbarItem?
    private weak var textCaptureItem: NSToolbarItem?
    private weak var shareItem: NSToolbarItem?
    private weak var copyLinkItem: NSToolbarItem?
    private weak var inspectorItem: NSToolbarItem?
    private weak var searchItem: NSSearchToolbarItem?
    private weak var prevFrameItem: NSToolbarItem?
    private weak var nextFrameItem: NSToolbarItem?
    private weak var frameLabelItem: NSToolbarItem?
    private weak var frameLabelField: NSTextField?
    weak var toolbar: NSToolbar?

    override init() {
        super.init()
        setupBindings()
    }

    private func setupBindings() {
        let viewModel = LibraryViewModel.shared
        let store = viewModel.annotationStore

        // Undo/Redo enabled state (guarded on hasImage)
        store.$annotations
            .combineLatest(store.$cropRect)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let hasImage = viewModel.selectedImage != nil
                self?.undoItem?.isEnabled = hasImage && store.canUndo
                self?.redoItem?.isEnabled = hasImage && store.canRedo
            }
            .store(in: &cancellables)

        // Delete enabled when something is selected and an image is loaded
        store.$selectedID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] selectedID in
                let hasImage = viewModel.selectedImage != nil
                self?.deleteItem?.isEnabled = hasImage && selectedID != nil
            }
            .store(in: &cancellables)

        // Tool picker tracks activeTool across both groups
        viewModel.$activeTool
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tool in
                let mainTools = EditorTool.allCases.filter { $0 != .crop }
                if let index = mainTools.firstIndex(of: tool) {
                    self?.toolPickerGroup?.selectedIndex = index
                    self?.cropPickerGroup?.selectedIndex = -1
                } else if tool == .crop {
                    self?.toolPickerGroup?.selectedIndex = -1
                    self?.cropPickerGroup?.selectedIndex = 0
                }
            }
            .store(in: &cancellables)

        // Toolbar items enabled state based on selected image/video
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let hasImage = viewModel.selectedImage != nil
                let hasMedia = hasImage || viewModel.selectedVideoURL != nil
                self?.undoItem?.isEnabled = hasImage && store.canUndo
                self?.redoItem?.isEnabled = hasImage && store.canRedo
                self?.deleteItem?.isEnabled = hasImage && store.selectedID != nil
                self?.toolPickerGroup?.isEnabled = hasImage
                self?.cropPickerGroup?.isEnabled = hasImage
                self?.saveItem?.isEnabled = hasMedia
                self?.copyItem?.isEnabled = hasImage
                self?.textCaptureItem?.isEnabled = hasImage
                self?.shareItem?.isEnabled = hasMedia
                self?.copyLinkItem?.isEnabled = hasMedia
                self?.updateFrameItems(viewModel: viewModel)
            }
            .store(in: &cancellables)
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: .search)
            item.searchField.placeholderString = "Search"
            item.searchField.toolTip = "Search by name, description, tag, or date.\nFilter with is:shared, is:image, is:video, or is:series."
            item.searchField.sendsWholeSearchString = false
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(searchAction(_:))

            // Magnifier dropdown offering the is: filters, so the syntax is
            // discoverable without reading docs.
            let filterMenu = NSMenu()
            let filters = [
                ("Shared (is:shared)", "is:shared"),
                ("Screenshots (is:image)", "is:image"),
                ("Recordings (is:video)", "is:video"),
                ("Series (is:series)", "is:series"),
            ]
            for (title, token) in filters {
                let menuItem = NSMenuItem(title: title, action: #selector(searchFilterAction(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = token
                filterMenu.addItem(menuItem)
            }
            item.searchField.searchMenuTemplate = filterMenu

            searchItem = item
            return item

        case .prevFrame:
            let item = NSToolbarItem(itemIdentifier: .prevFrame)
            item.label = "Previous Frame"
            item.toolTip = "Go to the previous frame in this series"
            item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous Frame")
            item.target = self
            item.action = #selector(previousFrameAction)
            item.isEnabled = false
            prevFrameItem = item
            return item

        case .nextFrame:
            let item = NSToolbarItem(itemIdentifier: .nextFrame)
            item.label = "Next Frame"
            item.toolTip = "Go to the next frame in this series"
            item.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next Frame")
            item.target = self
            item.action = #selector(nextFrameAction)
            item.isEnabled = false
            nextFrameItem = item
            return item

        case .frameLabel:
            let item = NSToolbarItem(itemIdentifier: .frameLabel)
            item.label = "Frame"
            let field = NSTextField(labelWithString: "")
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            field.textColor = .secondaryLabelColor
            field.alignment = .center
            field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            // Fixed width so the toolbar does not reflow as the digits change.
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
            item.view = field
            frameLabelItem = item
            frameLabelField = field
            return item

        case .undo:
            let item = NSToolbarItem(itemIdentifier: .undo)
            item.label = "Undo"
            item.toolTip = "Undo last action"
            item.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")
            item.target = self
            item.action = #selector(undoAction)
            item.isEnabled = false
            undoItem = item
            return item

        case .redo:
            let item = NSToolbarItem(itemIdentifier: .redo)
            item.label = "Redo"
            item.toolTip = "Redo last undone action"
            item.image = NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "Redo")
            item.target = self
            item.action = #selector(redoAction)
            item.isEnabled = false
            redoItem = item
            return item

        case .toolPicker:
            let tools = EditorTool.allCases.filter { $0 != .crop }
            let images = tools.map { tool in
                NSImage(systemSymbolName: tool.iconName, accessibilityDescription: tool.displayName) ?? NSImage()
            }
            let labels = tools.map { $0.displayName }

            let group = NSToolbarItemGroup(itemIdentifier: .toolPicker, images: images, selectionMode: .selectOne, labels: labels, target: self, action: #selector(toolPickerAction(_:)))
            group.label = "Tools"
            group.selectedIndex = 0
            group.isEnabled = false
            let toolTips = tools.map { toolTipForEditorTool($0) }
            for (index, subItem) in group.subitems.enumerated() {
                subItem.toolTip = toolTips[index]
            }
            toolPickerGroup = group
            return group

        case .cropPicker:
            let image = NSImage(systemSymbolName: "crop", accessibilityDescription: "Crop") ?? NSImage()
            let group = NSToolbarItemGroup(itemIdentifier: .cropPicker, images: [image], selectionMode: .selectOne, labels: ["Crop"], target: self, action: #selector(cropPickerAction(_:)))
            group.label = "Crop"
            group.selectedIndex = -1
            group.isEnabled = false
            group.subitems.first?.toolTip = "Crop the image"
            cropPickerGroup = group
            return group

        case .delete:
            let item = NSToolbarItem(itemIdentifier: .delete)
            item.label = "Delete"
            item.toolTip = "Delete selected annotation"
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
            item.target = self
            item.action = #selector(deleteAction)
            item.isEnabled = false
            deleteItem = item
            return item

        case .save:
            let item = NSToolbarItem(itemIdentifier: .save)
            item.label = "Save"
            item.toolTip = "Save to file"
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save")
            item.target = self
            item.action = #selector(saveAction)
            item.isEnabled = false
            saveItem = item
            return item

        case .copy:
            let item = NSToolbarItem(itemIdentifier: .copy)
            item.label = "Copy"
            item.toolTip = "Copy to clipboard"
            item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            item.target = self
            item.action = #selector(copyAction)
            item.isEnabled = false
            copyItem = item
            return item

        case .textCapture:
            let item = NSToolbarItem(itemIdentifier: .textCapture)
            item.label = "Text Capture"
            item.toolTip = "Recognize and extract text from image (OCR)"
            item.image = NSImage(systemSymbolName: "doc.text.viewfinder", accessibilityDescription: "Text Capture")
            item.target = self
            item.action = #selector(textCaptureAction)
            item.isEnabled = false
            textCaptureItem = item
            return item

        case .share:
            let item = NSToolbarItem(itemIdentifier: .share)
            item.label = "Share"
            item.toolTip = "Share with other apps"
            let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share") ?? NSImage(), target: self, action: #selector(shareAction(_:)))
            button.bezelStyle = .toolbar
            button.toolTip = "Share image with other apps"
            item.view = button
            item.isEnabled = false
            shareItem = item
            return item

        case .copyLink:
            let item = NSToolbarItem(itemIdentifier: .copyLink)
            item.label = "Copy Link"
            item.toolTip = "Copy a public iCloud link"
            item.image = NSImage(systemSymbolName: "link.icloud", accessibilityDescription: "Copy iCloud Link")
            item.target = self
            item.action = #selector(copyLinkAction)
            item.isEnabled = false
            copyLinkItem = item
            return item

        case .inspector:
            let item = NSToolbarItem(itemIdentifier: .inspector)
            item.label = "Inspector"
            item.toolTip = "Toggle inspector panel"
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Inspector")
            item.target = self
            item.action = #selector(inspectorAction)
            inspectorItem = item
            return item

        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .search,
            .sidebarTrackingSeparator,
            .undo,
            .redo,
            .toolPicker,
            .textCapture,
            .cropPicker,
            .delete,
            .flexibleSpace,
            .save,
            .copy,
            .share,
            .copyLink,
            .inspectorTrackingSeparator,
            .inspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The frame controls are inserted and removed on demand rather than
        // listed by default: NSToolbarItem.isHidden needs macOS 15, and leaving
        // them permanently visible would put dead chevrons next to every
        // screenshot.
        toolbarDefaultItemIdentifiers(toolbar) + [.prevFrame, .frameLabel, .nextFrame]
    }

    // MARK: - Validation

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let viewModel = LibraryViewModel.shared
        let hasImage = viewModel.selectedImage != nil
        let store = viewModel.annotationStore

        switch item.itemIdentifier {
        case .undo:
            return hasImage && store.canUndo
        case .redo:
            return hasImage && store.canRedo
        case .delete:
            return hasImage && store.selectedID != nil
        case .toolPicker, .cropPicker:
            return hasImage
        case .save, .share, .copyLink:
            return hasImage || viewModel.selectedVideoURL != nil
        case .copy, .textCapture:
            return hasImage
        case .inspector:
            return true
        case .prevFrame:
            return viewModel.canGoToPreviousFrame
        case .nextFrame:
            return viewModel.canGoToNextFrame
        case .frameLabel:
            return viewModel.currentFrameIndex != nil
        default:
            return true
        }
    }

    /// Frame navigation only means anything for series entries, so the controls
    /// hide entirely rather than sitting greyed out for every screenshot.
    private func updateFrameItems(viewModel: LibraryViewModel) {
        let isSeries = viewModel.currentFrameIndex != nil
        setFrameItemsVisible(isSeries)
        prevFrameItem?.isEnabled = viewModel.canGoToPreviousFrame
        nextFrameItem?.isEnabled = viewModel.canGoToNextFrame
        if let position = viewModel.currentFramePosition {
            frameLabelField?.stringValue = "\(position) of \(viewModel.seriesFrames.count)"
        } else {
            frameLabelField?.stringValue = ""
        }
    }

    private static let frameItemIdentifiers: [NSToolbarItem.Identifier] = [.prevFrame, .frameLabel, .nextFrame]

    private func setFrameItemsVisible(_ visible: Bool) {
        guard let toolbar else { return }
        let present = toolbar.items.contains { $0.itemIdentifier == .prevFrame }
        guard present != visible else { return }

        if visible {
            // Insert ahead of Undo, which is the first detail-side item.
            var insertIndex = toolbar.items.firstIndex { $0.itemIdentifier == .undo } ?? toolbar.items.count
            for identifier in Self.frameItemIdentifiers {
                toolbar.insertItem(withItemIdentifier: identifier, at: insertIndex)
                insertIndex += 1
            }
        } else {
            for identifier in Self.frameItemIdentifiers {
                if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == identifier }) {
                    toolbar.removeItem(at: index)
                }
            }
        }
    }

    // MARK: - Helpers

    private func toolTipForEditorTool(_ tool: EditorTool) -> String {
        let base: String = switch tool {
        case .selection: "Select and move annotations"
        case .arrow: "Draw arrow annotations"
        case .text: "Add text annotations"
        case .shape: "Draw shape annotations"
        case .line: "Draw line annotations"
        case .highlighter: "Highlight areas of the image"
        case .blur: "Blur sensitive areas of the image"
        case .crop: "Crop the image"
        }
        if let hint = tool.shortcutHint {
            return "\(base) (\(hint))"
        }
        return base
    }

    // MARK: - Actions

    @objc private func searchAction(_ sender: NSSearchField) {
        LibraryViewModel.shared.searchQuery = sender.stringValue
    }

    @objc private func searchFilterAction(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String else { return }
        let viewModel = LibraryViewModel.shared
        var query = viewModel.searchQuery
        guard !query.localizedCaseInsensitiveContains(token) else { return }
        query = query.isEmpty ? token : "\(token) \(query)"
        viewModel.searchQuery = query
        searchItem?.searchField.stringValue = query
    }

    @objc private func previousFrameAction() {
        LibraryViewModel.shared.goToPreviousFrame()
    }

    @objc private func nextFrameAction() {
        LibraryViewModel.shared.goToNextFrame()
    }

    @objc private func undoAction() {
        LibraryViewModel.shared.annotationStore.undo()
    }

    @objc private func redoAction() {
        LibraryViewModel.shared.annotationStore.redo()
    }

    @objc private func toolPickerAction(_ sender: NSToolbarItemGroup) {
        let tools = EditorTool.allCases.filter { $0 != .crop }
        let index = sender.selectedIndex
        guard index >= 0, index < tools.count else { return }
        LibraryViewModel.shared.activeTool = tools[index]
    }

    @objc private func cropPickerAction(_ sender: NSToolbarItemGroup) {
        guard sender.selectedIndex == 0 else { return }
        LibraryViewModel.shared.activeTool = .crop
    }

    @objc private func deleteAction() {
        LibraryViewModel.shared.annotationStore.removeSelected()
    }

    @objc private func saveAction() {
        let viewModel = LibraryViewModel.shared
        let entryName = viewModel.selectedExportName
        if let image = viewModel.selectedImage {
            let store = viewModel.annotationStore
            if viewModel.currentFrameIndex != nil {
                ImageExportService.saveSeries(
                    currentFrame: .init(image: image, annotations: store.annotations, cropRect: store.cropRect),
                    allFrames: { viewModel.seriesExportFrames() },
                    defaultName: entryName
                )
            } else {
                ImageExportService.save(image: image, annotations: store.annotations, cropRect: store.cropRect, defaultName: entryName)
            }
        } else if let videoURL = viewModel.selectedVideoURL {
            VideoExportService.save(videoURL: videoURL, defaultName: entryName)
        }
    }

    @objc private func copyAction() {
        guard let image = LibraryViewModel.shared.selectedImage else { return }
        let store = LibraryViewModel.shared.annotationStore
        ImageExportService.copyToClipboard(image: image, annotations: store.annotations, cropRect: store.cropRect)
        CopiedToast.show(in: NSApp.keyWindow)
    }

    @objc private func textCaptureAction() {
        guard let image = LibraryViewModel.shared.selectedImage else { return }

        let parentWindow = NSApp.keyWindow
        TextCapturePanel.showLoading(relativeTo: parentWindow)

        Task {
            do {
                let rawText = try await TextRecognitionService.recognizeText(in: image)
                TextCapturePanel.show(text: rawText, relativeTo: parentWindow)
            } catch {
                TextCapturePanel.show(text: "", relativeTo: parentWindow)
                let alert = NSAlert()
                alert.messageText = "Text Capture"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                if let window = NSApp.keyWindow {
                    await alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
        }
    }

    @objc private func inspectorAction() {
        LibraryViewModel.shared.showInspector.toggle()
    }

    @objc private func copyLinkAction() {
        LibraryViewModel.shared.copyICloudLinkForSelection()
    }

    @objc private func shareAction(_ sender: NSButton) {
        let viewModel = LibraryViewModel.shared
        let items: [Any]
        if let image = viewModel.selectedImage {
            let store = viewModel.annotationStore
            items = [ImageExportService.flatten(image: image, annotations: store.annotations, cropRect: store.cropRect)]
        } else if let videoURL = viewModel.selectedVideoURL {
            items = [videoURL]
        } else {
            return
        }
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
}
