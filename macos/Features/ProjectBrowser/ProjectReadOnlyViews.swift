import AppKit
import SwiftUI

struct ProjectReadOnlyImage: NSViewRepresentable {
    let image: CGImage
    final class Coordinator {
        var image: CGImage?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.isEditable = false
        view.setAccessibilityIdentifier("projectFiles.image")
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.image !== image else { return }
        context.coordinator.image = image
        view.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

struct ProjectReadOnlyText: NSViewRepresentable {
    let text: String
    let path: String
    final class Coordinator {
        /// What the view was last given. The view is read-only, so its string never drifts
        /// from it, and comparing against it spares copying the text storage out.
        var text = ""
        var language: PreviewSyntaxHighlighter.Language?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    /// The body text style in its monospaced design, as the chat's code blocks use.
    private static var font: NSFont {
        let body = NSFont.preferredFont(forTextStyle: .body)
        return body.fontDescriptor.withDesign(.monospaced).flatMap { NSFont(descriptor: $0, size: 0) } ?? body
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let view = NSTextView(frame: .zero)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.drawsBackground = false; view.font = Self.font
        view.textColor = .labelColor; view.textContainerInset = NSSize(width: 12, height: 12)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = true
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = view.maxSize
        view.usesFindBar = true
        view.setAccessibilityIdentifier("projectFiles.text")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let language = PreviewSyntaxHighlighter.language(for: path)
        let changed = context.coordinator.text != text
        if changed { view.string = text; context.coordinator.text = text }
        if changed || context.coordinator.language != language {
            if let storage = view.textStorage { PreviewSyntaxHighlighter.apply(to: storage, language: language) }
            context.coordinator.language = language
        }
        if changed { view.sizeToFit() }
    }
}
