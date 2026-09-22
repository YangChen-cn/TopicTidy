import SwiftUI

struct EvidenceList: View {
    let evidence: [Evidence]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(evidence) { item in
                HStack(alignment: .top, spacing: 7) {
                    Text(item.strength == "strong" ? "强" : item.strength == "weak" ? "弱" : "无")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(item.strength == "strong" ? Color.accentColor : Color.secondary)
                        .frame(width: 18)
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("评分为启发式，整理前请核对内容。")
                .font(.caption2).foregroundStyle(.tertiary)
        }.padding(.top, 6)
    }
}
