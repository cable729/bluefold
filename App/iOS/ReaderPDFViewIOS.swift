import PDFKit
import ReaderCore
import ReaderUI
import UIKit

/// PDFView subclass that intercepts taps on internal-link annotations — the
/// UIKit analog of macOS `ReaderPDFView.mouseDown`.
///
/// PDFKit's iOS PDFView navigates GoTo links itself, invisibly to the app:
/// no history push, no validated destination point (see "PDFKit destination
/// pathologies" in PROGRESS.md — garbage points make `go(to:)` silently
/// no-op). This view claims those taps with its own recognizer so navigation
/// flows through `ReaderCore.NavigationHistory` and the shared
/// `PDFView.go(to:in:)` crop-validated jump instead. External URL links stay
/// with PDFView's default handling.
///
/// Touch translations of the macOS pointer vocabulary:
/// - plain tap on a link = navigate in place (history push)
/// - ⌘-tap (hardware keyboard) = background tab, like macOS ⌘-click
/// - long-press on a link = bespoke peek overlay (destination preview +
///   Open / New Tab / Split), see `LinkPeekOverlayIOS`
final class ReaderPDFViewIOS: PDFView {
    /// Called with the resolved target, the position being navigated *away
    /// from* (the history push target), and how to open it. The handler
    /// performs the navigation; PDFView's own link handling never sees the
    /// tap.
    var onLinkActivated: ((
        _ target: LinkTarget, _ current: NavEntry,
        _ mode: ReaderSessionModel.LinkOpenMode
    ) -> Void)?
    /// Fired when the user starts a scroll drag (iPhone chrome auto-hide).
    var onScrollInteraction: (() -> Void)?
    /// Fired on a tap that hit neither a link nor a text selection
    /// (iPhone chrome show/hide toggle).
    var onContentTap: (() -> Void)?
    /// The current theme's accent, used to tint the long-press peek buttons.
    /// Pushed from `PDFKitView` so the peek follows light/dark/sepia.
    var linkAccent: UIColor = .tintColor

    private let linkTap = UITapGestureRecognizer()
    private let linkPress = UILongPressGestureRecognizer()
    /// Swipe-to-turn for the snap-one-screen modes (single page / two-up).
    /// Those modes never scroll across a page boundary, so PDFKit offers no
    /// touch way to advance — without these, pages only turn via a hardware
    /// keyboard. Flick left/up = forward, right/down = back. One recognizer
    /// per direction: a single recognizer with a combined direction mask
    /// only fires reliably for one of its directions. Gated to the paged
    /// modes in `gestureRecognizerShouldBegin` so they never hijack a flick
    /// in the continuous modes (where the up/down flick belongs to scrolling).
    private let pageSwipes: [UISwipeGestureRecognizer] = [
        UISwipeGestureRecognizer(), UISwipeGestureRecognizer(),
        UISwipeGestureRecognizer(), UISwipeGestureRecognizer(),
    ]
    /// Chrome show/hide toggle (iPhone). Separate recognizer that never
    /// cancels touches and recognizes alongside PDFKit's own taps — a
    /// touchesEnded override never fired (PDFKit's subviews consume the
    /// touches before they bubble).
    private let chromeTap = UITapGestureRecognizer()
    /// Recognizers already told to wait for ours (idempotence guard for the
    /// per-layout re-walk; holds identifiers, not references).
    private var deferredRecognizers: Set<ObjectIdentifier> = []
    /// Scroll views whose pan already reports to us.
    private var observedPans: Set<ObjectIdentifier> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureRecognizers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureRecognizers()
    }

    private func configureRecognizers() {
        linkTap.addTarget(self, action: #selector(handleLinkTap))
        linkTap.delegate = self
        addGestureRecognizer(linkTap)

        linkPress.minimumPressDuration = 0.35
        linkPress.addTarget(self, action: #selector(handleLinkPress))
        linkPress.delegate = self
        addGestureRecognizer(linkPress)

        chromeTap.addTarget(self, action: #selector(handleChromeTap))
        chromeTap.cancelsTouchesInView = false
        chromeTap.delegate = self
        chromeTap.require(toFail: linkTap)  // links never toggle chrome
        addGestureRecognizer(chromeTap)

        let directions: [UISwipeGestureRecognizer.Direction] = [.left, .right, .up, .down]
        for (recognizer, direction) in zip(pageSwipes, directions) {
            recognizer.direction = direction
            recognizer.addTarget(self, action: #selector(handlePageSwipe(_:)))
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }

        // Links are draggable onto the tab strip / split drop zone.
        let linkDrag = UIDragInteraction(delegate: self)
        linkDrag.isEnabled = true  // default off on iPhone
        addInteraction(linkDrag)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // PDFKit attaches its own tap recognizers (link handling, selection)
        // to internal subviews, some lazily — re-walk on every layout and
        // make each one wait for our link tap to fail. Off links, ours fails
        // instantly in gestureRecognizerShouldBegin, so scrolling and
        // selection are unaffected. The same walk finds the inner scroll
        // view for the chrome-hide pan hook.
        deferOtherTapRecognizers(in: self)
    }

    private func deferOtherTapRecognizers(in view: UIView) {
        for recognizer in view.gestureRecognizers ?? [] {
            guard recognizer !== linkTap, recognizer is UITapGestureRecognizer else { continue }
            if deferredRecognizers.insert(ObjectIdentifier(recognizer)).inserted {
                recognizer.require(toFail: linkTap)
            }
        }
        if let scrollView = view as? UIScrollView,
           observedPans.insert(ObjectIdentifier(scrollView)).inserted {
            scrollView.panGestureRecognizer.addTarget(
                self, action: #selector(handleScrollPan(_:)))
            // On a page taller than the viewport the inner scroll view claims
            // the vertical drag for in-page scrolling and cancels the swipe
            // before it recognizes — so an up/down flick never turned the
            // page. Make the scroll pan wait for the page-turn swipes to
            // fail: a fast straight flick recognizes and turns the page, a
            // normal (slower) scroll drag fails them instantly and scrolls.
            // Harmless in the continuous modes, where the swipes are gated
            // off in gestureRecognizerShouldBegin and fail immediately.
            for swipe in pageSwipes {
                scrollView.panGestureRecognizer.require(toFail: swipe)
            }
        }
        for subview in view.subviews {
            deferOtherTapRecognizers(in: subview)
        }
    }

    /// The link recognizers begin ONLY over an internal link; everywhere
    /// else they fail immediately so PDFKit's own recognizers proceed
    /// unimpeded. The chrome tap is the mirror image: anywhere BUT a link.
    /// (PDFView is itself a UIGestureRecognizerDelegate on iOS — override,
    /// and defer to super for every recognizer that isn't ours.)
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === chromeTap {
            return onContentTap != nil
                && linkTarget(at: gestureRecognizer.location(in: self)) == nil
        }
        if pageSwipes.contains(where: { $0 === gestureRecognizer }) {
            return isPaged
        }
        guard gestureRecognizer === linkTap || gestureRecognizer === linkPress else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        return linkTarget(at: gestureRecognizer.location(in: self)) != nil
    }

    /// The chrome tap and the page swipes observe without claiming: they
    /// must fire alongside PDFKit's own recognizers, never instead of them.
    /// PDFKit's inner scroll-view pan would otherwise block the swipe, so a
    /// horizontal flick would do nothing in the snap-one-screen modes.
    override func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        for ours in [chromeTap] + pageSwipes as [UIGestureRecognizer] {
            if gestureRecognizer === ours || other === ours {
                return true
            }
        }
        return super.gestureRecognizer(
            gestureRecognizer, shouldRecognizeSimultaneouslyWith: other)
    }

    @objc private func handleChromeTap() {
        guard chromeTap.state == .ended else { return }
        onContentTap?()
    }

    @objc private func handleLinkTap() {
        guard let target = linkTarget(at: linkTap.location(in: self)) else { return }
        // ⌘-tap = background tab (macOS ⌘-click); hardware keyboards only.
        let mode: ReaderSessionModel.LinkOpenMode =
            linkTap.modifierFlags.contains(.command) ? .newTab : .here
        onLinkActivated?(target, currentNavEntry(), mode)
    }

    /// Long-press on a link opens the bespoke peek overlay: a scrollable preview
    /// of the destination at book scale with Open / New Tab / (iPad) Split
    /// buttons. Same-document links show a live preview; remote links fall back
    /// to a placeholder card so the open actions stay available.
    @objc private func handleLinkPress() {
        guard linkPress.state == .began,
              let target = linkTarget(at: linkPress.location(in: self)),
              let window
        else { return }
        let current = currentNavEntry()
        // iPad splits both ways (side-by-side + top/bottom); iPhone is
        // vertical-only (its split stacks top/bottom with one tab row).
        let splitAxes: [SplitAxis] =
            UIDevice.current.userInterfaceIdiom == .pad ? [.horizontal, .vertical] : [.vertical]
        let overlay = LinkPeekOverlayIOS(
            document: document,
            target: target,
            contentScale: scaleFactor,  // book's on-screen scale → readable at size
            splitAxes: splitAxes,
            accent: linkAccent
        ) { [weak self] mode in
            self?.onLinkActivated?(target, current, mode)
        }
        overlay.present(in: window, from: linkPress.location(in: window))
    }

    @objc private func handleScrollPan(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began {
            onScrollInteraction?()
        }
    }

    private func linkTarget(at viewPoint: CGPoint) -> LinkTarget? {
        guard
            let page = page(for: viewPoint, nearest: false),
            let annotation = page.annotation(at: convert(viewPoint, to: page)),
            let document
        else { return nil }
        return LinkResolver.target(of: annotation, in: document)
    }

    // MARK: - Hardware keyboard: ←/→ page (matches macOS, where bare
    // arrows page even in continuous display modes — PDFView only pages
    // in single-page mode on its own). Priority over system behavior so
    // the inner scroll view's arrow-scrolling doesn't swallow them; not
    // a history event (scrolling/paging never pushes history).

    override var keyCommands: [UIKeyCommand]? {
        let previous = UIKeyCommand(
            action: #selector(pagePrevious), input: UIKeyCommand.inputLeftArrow)
        let next = UIKeyCommand(
            action: #selector(pageNext), input: UIKeyCommand.inputRightArrow)
        for command in [previous, next] {
            command.wantsPriorityOverSystemBehavior = true
        }
        return [previous, next] + (super.keyCommands ?? [])
    }

    @objc private func pagePrevious() {
        if canGoToPreviousPage { goToPreviousPage(nil) }
    }

    @objc private func pageNext() {
        if canGoToNextPage { goToNextPage(nil) }
    }

    // MARK: - Swipe: turn pages in the snap-one-screen modes

    /// The non-continuous modes, where PDFKit shows a fixed screen of pages
    /// and never scrolls across a page boundary on its own.
    private var isPaged: Bool {
        displayMode == .singlePage || displayMode == .twoUp
    }

    @objc private func handlePageSwipe(_ recognizer: UISwipeGestureRecognizer) {
        switch recognizer.direction {
        case .left, .up:
            if canGoToNextPage { goToNextPage(nil) }
        default:  // .right, .down
            if canGoToPreviousPage { goToPreviousPage(nil) }
        }
    }
}

// MARK: - Link dragging (drop on the tab strip / split zone)

extension ReaderPDFViewIOS: @MainActor UIDragInteractionDelegate {
    func dragInteraction(
        _ interaction: UIDragInteraction,
        itemsForBeginning session: UIDragSession
    ) -> [UIDragItem] {
        let location = session.location(in: self)
        guard let target = linkTarget(at: location),
              target.remoteFileURL == nil  // same-document links only
        else { return [] }
        let payload = DragPayload.section(target.entry)
        let item = UIDragItem(itemProvider: NSItemProvider(object: payload as NSString))
        item.localObject = payload
        return [item]
    }
}

