import AppKit
import SwiftUI

/// Dragging a row out hands over the files and folders themselves, as dragging them out of
/// Finder does: the list starts the drag and draws the rows as its image, and Finder, Mail or a
/// chat app gets their URLs. A drag from a selected row carries the whole selection, one from any
/// other row that row alone. The drag only ever offers copy, so a drop on a Finder window on the
/// same disk copies instead of moving anything out of the project, and ⌘, which asks Finder to
/// move, gets no drop at all. A generated image's card drags its file out the same way.
struct ProjectFileDrag: ViewModifier {
    let url: URL?
    /// Every URL the drag carries, read once it begins.
    let draggedURLs: () -> [URL]
    private static let copyOnly = DragConfiguration(
        operationsWithinApp: .init(allowCopy: true, allowMove: false, allowDelete: false),
        operationsOutsideApp: .init(allowCopy: true, allowMove: false, allowDelete: false))
    func body(content: Content) -> some View {
        if let url {
            content
                .onDrag { NSItemProvider(object: url as NSURL) }
                // SwiftUI hands the receiver a copy it makes of the provider's file under
                // ~/Library/Caches/com.apple.SwiftUI.Drag-…, a whole folder included, and leaves it
                // there. Putting the URLs themselves on the drag pasteboard once the drag begins
                // gives the receiver the files in the project instead, and nothing is copied.
                .onDragSessionUpdated { session in
                    guard session.phase == .initial else { return }
                    let urls = draggedURLs()
                    let pasteboard = NSPasteboard(name: .drag)
                    pasteboard.clearContents()
                    pasteboard.writeObjects((urls.isEmpty ? [url] : urls) as [NSURL])
                }
                .dragConfiguration(Self.copyOnly)
        } else {
            content
        }
    }
}
