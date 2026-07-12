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
/// - long-press on a link = menu: Open Here / New Tab / Split
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

    private let linkTap = UITapGestureRecognizer()
    private let linkPress = UILongPressGestureRecognizer()
    private lazy var linkMenu = UIEditMenuInteraction(delegate: self)
    /// Link under the active long-press, held for the menu callbacks.
    private var pressedLink: LinkTarget?
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

        addInteraction(linkMenu)
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
        }
        for subview in view.subviews {
            deferOtherTapRecognizers(in: subview)
        }
    }

    /// Our recognizers begin ONLY over an internal link; everywhere else
    /// they fail immediately so PDFKit's own recognizers proceed unimpeded.
    /// (PDFView is itself a UIGestureRecognizerDelegate on iOS — override,
    /// and defer to super for every recognizer that isn't ours.)
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === linkTap || gestureRecognizer === linkPress else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        return linkTarget(at: gestureRecognizer.location(in: self)) != nil
    }

    @objc private func handleLinkTap() {
        guard let target = linkTarget(at: linkTap.location(in: self)) else { return }
        // ⌘-tap = background tab (macOS ⌘-click); hardware keyboards only.
        let mode: ReaderSessionModel.LinkOpenMode =
            linkTap.modifierFlags.contains(.command) ? .newTab : .here
        onLinkActivated?(target, currentNavEntry(), mode)
    }

    @objc private func handleLinkPress() {
        guard linkPress.state == .began,
              let target = linkTarget(at: linkPress.location(in: self))
        else { return }
        pressedLink = target
        let configuration = UIEditMenuConfiguration(
            identifier: "bluefold.link",
            sourcePoint: linkPress.location(in: self)
        )
        linkMenu.presentEditMenu(with: configuration)
    }

    @objc private func handleScrollPan(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began {
            onScrollInteraction?()
        }
    }

    /// Chrome toggle: a finished tap that our link recognizer rejected and
    /// that produced no selection. Called from the deferred PDFKit taps'
    /// completion is unreliable, so use touchesEnded on the view itself.
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let touch = touches.first, touch.tapCount == 1,
              currentSelection == nil,
              linkTarget(at: touch.location(in: self)) == nil
        else { return }
        onContentTap?()
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
}

// MARK: - Link long-press menu

extension ReaderPDFViewIOS: @MainActor UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard configuration.identifier as? String == "bluefold.link",
              let target = pressedLink
        else { return nil }
        let current = currentNavEntry()
        var actions: [UIAction] = [
            UIAction(title: "Open Here", image: UIImage(systemName: "arrow.right")) {
                [weak self] _ in
                self?.onLinkActivated?(target, current, .here)
            },
            UIAction(
                title: "Open in New Tab",
                image: UIImage(systemName: "plus.rectangle.on.rectangle")
            ) { [weak self] _ in
                self?.onLinkActivated?(target, current, .newTab)
            },
        ]
        // Split pane is an iPad affordance.
        if UIDevice.current.userInterfaceIdiom == .pad {
            actions.append(UIAction(
                title: "Open in Split",
                image: UIImage(systemName: "rectangle.split.2x1")
            ) { [weak self] _ in
                self?.onLinkActivated?(target, current, .split)
            })
        }
        return UIMenu(children: actions)
    }
}
