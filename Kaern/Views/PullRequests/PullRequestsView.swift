import KaernKit
import SwiftUI

/// Sidebar › Pull Requests: checks, review state and when each was updated. Picking one shows
/// it on the right, ready to check out. Reviews happen in the browser.
struct PullRequestsView: View {
    let model: RepositoryModel
    let state: PullRequestsState
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onExitCommand { model.closePullRequests() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                model.closePullRequests()
            } label: {
                Label("History", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .help("Back to History (Esc)")

            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 14)

            Image(systemName: "arrow.triangle.pull")
                .foregroundStyle(.secondary)
            Text("Pull Requests")
                .fontWeight(.semibold)
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(updatedText(now: context.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button {
                Task { await model.loadPullRequests() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .accessibilityLabel("Refresh")
            Picker("State", selection: Binding(get: { state.showsClosed }, set: { model.setPullRequestsShowClosed($0) })) {
                Text("Open").tag(false)
                Text("Closed").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func updatedText(now: Date) -> String {
        let place = String(localized: "\(state.repositoryPath) on \(state.account.hostName)")
        guard let updated = state.updatedAt else { return place }
        return place + " · " + String(localized: "updated \(Formatters.shortRelative(updated, now: now))")
    }

    @ViewBuilder
    private var content: some View {
        if let items = state.items {
            if let error = state.error, items.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Pull Requests", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.loadPullRequests() } }
                }
            } else {
                VStack(spacing: 0) {
                    columnsHeader
                    Divider()
                    List(selection: Binding(get: { state.selected }, set: { model.selectPullRequest($0) })) {
                        ForEach(items) { item in
                            PullRequestRow(item: item, isCurrent: model.isCurrentBranch(item.pull), you: state.account.login)
                                .tag(item.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                                .contextMenu {
                                    Button("Open on \(state.account.serviceName)") { model.openOnHost(item.pull) }
                                    Button("Copy Link") { Pasteboard.copy(item.pull.htmlURL.absoluteString) }
                                    Button("Copy Branch Name") { Pasteboard.copy(item.pull.head.ref) }
                                }
                        }
                        Text(footer)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .selectionDisabled()
                            .listRowSeparator(.hidden)
                            .padding(.vertical, 6)
                    }
                    .listStyle(.plain)
                    .alternatingRowBackgrounds()
                    .focused($isFocused)
                    .onAppear { isFocused = true }
                    .overlay {
                        if items.isEmpty {
                            ContentUnavailableView(state.showsClosed ? "No Closed Pull Requests" : "No Open Pull Requests",
                                                   systemImage: "arrow.triangle.pull")
                        }
                    }
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var columnsHeader: some View {
        HStack(spacing: 12) {
            Text("Pull Request").frame(maxWidth: .infinity, alignment: .leading)
            Text("Checks").frame(width: 96, alignment: .leading)
            Text("Review").frame(width: 150, alignment: .leading)
            Text("Updated").frame(width: 86, alignment: .leading)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 22)
        .frame(height: 26)
    }

    private var footer: String {
        var parts: [String] = []
        if let open = state.openCount { parts.append(String(localized: "\(open) open")) }
        if let closed = state.closedCount { parts.append(String(localized: "\(closed) closed")) }
        let counts = parts.joined(separator: " · ")
        let source = String(localized: "Pull requests come from the \(state.account.hostName) account in Settings › Accounts.")
        return counts.isEmpty ? source : counts + ". " + source
    }
}

private struct PullRequestRow: View {
    let item: PullRequestItem
    let isCurrent: Bool
    let you: String

    private var pull: PullRequest { item.pull }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(pull.number)").foregroundStyle(.secondary)
                    Text(pull.title).fontWeight(.semibold).lineLimit(1)
                    if pull.isFromFork { Tag(text: String(localized: "Fork")) }
                    if pull.isDraft { Tag(text: String(localized: "Draft")) }
                    if isCurrent { Tag(text: String(localized: "This branch")) }
                }
                .font(.system(size: 13))
                Text("\(pull.isFromFork ? (pull.head.repo?.fullName.split(separator: "/").first.map { "\($0):" } ?? "") : "")\(pull.head.ref) → \(pull.base.ref) · \(pull.user.login)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ChecksLabel(checks: item.checks)
                .frame(width: 96, alignment: .leading)
            ReviewLabel(review: item.review)
                .frame(width: 150, alignment: .leading)
            Text(Formatters.historyDate(pull.updatedAt))
                .font(.system(size: 12))
                .frame(width: 86, alignment: .leading)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// ✓ 4 of 4 · ● 2 of 4 · ✗ 1 failing
struct ChecksLabel: View {
    let checks: [CheckRun]?

    var body: some View {
        if let checks {
            let summary = ChecksSummary(checks)
            HStack(spacing: 5) {
                if summary.total == 0 {
                    Text("No checks").foregroundStyle(.tertiary)
                } else if summary.failed > 0 {
                    Image(systemName: "xmark").foregroundStyle(Color(Palette.deleted)).fontWeight(.bold)
                    Text(summary.failed == 1 ? "1 failing" : "\(summary.failed) failing")
                } else if summary.pending > 0 {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                    Text("\(summary.passed) of \(summary.total)")
                } else {
                    Image(systemName: "checkmark").foregroundStyle(Color(Palette.added)).fontWeight(.bold)
                    Text("\(summary.passed) of \(summary.total)")
                }
            }
            .font(.system(size: 12))
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

struct ReviewLabel: View {
    let review: ReviewSummary?

    var body: some View {
        HStack(spacing: 5) {
            switch review {
            case .yourReviewRequested:
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                Text("Your review requested")
            case .changesRequested:
                Image(systemName: "xmark").foregroundStyle(Color(Palette.deleted)).fontWeight(.bold)
                Text("Changes requested")
            case .approved:
                Image(systemName: "checkmark").foregroundStyle(Color(Palette.added)).fontWeight(.bold)
                Text("Approved")
            case .reviewRequested:
                Circle().strokeBorder(Color.secondary).frame(width: 7, height: 7)
                Text("Review requested")
            case .noReviews:
                Text("No reviews").foregroundStyle(.tertiary)
            case nil:
                ProgressView().controlSize(.mini)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }
}

// MARK: - Inspector

struct PullRequestInspector: View {
    let model: RepositoryModel
    let state: PullRequestsState

    var body: some View {
        if let item = state.selectedItem {
            PullRequestDetail(model: model, item: item, hostName: state.account.serviceName, you: state.account.login)
                .id(item.id)
        } else {
            ContentUnavailableView("No Pull Request Selected", systemImage: "arrow.triangle.pull")
        }
    }
}

private struct PullRequestDetail: View {
    let model: RepositoryModel
    let item: PullRequestItem
    let hostName: String
    let you: String

    @State private var branchName = ""
    @State private var stashFirst = true
    @State private var isCheckingOut = false

    private var pull: PullRequest { item.pull }
    private var changeCount: Int { model.status.entries.count }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(pull.title)
                        .font(.system(size: 13, weight: .bold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        AccountAvatar(login: pull.user.login, url: pull.user.avatarURL)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pull.user.login).font(.system(size: 13, weight: .semibold))
                            Text("Opened \(Formatters.historyDate(pull.createdAt)) · #\(pull.number)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let body = pull.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                        Text(body)
                            .font(.system(size: 12))
                            .lineLimit(12)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            label("From")
                            Text(pull.isFromFork ? "\(pull.head.repo?.fullName.split(separator: "/").first ?? ""):\(pull.head.ref)" : pull.head.ref)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        GridRow {
                            label("Into")
                            Text(pull.base.ref)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                        }
                        GridRow {
                            label("Size")
                            if let size = item.size {
                                Text("\(size.commits == 1 ? String(localized: "1 commit") : String(localized: "\(size.commits) commits")) · \(size.changedFiles == 1 ? String(localized: "1 file") : String(localized: "\(size.changedFiles) files")) · +\(size.additions) −\(size.deletions)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                    Divider()
                    checks
                    Divider()
                    reviews
                }
                .padding(14)
            }
            Divider()
            checkOut
        }
        .onAppear {
            branchName = pull.suggestedLocalBranch
        }
    }

    @ViewBuilder
    private var checks: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let runs = item.checks {
                let summary = ChecksSummary(runs)
                Text(summary.total == 0 ? "Checks" : "Checks · \(summary.failed > 0 ? String(localized: "\(summary.failed) failing") : String(localized: "\(summary.passed) passed"))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if runs.isEmpty {
                    Text("No checks ran for the latest commit.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                ForEach(runs) { run in
                    HStack(spacing: 8) {
                        switch run.outcome {
                        case .passed: Image(systemName: "checkmark").foregroundStyle(Color(Palette.added)).fontWeight(.bold)
                        case .failed: Image(systemName: "xmark").foregroundStyle(Color(Palette.deleted)).fontWeight(.bold)
                        case .pending: Circle().fill(Color.orange).frame(width: 7, height: 7).frame(width: 14)
                        case .skipped: Image(systemName: "minus").foregroundStyle(.tertiary)
                        }
                        Text(run.name).lineLimit(1)
                        Spacer(minLength: 6)
                        if let duration = run.duration {
                            Text(Duration.seconds(duration).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.system(size: 12))
                }
            } else {
                Text("Checks").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var reviews: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reviews")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            let requested = (pull.requestedReviewers ?? []).map(\.login)
            if requested.isEmpty, item.review == .noReviews {
                Text("No reviews yet.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ForEach(requested, id: \.self) { login in
                HStack(spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                    Text(login.caseInsensitiveCompare(you) == .orderedSame ? "\(login) (you) · review requested" : "\(login) · review requested")
                }
                .font(.system(size: 12))
            }
            if let review = item.review, review == .approved || review == .changesRequested {
                ReviewLabel(review: review)
            }
        }
    }

    private var checkOut: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check out as")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Branch", text: $branchName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Local branch name")
            if changeCount > 0 {
                Toggle(changeCount == 1 ? "Stash my 1 uncommitted change first" : "Stash my \(changeCount) uncommitted changes first", isOn: $stashFirst)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            Text(pull.isFromFork
                 ? "Fetches pull/\(pull.number)/head from \(model.pullRequests?.remote ?? "origin"). No remote is added for the fork."
                 : "Fetches pull/\(pull.number)/head from \(model.pullRequests?.remote ?? "origin") and tracks \(pull.head.ref).")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(model.isCurrentBranch(pull) ? "Checked Out" : "Check Out") {
                    isCheckingOut = true
                    let name = branchName.trimmingCharacters(in: .whitespaces)
                    Task {
                        await model.checkOutPullRequest(pull, as: name, stashing: stashFirst)
                        isCheckingOut = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isCurrentBranch(pull) || branchName.trimmingCharacters(in: .whitespaces).isEmpty
                          || isCheckingOut || !model.canStartOperation || model.status.branch == branchName.trimmingCharacters(in: .whitespaces))
                Button("Open on \(hostName)") { model.openOnHost(pull) }
                Menu {
                    Button("Copy Link") { Pasteboard.copy(pull.htmlURL.absoluteString) }
                    Button("Copy Branch Name") { Pasteboard.copy(pull.head.ref) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
        }
        .padding(12)
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}
