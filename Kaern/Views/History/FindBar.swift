import KaernKit
import SwiftUI

/// The Search find bar (ScreenExplore): a scope token, the field, ‹ › through the matches, the
/// count, a key hint and Done. Commits that don't match are dimmed in the graph.
struct FindBar: View {
    let repository: RepositoryModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let search = repository.search
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Icon(Icons.search(1.4), size: 13)
                    .foregroundStyle(K.label2)
                ScopeToken(repository: repository)
                TextField(search.scope.placeholder, text: Binding(
                    get: { repository.search.query },
                    set: { repository.setSearchQuery($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(K.label)
                .focused($fieldFocused)
                .onSubmit { repository.stepSearch(1) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    repository.stepSearch(-1)
                    return .handled
                }
                .onExitCommand { repository.closeSearch() }
                if !search.query.isEmpty {
                    Button { repository.setSearchQuery("") } label: {
                        Icon(Icons.close, size: 9)
                            .foregroundStyle(K.content)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(K.label3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: 560)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(K.field))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5))
            HStack(spacing: 2) {
                StepButton(icon: Icons.arrowLeft, label: "Previous match") { repository.stepSearch(-1) }
                StepButton(icon: Icons.arrowRight, label: "Next match") { repository.stepSearch(1) }
            }
            .disabled(search.matches.isEmpty)
            Text(countText)
                .font(.system(size: 12))
                .foregroundStyle(K.label2)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            Text("Return next · ⇧Return previous · Esc closes")
                .font(.system(size: 11.5))
                .foregroundStyle(K.label3)
                .lineLimit(1)
                .layoutPriority(-1)
            GhostButton(title: "Done") { repository.closeSearch() }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background {
            ZStack(alignment: .bottom) {
                K.win
                K.sep.frame(height: 1)
            }
        }
        .onAppear { fieldFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .kaernFocusSearch)) { note in
            if (note.object as? String) == repository.id { fieldFocused = true }
        }
    }

    private var countText: String {
        let search = repository.search
        guard search.isFiltering else { return "Type to search" }
        if search.matches.isEmpty { return search.gitKey == search.key || !search.needsGit ? "No matches" : "Searching…" }
        if let position = repository.searchPosition { return "\(position) of \(search.matches.count)" }
        return search.matches.count == 1 ? "1 match" : "\(search.matches.count) matches"
    }
}

extension Notification.Name {
    /// Puts the cursor in the find bar of the repository whose id is the object.
    static let kaernFocusSearch = Notification.Name("KaernFocusSearch")
}

/// The scope token (`.tok`): what the search looks at, with a menu of the others.
private struct ScopeToken: View {
    let repository: RepositoryModel

    var body: some View {
        Menu {
            ForEach(CommitSearchScope.allCases) { scope in
                Toggle(isOn: Binding(get: { repository.search.scope == scope }, set: { _ in repository.setSearchScope(scope) })) {
                    Text(scope.title)
                    Text(scope.hint)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(repository.search.scope.title)
                    .font(KFont.weighted(11.5, 0.35))
                Icon(Icons.chevronDown, size: 8)
            }
            .foregroundStyle(K.accentText)
            .padding(.leading, 7)
            .padding(.trailing, 6)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(K.accentSoft))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Search in \(repository.search.scope.title)")
    }
}

/// ‹ and › in the find bar and Review's header (`.navb button`).
struct StepButton: View {
    let icon: SVGIcon
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 11)
                .foregroundStyle(K.label2)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverPlateStyle(radius: 6))
        .opacity(isEnabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }
}

/// `.ghost`: a small bordered button (Review All, Done, One File).
struct GhostButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(K.label)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .controlSurface(radius: 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .fixedSize()
    }
}

/// `.seg`: two or more choices in a small segmented control (Path / Tree, Split / Unified).
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var label: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(selection == value ? K.label : K.label2)
                        .padding(.horizontal, 9)
                        .frame(maxHeight: .infinity)
                        .background {
                            if selection == value {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(K.control)
                                    .shadow(color: K.shadowCtl, radius: 0.75, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(K.hover))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}
