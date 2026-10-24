import SwiftUI

/// Shared evidence row for the overview's observations, signals, and reports.
struct WorkspaceActivityRow: View {
    let symbol: String
    let title: String
    let detail: String
    let timestamp: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15))
                .foregroundStyle(color).frame(width: 32, height: 32)
                .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { Text(detail); Text("·"); Text(timestamp) }
                    VStack(alignment: .leading, spacing: 3) { Text(detail); Text(timestamp) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
