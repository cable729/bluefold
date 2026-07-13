import PDFKit
import ReaderCore
import ReaderUI
import UIKit

/// The long-press link peek on iOS: a contained card floating over a dimmed
/// backdrop, with a live, scrollable `PDFView` scrolled to the link's
/// destination on top and a footer toolbar beneath — a wide **Open** button
/// plus **New Tab** / **Split** (iPad-only) icon buttons. Backdrop tap dismisses.
///
/// The card content and toolbar live in a single properly-sized container, so
/// every button hit-tests correctly (an earlier version floated the buttons
/// outside their superview's bounds, which silently ate the taps).
@MainActor
final class LinkPeekOverlayIOS: UIView {
    private let onChoose: (ReaderSessionModel.LinkOpenMode) -> Void

    private let backdrop = UIView()
    private let cardContainer = UIView()
    /// The [preview card + button row] stack — the part that scales in/out.
    private var contentGroup: UIView?

    private let accent: UIColor

    init(
        document: PDFDocument?,
        target: LinkTarget,
        contentScale: CGFloat,
        splitAxes: [SplitAxis],
        accent: UIColor,
        onChoose: @escaping (ReaderSessionModel.LinkOpenMode) -> Void
    ) {
        self.onChoose = onChoose
        self.accent = accent
        super.init(frame: .zero)

        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        let backdropTap = UITapGestureRecognizer(target: self, action: #selector(handleBackdropTap))
        backdropTap.delegate = self
        backdrop.addGestureRecognizer(backdropTap)
        addSubview(backdrop)

        // The preview card (rounded, shadowed) holds ONLY the preview.
        cardContainer.backgroundColor = .systemBackground
        cardContainer.layer.cornerRadius = 14
        cardContainer.layer.cornerCurve = .continuous
        cardContainer.layer.shadowColor = UIColor.black.cgColor
        cardContainer.layer.shadowOpacity = 0.28
        cardContainer.layer.shadowRadius = 22
        cardContainer.layer.shadowOffset = CGSize(width: 0, height: 10)
        cardContainer.translatesAutoresizingMaskIntoConstraints = false

        let preview = Self.previewView(document: document, target: target, scale: contentScale)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.layer.cornerRadius = 14
        preview.layer.cornerCurve = .continuous
        preview.clipsToBounds = true
        cardContainer.addSubview(preview)

        // Buttons sit BELOW the preview, floating on the backdrop (no bar
        // behind them), with a gap matching the padding around them.
        let toolbar = makeToolbar(splitAxes: splitAxes)

        let group = UIStackView(arrangedSubviews: [cardContainer, toolbar])
        group.axis = .vertical
        group.alignment = .center
        group.spacing = 14  // padding above the button row
        group.translatesAutoresizingMaskIntoConstraints = false
        addSubview(group)
        contentGroup = group

        let cardWidth = Self.cardWidth(document: document, target: target, scale: contentScale)
        let previewHeight = Self.previewHeight(remote: target.remoteFileURL != nil)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            group.centerXAnchor.constraint(equalTo: centerXAnchor),
            group.centerYAnchor.constraint(equalTo: centerYAnchor),

            cardContainer.widthAnchor.constraint(equalToConstant: cardWidth),
            cardContainer.heightAnchor.constraint(equalToConstant: previewHeight),
            preview.topAnchor.constraint(equalTo: cardContainer.topAnchor),
            preview.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor),
        ])

        // Scroll the live preview to the destination once it has a frame.
        if let pdfView = preview as? PDFView, let document, target.remoteFileURL == nil {
            DispatchQueue.main.async { LinkPreview.scroll(pdfView, to: target, in: document) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Sizing

    private static func cardWidth(
        document: PDFDocument?, target: LinkTarget, scale: CGFloat
    ) -> CGFloat {
        let screen = UIScreen.main.bounds.width
        guard target.remoteFileURL == nil,
              let page = document?.page(at: min(max(target.entry.pageIndex, 0),
                                                max(0, (document?.pageCount ?? 1) - 1)))
        else { return min(360, screen * 0.86) }
        let column = LinkPreview.textColumnBounds(on: page)?.width
            ?? page.bounds(for: .cropBox).width
        // Text column at book scale + a gutter on each side (centered column),
        // capped so the card never runs to the screen edges.
        return min(column * scale + LinkPreview.gutter * 2, screen * 0.94)
    }

    private static func previewHeight(remote: Bool) -> CGFloat {
        remote ? 200 : min(UIScreen.main.bounds.height * 0.5, 460)
    }

    private static func previewView(
        document: PDFDocument?, target: LinkTarget, scale: CGFloat
    ) -> UIView {
        if let document, target.remoteFileURL == nil {
            let pdfView = PDFView()
            pdfView.backgroundColor = .systemBackground
            pdfView.isUserInteractionEnabled = true
            if LinkPreview.configure(
                pdfView, document: document, target: target, contentScale: scale
            ) != nil {
                return pdfView
            }
        }
        // Placeholder card (remote link or no text layer).
        let placeholder = UIView()
        placeholder.backgroundColor = .systemBackground
        let icon = UIImageView(image: UIImage(systemName: "doc.text"))
        icon.tintColor = .tertiaryLabel
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        placeholder.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: placeholder.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
        ])
        return placeholder
    }

    // MARK: - Toolbar

    private func makeToolbar(splitAxes: [SplitAxis]) -> UIStackView {
        let open = primaryButton()
        open.addTarget(self, action: #selector(chooseOpen), for: .touchUpInside)

        let newTab = iconButton(systemImage: "plus.rectangle.on.rectangle")
        newTab.addTarget(self, action: #selector(chooseNewTab), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [open, newTab])
        // One split button per available axis: side-by-side (2x1) and/or
        // top-and-bottom (1x2). iPhone offers only vertical (top/bottom).
        for axis in splitAxes {
            let icon = axis == .vertical ? "rectangle.split.1x2" : "rectangle.split.2x1"
            let button = iconButton(systemImage: icon)
            button.addAction(UIAction { [weak self] _ in
                self?.dismiss { self?.onChoose(.split(axis)) }
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        stack.axis = .horizontal
        stack.spacing = 8
        stack.distribution = .fill  // buttons keep natural widths, row is centered
        return stack
    }

    private func primaryButton() -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = "Open"
        config.image = UIImage(systemName: "arrow.right")
        config.baseBackgroundColor = accent       // theme accent
        config.baseForegroundColor = .white
        config.imagePadding = 6
        config.cornerStyle = .capsule
        config.buttonSize = .large
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Accent-filled icon button with a white glyph — matches the Open button.
    private func iconButton(systemImage: String) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: systemImage)
        config.baseBackgroundColor = accent       // theme accent
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.buttonSize = .large
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 54).isActive = true
        return button
    }

    // MARK: - Presentation

    /// Fades the backdrop in and springs the card up from `anchorPoint` (in
    /// `host` coordinates), with a light impact haptic.
    func present(in host: UIView, from anchorPoint: CGPoint) {
        frame = host.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(self)
        layoutIfNeeded()

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let group = contentGroup ?? cardContainer
        backdrop.alpha = 0
        group.alpha = 0
        let dx = anchorPoint.x - group.center.x
        let dy = anchorPoint.y - group.center.y
        group.transform = CGAffineTransform(translationX: dx * 0.35, y: dy * 0.35)
            .scaledBy(x: 0.86, y: 0.86)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.82,
                       initialSpringVelocity: 0.5) {
            self.backdrop.alpha = 1
            group.alpha = 1
            group.transform = .identity
        }
    }

    private func dismiss(then action: (() -> Void)? = nil) {
        let group = contentGroup ?? cardContainer
        UIView.animate(withDuration: 0.16, animations: {
            self.backdrop.alpha = 0
            group.alpha = 0
            group.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        }, completion: { _ in
            self.removeFromSuperview()
            action?()
        })
    }

    @objc private func handleBackdropTap() { dismiss() }
    @objc private func chooseOpen() { dismiss { self.onChoose(.here) } }
    @objc private func chooseNewTab() { dismiss { self.onChoose(.newTab) } }
}

// The backdrop tap must not fire for touches that land on the card (buttons or
// the scrollable preview).
extension LinkPeekOverlayIOS: @MainActor UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        let group = contentGroup ?? cardContainer
        return !group.frame.contains(touch.location(in: self))
    }
}
