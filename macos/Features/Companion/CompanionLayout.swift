import Foundation
import CoreGraphics

struct CompanionLayout {
    static let capsuleWidth: CGFloat = 330
    static let collapsedHeight: CGFloat = 56
    static let expandedHeight: CGFloat = 96
    static let activityPadding: CGFloat = 48
    /// How far a card's ✕ reaches past its top and leading edges.
    static let closeButtonOverhang: CGFloat = 4
    static let controlsWidth = PetSurfacePresentation.canvasWidth
    static let controlsHeight = PetSurfacePresentation.canvasHeight
    var pet: CGRect
    var activity: CGRect
    var controls: CGRect
    /// The bubble canvas between the pet and the activity; empty unless room was reserved.
    var bubble: CGRect = .zero
    var isActivityBelowPet: Bool { activity.maxY <= pet.minY }
    // Keep the original card placement, expanding only the transparent host so the
    // 20 pt shadow and its 6 pt vertical offset can fade before the window boundary.
    var activityCanvas: CGRect {
        activity.insetBy(dx: 12 - Self.activityPadding, dy: 12 - Self.activityPadding)
    }
    /// `bubble` reserves the bubble canvas between the pet and the activity, e.g. for a voice session.
    static func place(pet: CGRect, in screen: CGRect, expanded: Bool, bubble reservesBubble: Bool = false, activityHeight: CGFloat? = nil) -> Self {
        let inset = screen.insetBy(dx: 8, dy: 8)
        let width = min(capsuleWidth + 24, inset.width)
        let height = min((activityHeight ?? (expanded ? expandedHeight : collapsedHeight)) + 24, inset.height - pet.height - controlsHeight - 8)
        // Keep room for the controls below the pet. The activity goes toward
        // the screen center, so it never reserves space above a top-edge pet.
        // Coordinates are AppKit's bottom-up points.
        let x = clamp(pet.minX, inset.minX, inset.maxX - pet.width)
        let y = clamp(pet.minY, inset.minY + controlsHeight, inset.maxY - pet.height)
        let placed = CGRect(x: x, y: y, width: pet.width, height: pet.height)
        // Like the activity, the controls use a fixed canvas; only their content moves and resizes.
        let controls = CGRect(x: clamp(placed.midX - controlsWidth / 2, inset.minX, inset.maxX - controlsWidth),
                              y: placed.minY - controlsHeight, width: controlsWidth, height: controlsHeight)
        let below = placed.midY >= screen.midY
        let left = clamp(placed.midX - width / 2, inset.minX, inset.maxX - width)
        let bubbleHeight = reservesBubble ? CompanionBubbleContent.canvasHeight : 0
        let bubble = CGRect(x: left, y: below ? controls.minY - bubbleHeight : placed.maxY, width: width, height: bubbleHeight)
        // The capsule's 12 pt transparent padding overlaps the pet side by 4 pt; the bubble keeps its own margin.
        let overlap: CGFloat = reservesBubble ? 12 : 4
        let activity = CGRect(x: left, y: clamp(below ? bubble.minY + overlap - height : bubble.maxY - overlap, inset.minY, inset.maxY - height),
                              width: width, height: height)
        return Self(pet: placed, activity: activity, controls: controls, bubble: reservesBubble ? bubble : .zero)
    }
    /// The visible controls, centered under the pet but kept inside their canvas.
    func controlsContent(width: CGFloat) -> CGRect {
        let center = PetSurfacePresentation.contentCenter(petCenter: pet.midX - controls.minX, width: width)
        let x = controls.minX + center - width / 2
        return CGRect(x: x, y: controls.minY, width: width, height: controls.height)
    }
    /// The collapsed bar of `size`, where the controls draw it: hanging from the top of their row.
    func collapsedBar(size: CGSize) -> CGRect {
        let content = controlsContent(width: size.width)
        return CGRect(x: content.minX, y: controls.maxY - PetSurfacePresentation.collapsedTop - size.height,
                      width: size.width, height: size.height)
    }
    static func screen(for pet: CGRect, screens: [CGRect]) -> CGRect? {
        screens.min { left, right in
            func distance(_ screen: CGRect) -> CGFloat {
                let dx = pet.midX - clamp(pet.midX, screen.minX, screen.maxX)
                let dy = pet.midY - clamp(pet.midY, screen.minY, screen.maxY)
                return dx * dx + dy * dy
            }
            return distance(left) < distance(right)
        }
    }
    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}
