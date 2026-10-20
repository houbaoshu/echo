import SwiftUI

struct PetSettingsView: View {
    let pets: PetCatalog
    var settings: SettingsStore
    var body: some View {
        Form {
            Section {
                if let notice = pets.notice { Text(notice).settingsNotice() }
                SpriteGrid(entries: pets.entries, highlightedID: pets.highlightedID) { pet in
                    SpriteCard(name: pet.name, preview: pet.preview, selected: pets.selectedID == pet.id,
                               currentLabel: String(localized: "\(pet.name)，当前精灵"), identifier: "settings.pet.\(pet.id)",
                               moveToTrash: pet.builtin ? nil : { pets.moveToTrash(pet.id) }) { pets.activate(pet.id) }
                }
            } header: {
                HStack {
                    Text("我的精灵")
                    Spacer()
                    Button("导入精灵…", systemImage: "plus") {
                        WorkspaceActions.chooseFolder { pets.importPet(from: $0) }
                    }.accessibilityIdentifier("settings.importPet")
                }
            }
        }
        // Listed again each time the window opens or the page is switched to, so a pet put back
        // from the Trash shows up; listed pets are not read again.
        .task(id: settings.presentationRevision) { pets.reload() }
    }
}

/// Live Voice's planet picker. Same card grid as the pets, from a different folder: a planet is
/// the voice mark, not a second pet, so it gets its own section rather than a row in 精灵.
struct PlanetSettingsView: View {
    var planets: PlanetStore
    var settings: SettingsStore
    var body: some View {
        Form {
            Section {
                if let notice = planets.notice {
                    Text(notice).settingsNotice().accessibilityIdentifier("settings.planet.notice")
                }
                SpriteGrid(entries: planets.entries, highlightedID: planets.highlightedID) { planet in
                    SpriteCard(name: planet.name, preview: planet.preview, selected: planets.selectedID == planet.id,
                               currentLabel: String(localized: "\(planet.name)，当前星球"), identifier: "settings.planet.\(planet.id)",
                               moveToTrash: planet.id.hasPrefix("imported:") ? { planets.moveToTrash(planet.id) } : nil) { planets.select(planet.id) }
                }
            } header: {
                HStack {
                    Text("我的星球")
                    Spacer()
                    Button("导入星球…", systemImage: "plus") {
                        WorkspaceActions.chooseFolder { planets.importPlanet(from: $0) }
                    }.accessibilityIdentifier("settings.importPlanet")
                }
            }
        }
        // Listed each time the window opens or the page is switched to, so a planet put back from
        // the Trash shows up, and never for a page nobody opened; listed planets are not decoded again.
        .task(id: settings.presentationRevision) { planets.loadEntries() }
    }
}

/// The pet or planet cards, scrolled to whichever one was just imported.
struct SpriteGrid<Entry: Identifiable>: View where Entry.ID == String {
    let entries: [Entry]
    let highlightedID: String?
    let card: (Entry) -> SpriteCard
    var body: some View {
        ScrollViewReader { proxy in
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 16) {
                ForEach(entries) { entry in card(entry).id(entry.id) }
            }.onChange(of: highlightedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

/// One pet or planet in its settings grid. Both grids draw this one card, so they cannot drift.
struct SpriteCard: View {
    let name: String
    let preview: CGImage
    let selected: Bool
    /// How VoiceOver names the card while it is selected — its name and 当前精灵 or 当前星球 —
    /// as one localized sentence, since the two halves do not join the same way in every language.
    let currentLabel: String
    let identifier: String
    /// Only an imported card has a menu, and its one item moves the folder to the Trash.
    var moveToTrash: (() -> Void)?
    let action: () -> Void
    var body: some View {
        if let moveToTrash {
            card.contextMenu { Button("移到废纸篓", action: moveToTrash) }
        } else { card }
    }
    private var card: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(decorative: preview, scale: 1).resizable().interpolation(.high).scaledToFit()
                    .frame(height: 130).frame(maxWidth: .infinity).padding(.top, 8)
                HStack {
                    Text(name).font(WorkspaceStyle.medium).lineLimit(1)
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(PetCardButtonStyle(selected: selected))
            // Keep the system focus ring on the card's own shape.
            .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 16))
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityLabel(selected ? currentLabel : String(localized: "\(name)，点击切换"))
            .accessibilityIdentifier(identifier)
    }
}

/// The pet card is a selectable tile, so it carries the states a system row does:
/// hover, pressed, selected and disabled.
struct PetCardButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        Card(selected: selected, pressed: configuration.isPressed) { configuration.label }
    }
    private struct Card<Content: View>: View {
        let selected: Bool
        let pressed: Bool
        @ViewBuilder let content: Content
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        var body: some View {
            let highlighted = enabled && (pressed || hovered)
            content
                .background(Color.primary.opacity(pressed ? 0.08 : hovered ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(highlighted ? 0.2 : 0.1),
                                  lineWidth: selected ? 2 : 1))
                .opacity(enabled ? 1 : 0.5)
                .onHover { hovered = $0 }
        }
    }
}
