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
final class ReaderPDFViewIOS: PDFView {
    /// Called with the resolved target and the position being navigated
    /// *away from* (the history push target). The handler performs the
    /// navigation; PDFView's own link handling never sees the tap.
    var onLinkActivated: ((_ target: LinkTarget, _ current: NavEntry) -> Void)?

    private let linkTap = UITapGestureRecognizer()
    /// Recognizers already told to wait for ours (idempotence guard for the
    /// per-layout re-walk; holds identifiers, not references).
    private var deferredRecognizers: Set<ObjectIdentifier> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLinkTap()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLinkTap()
    }

    private func configureLinkTap() {
        linkTap.addTarget(self, action: #selector(handleLinkTap))
        linkTap.delegate = self
        addGestureRecognizer(linkTap)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // PDFKit attaches its own tap recognizers (link handling, selection)
        // to internal subviews, some lazily — re-walk on every layout and
        // make each one wait for our link tap to fail. Off links, ours fails
        // instantly in gestureRecognizerShouldBegin, so scrolling and
        // selection are unaffected.
        deferOtherTapRecognizers(in: self)
    }

    private func deferOtherTapRecognizers(in view: UIView) {
        for recognizer in view.gestureRecognizers ?? [] {
            guard recognizer !== linkTap, recognizer is UITapGestureRecognizer else { continue }
            if deferredRecognizers.insert(ObjectIdentifier(recognizer)).inserted {
                recognizer.require(toFail: linkTap)
            }
        }
        for subview in view.subviews {
            deferOtherTapRecognizers(in: subview)
        }
    }

    /// Our recognizer begins ONLY over an internal link; everywhere else it
    /// fails immediately so PDFKit's own recognizers proceed unimpeded.
    /// (PDFView is itself a UIGestureRecognizerDelegate on iOS — override,
    /// and defer to super for every recognizer that isn't ours.)
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === linkTap else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        return linkTarget(at: gestureRecognizer.location(in: self)) != nil
    }

    @objc private func handleLinkTap() {
        guard let target = linkTarget(at: linkTap.location(in: self)) else { return }
        onLinkActivated?(target, currentNavEntry())
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

    private func linkTarget(at viewPoint: CGPoint) -> LinkTarget? {
        guard
            let page = page(for: viewPoint, nearest: false),
            let annotation = page.annotation(at: convert(viewPoint, to: page)),
            let document
        else { return nil }
        return LinkResolver.target(of: annotation, in: document)
    }
}
