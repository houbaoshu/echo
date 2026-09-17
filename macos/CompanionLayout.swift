import Foundation
import CoreGraphics

struct CompanionLayout {
    static let capsuleWidth: CGFloat = 260
    static let collapsedHeight: CGFloat = 54
    static let expandedHeight: CGFloat = 94
    static let controlsWidth = PetSurfacePresentation.canvasWidth
    static let controlsHeight = PetSurfacePresentation.canvasHeight
    var pet: CGRect
    var activity: CGRect
    var controls: CGRect
    var isActivityBelowPet: Bool { activity.maxY <= pet.minY }
    // A fixed transparent hosting canvas avoids AppKit/SwiftUI resizing races.
    // `activity` still describes the padded visible capsule for layout checks.
    var activityCanvas: CGRect {
        CGRect(x: activity.minX,
               y: isActivityBelowPet ? activity.maxY - Self.expandedHeight - 24 : activity.minY,
               width: activity.width,
               height: Self.expandedHeight + 24)
    }
    static func place(pet: CGRect, in screen: CGRect, expanded: Bool) -> Self {
        let inset = screen.insetBy(dx: 8, dy: 8)
        let width = min(capsuleWidth + 24, inset.width)
        let height = (expanded ? expandedHeight : collapsedHeight) + 24
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
        let activity = CGRect(x: clamp(placed.midX - width / 2, inset.minX, inset.maxX - width),
                              y: below ? controls.minY + 4 - height : placed.maxY - 4,
                              width: width, height: height)
        return Self(pet: placed, activity: activity, controls: controls)
    }
    /// The visible controls, centered under the pet but kept inside their canvas.
    func controlsContent(width: CGFloat) -> CGRect {
        let center = PetSurfacePresentation.contentCenter(petCenter: pet.midX - controls.minX, width: width)
        let x = controls.minX + center - width / 2
        return CGRect(x: x, y: controls.minY, width: width, height: controls.height)
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
