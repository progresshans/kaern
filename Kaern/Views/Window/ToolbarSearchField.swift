import AppKit
import KaernKit
import SwiftUI

/// Search Commits (⌘F) in its own toolbar item, after the git actions as in the design
/// (SwiftUI's `searchable` field is always pinned last). In narrow windows it collapses to a
/// magnifier button that opens the field in a popover.
struct CommitSearchItem: View {
    let model: RepositoryModel
    @State private var isPopoverShown = false

    var body: some View {
        if model.isSearchCompact {
            Button {
                isPopoverShown.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(TitleBarSurface(shape: Circle()))
            .help("Search Commits (⌘F)")
            .accessibilityLabel("Search Commits")
            .popover(isPresented: $isPopoverShown, arrowEdge: .bottom) {
                CommitSearchField(model: model, autofocus: true)
                    .frame(width: 260)
                    .padding(10)
            }
            .onChange(of: model.searchFocusRequest) { isPopoverShown = true }
        } else {
            CommitSearchField(model: model, autofocus: false)
                .frame(width: 240)
                .modifier(TitleBarSurface(shape: Capsule()))
        }
    }
}

extension CommitSearchScope {
    var title: LocalizedStringKey {
        switch self {
        case .all: "Everything"
        case .message: "Message"
        case .author: "Author"
        case .path: "Path"
        case .sha: "SHA"
        }
    }

    var prompt: LocalizedStringKey {
        switch self {
        case .all: "Search Commits"
        case .message: "Words in the message"
        case .author: "Name or email"
        case .path: "File or folder"
        case .sha: "Commit SHA"
        }
    }
}

/// The field: a scope token (Message · Author · Path · SHA) in front of the text, picked from
/// the magnifier's menu or by typing "author:" and so on. Return and ⌘G go to the next match,
/// ⇧Return and ⇧⌘G to the previous one, Esc clears, Delete in an empty field drops the token.
struct CommitSearchField: View {
    @Bindable var model: RepositoryModel
    let autofocus: Bool
    @FocusState private var isFocused: Bool

    private var isActive: Bool { !model.searchText.isEmpty || model.searchScope != .all }

    var body: some View {
        HStack(spacing: 5) {
            Menu {
                Picker("Search In", selection: $model.searchScope) {
                    Text(CommitSearchScope.all.title).tag(CommitSearchScope.all)
                    Divider()
                    ForEach([CommitSearchScope.message, .author, .path, .sha]) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Search in… (type “author:”, “path:”, “sha:” or “message:” to pick)")
            .accessibilityLabel("Search In")

            if model.searchScope != .all {
                Text(model.searchScope.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .fixedSize()
                    .accessibilityLabel("Searching \(Text(model.searchScope.title))")
            }

            TextField("Search Commits", text: $model.searchText, prompt: Text(model.searchScope.prompt))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onKeyPress(.return, phases: .down) { press in
                    model.selectNextSearchMatch(backwards: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(.delete) {
                    guard model.searchText.isEmpty, model.searchScope != .all else { return .ignored }
                    model.searchScope = .all
                    return .handled
                }
                .onExitCommand {
                    if isActive { clear() } else { isFocused = false }
                }
                .accessibilityLabel("Search Commits")

            if isActive {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear Search (Esc)")
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .contentShape(Capsule())
        .onTapGesture { isFocused = true }
        .overlay {
            Capsule()
                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 2)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onChange(of: model.searchText) { _, text in
            // "author:minji" becomes the Author token and "minji".
            if let parsed = CommitSearchScope.parsePrefix(text) {
                model.searchScope = parsed.scope
                model.searchText = parsed.query
            }
        }
        .onChange(of: model.searchFocusRequest) { isFocused = true }
        .onAppear { if autofocus { isFocused = true } }
    }

    private func clear() {
        model.searchText = ""
        model.searchScope = .all
    }
}
