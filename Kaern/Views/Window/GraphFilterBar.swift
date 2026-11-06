import KaernKit
import SwiftUI

/// Under the toolbar while the graph leaves branches out: which ones, and Show All.
struct GraphFilterBar: View {
    let model: RepositoryModel

    var body: some View {
        if let text {
            HStack(spacing: 8) {
                Image(systemName: model.soloRef == nil ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                Text(text)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Button(model.soloRef == nil ? "Show All" : "Show All Branches") { model.showAllBranchesInGraph() }
                    .controlSize(.small)
                    .fixedSize()
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    Color.accentColor.opacity(0.07)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(text)
        }
    }

    private var text: String? {
        if let solo = model.soloRef {
            return String(localized: "The graph shows only \(RepositoryModel.graphFilterName(solo)).")
        }
        let names = model.hiddenRefs.sorted().map(RepositoryModel.graphFilterName)
        switch names.count {
        case 0: return nil
        case 1: return String(localized: "\(names[0]) is hidden in the graph.")
        case 2, 3: return String(localized: "\(names.formatted(.list(type: .and))) are hidden in the graph.")
        default: return String(localized: "\(names.count) branches are hidden in the graph.")
        }
    }
}
