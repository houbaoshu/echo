import AppKit

// Lookups over a hosted view's view tree and accessibility tree. AppKit only, so every view
// test target can compile this file whatever it can see of the app.

/// The first view under and including `view`, depth first, that `match` accepts.
@MainActor func findView(_ view: NSView, _ match: (NSView) -> Bool) -> NSView? {
    if match(view) { return view }
    for child in view.subviews { if let found = findView(child, match) { return found } }
    return nil
}

/// The first view of type `T` under and including `view`, depth first.
@MainActor func firstSubview<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    findView(view) { $0 is T } as? T
}

/// Visits `root` and every element under it once, in tree order: an element, its accessibility
/// children, then a view's subviews. `visit` returns true to end the walk there.
/// SwiftUI AX nodes implement the Objective-C selectors without declaring NSAccessibilityProtocol
/// conformance, so everything is reached through capability dispatch.
@MainActor private func walkAccessibility(_ root: Any, _ visit: (AnyObject) -> Bool) {
    var visited: Set<ObjectIdentifier> = []
    func walk(_ value: Any) -> Bool {
        let object = value as AnyObject
        guard visited.insert(ObjectIdentifier(object)).inserted else { return false }
        if visit(object) { return true }
        let children = (value as? NSView)?.accessibilityChildren() ?? object.accessibilityChildren?() ?? []
        for child in children { if walk(child) { return true } }
        if let view = value as? NSView { for child in view.subviews { if walk(child) { return true } } }
        return false
    }
    _ = walk(root)
}

/// The first element published with `id`, in tree order.
@MainActor func findAccessibility(_ id: String, in root: Any) -> AnyObject? {
    var found: AnyObject?
    walkAccessibility(root) { object in
        guard object.accessibilityIdentifier?() == id else { return false }
        found = object
        return true
    }
    return found
}

/// Every element published with `id`, in tree order.
@MainActor func findAllAccessibility(_ id: String, in root: Any) -> [AnyObject] {
    var found: [AnyObject] = []
    walkAccessibility(root) { object in
        if object.accessibilityIdentifier?() == id { found.append(object) }
        return false
    }
    return found
}

/// The strings the window actually draws: only static-text nodes contribute, so a test
/// can tell visible wording apart from what is published for assistive technology alone.
@MainActor func visibleText(in root: Any) -> [String] {
    var found: [String] = []
    walkAccessibility(root) { object in
        if object.accessibilityRole?() == .staticText {
            if let label = object.accessibilityLabel?() { found.append(label) }
            if let text = axValue(object) { found.append(text) }
        }
        return false
    }
    return found
}

/// Every accessible string the hosted view publishes, labels and values alike, so a
/// test can assert what the window does and does not say.
@MainActor func accessibilityText(in root: Any) -> [String] {
    var found: [String] = []
    walkAccessibility(root) { object in
        if let label = object.accessibilityLabel?() { found.append(label) }
        if let text = axValue(object) { found.append(text) }
        return false
    }
    return found
}

/// Where an element is drawn, in screen coordinates, so a test can assert what sits above
/// what without depending on the wording either one publishes.
@MainActor func axFrame(_ object: AnyObject?) -> NSRect? {
    guard let object = object as? NSObject,
          object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
    return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
}

/// SwiftUI AX nodes answer the selector without declaring the protocol, so dispatch it directly.
@MainActor func axValue(_ object: AnyObject?) -> String? {
    let selector = NSSelectorFromString("accessibilityValue")
    guard let object, object.responds(to: selector) else { return nil }
    return object.perform(selector)?.takeUnretainedValue() as? String
}
