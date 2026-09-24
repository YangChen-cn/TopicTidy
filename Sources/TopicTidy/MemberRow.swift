import SwiftUI

struct MemberRow: View {
    let member: Member
    @Bindable var model: AppModel
    @State private var editing = false
    @State private var operation = "move"
    @State private var name = ""
    @State private var quickLookURL: URL?
    var body: some View {
        HStack {
            Image(systemName: member.applied ? "checkmark.circle" : member.excluded ? "minus.circle" : "doc.text")
                .font(.body).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(member.name).font(.callout).lineLimit(1).truncationMode(.middle).help(member.name)
                Text(member.applied ? "已整理" : member.excluded ? "已取消" : URL(fileURLWithPath: member.name).pathExtension.uppercased())
                    .font(.caption).foregroundStyle(.secondary)
                if !member.memberReason.isEmpty, !member.applied {
                    Text(member.memberReason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                ForEach(member.conflicts, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            Menu {
                Button("快速查看", systemImage: "eye") {
                    quickLookURL = URL(fileURLWithPath: member.path)
                }
                Button("在 Finder 中显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: member.path)])
                }
                Divider()
                Button("移至主题…") { operation = "move"; name = member.topic ?? ""; editing = true }
                    .disabled(model.busy || member.applied)
                Button("拆分为新主题…") { operation = "split"; name = ""; editing = true }
                    .disabled(model.busy || member.applied)
                if let topic = member.topic {
                    Button("重命名主题…") { operation = "rename"; name = topic; editing = true }
                        .disabled(model.busy || member.applied)
                    Button("合并主题到…") { operation = "merge"; name = ""; editing = true }
                        .disabled(model.busy || member.applied)
                }
                Button("排除此文件", role: .destructive) { Task { await model.edit("exclude", [String(member.id)]) } }
                    .disabled(model.busy || member.applied)
            } label: { Label("文件操作", systemImage: "ellipsis") }
                .labelStyle(.iconOnly).menuIndicator(.hidden).menuStyle(.borderlessButton)
                .fixedSize()
        }.padding(.vertical, 5)
        .quickLookPreview($quickLookURL)
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 16) {
                Text(operation == "rename" ? "重命名主题" : operation == "merge" ? "合并主题" : "指定主题")
                    .font(.headline)
                TextField("主题名称", text: $name).textFieldStyle(.roundedBorder)
                Text("使用已有主题名可将文件归入该主题。").foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消") { editing = false }.keyboardShortcut(.cancelAction)
                    Button("保存") {
                        let args = (operation == "rename" || operation == "merge")
                            ? [member.topic ?? "", name] : [String(member.id), name]
                        editing = false
                        Task { await model.edit(operation, args) }
                    }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.padding().frame(width: 310)
        }
    }
}
