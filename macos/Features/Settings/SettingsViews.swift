import AppKit
import SwiftUI

/// The settings page's section list, hosted in a real system sidebar column.
///
/// NSSplitViewItem's sidebar owns the column: the material, its inactive-window
/// appearance, the hairline divider to the detail pane and the titlebar region all
/// come from AppKit, the same way the workspace sidebar gets them. Nothing here
/// paints a background or fixes a width, or that material would be covered up.
struct SettingsSidebar: View {
    var settings: SettingsStore
    /// Owned by the window controller, so showing the page can hand the first
    /// responder to this list instead of to the hosting container.
    let sectionFocus: SidebarListFocus
    /// The sidebar is a system source list, so it hands back an optional selection.
    /// Clearing it (⌘-click on the selected row) keeps the current section.
    private var sectionSelection: Binding<SettingsSection?> {
        Binding(get: { settings.selectedSection },
                set: { if let value = $0 { settings.selectedSection = value } })
    }
    /// A system source list owns section selection: it supplies the standard
    /// selection fill, hover, focus ring, arrow-key traversal and selected trait.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: sectionSelection) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    Label { Text(section.title) } icon: { icon(section).accessibilityHidden(true) }
                        // Fill the row so the blank space beside the label selects too.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("settings.section.\(section.rawValue)")
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .modifier(SidebarListFocusBinding(focus: sectionFocus))
                .accessibilityLabel("设置分区").accessibilityIdentifier("settings.sections")
        }.padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    @ViewBuilder private func icon(_ section: SettingsSection) -> some View {
        switch section {
        case .model: Image(systemName: "slider.horizontal.3")
        // brain is wider and heavier than the other symbols, so resizable + scaledToFit inside a
        // fixed frame shrinks it to about the width of the other rows.
        case .memory: Image(systemName: "brain").resizable().scaledToFit().frame(width: 17, height: 17)
        case .voice: Image(systemName: "waveform")
        case .planet: Image("custom.spaceship")
        case .pet: Image("custom.capsule").frame(width: 20, height: 20)
        }
    }
}

/// The settings page's detail pane: the selected section, and nothing else. Live Voice
/// keeps its controls in the chat window and on the pet strip, so settings never
/// carries them. The sidebar is its own column, so this is only the right-hand side.
struct SettingsView: View {
    var settings: SettingsStore
    var voice: VoiceSessionController
    let pets: PetCatalog
    var planets: PlanetStore
    private var section: SettingsSection { settings.selectedSection }
    var body: some View {
        // Each section is its own `Form`, so the card grouping, the label column and
        // its width, the control column, the row separators and the narrow-pane
        // stacking all come from `.formStyle(.grouped)`. The form scrolls itself,
        // which is why there is no ScrollView here. The section's name is the window
        // title, so the pane carries no heading of its own. The pane sets no font: the
        // form's own body font is the same, and a font set here would also replace the
        // form's semibold group headings (measured on macOS 27: they turn regular).
        // Nor does it set a foreground colour: given a concrete colour, the form derives its
        // row separators and button fills from it and draws them a step darker than System
        // Settings (measured on macOS 27: separators 209 vs 235 on a 247 card).
        // The grouped form's own background is wallpaper-tinted in dark mode and covers
        // anything behind it, so it is hidden for the neutral fill System Settings shows
        // (measured on macOS 27, dark: 30 vs the form's 42,39,38).
        Group {
            // Closing a retained settings window does not unmount its views.
            // Reset revealed credentials and field focus on close/reopen while
            // leaving the store's unsaved form values intact.
            // Keep the if/else chain: written as a switch, a swapped-in pane no longer
            // rejoins the key view loop (NativeAppKitEventTests.testSettingsKeyboardAndFocus).
            if section == .model { ModelSettingsView(settings: settings).id(settings.presentationRevision) }
            else if section == .memory { MemorySettingsView(settings: settings) }
            else if section == .voice { VoiceSettingsView(settings: settings, voice: voice).id(settings.presentationRevision) }
            else if section == .planet { PlanetSettingsView(planets: planets, settings: settings) }
            else { PetSettingsView(pets: pets, settings: settings) }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

extension Text {
    /// A page's note beside its controls: small, secondary and selectable.
    func settingsNotice() -> some View {
        font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary).textSelection(.enabled)
    }
}

#Preview("设置") {
    let settings = SettingsStore()
    let voice = VoiceSessionController()
    let pets = PetCatalog(
        settings: settings,
        builtinRoot: Bundle.main.resourceURL?.appendingPathComponent("pets")
    )
    let planets = PlanetStore(
        settings: settings,
        root: Bundle.main.resourceURL?.appendingPathComponent("planets"),
        voice: voice
    )
    return SettingsView(settings: settings, voice: voice, pets: pets, planets: planets)
        .frame(width: 720, height: 560)
}
