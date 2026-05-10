import AppKit

@MainActor
final class RegionSelectionWindow: NSPanel {
    private let onRegionSelected: (CGRect) -> Void
    private let onCancel: () -> Void

    init(frozenImage: NSImage? = nil, onRegionSelected: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        self.onRegionSelected = onRegionSelected
        self.onCancel = onCancel

        guard let screen = NSScreen.main else {
            super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            self.isReleasedWhenClosed = false
            return
        }

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isReleasedWhenClosed = false
        self.level = .statusBar + 1
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hidesOnDeactivate = false

        let selectionView = RegionSelectionView(frame: screen.frame, frozenImage: frozenImage) { [weak self] rect in
            self?.onRegionSelected(rect)
        } onCancel: { [weak self] in
            self?.onCancel()
        }
        self.contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
}
