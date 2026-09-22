import SwiftUI

struct MemberRow: View {
    let member: Member
    @Bindable var model: AppModel
    @State private var editing = false
    @State private var operation = "move"
    @State private var name = ""
    var body: some View {
        HStack {
            Image(systemName: member.excluded ? "minus.circle" : "doc.text")
                .font(.system(size: 14)).foregroundStyle(member.excluded ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading) {
                Text(member.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(member.name)
                Text(member.excluded ? "已排除" : URL(fileURLWithPath: member.name).pathExtension.uppercased())
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(member.conflicts, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            Menu {
                Button("在 Finder 中显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: member.path)])
                }
                Divider()
                Button("移至主题…") { operation = "move"; name = member.topic ?? ""; editing = true }
                Button("拆分为新主题…") { operation = "split"; name = ""; editing = true }
                if let topic = member.topic {
                    Button("重命名主题…") { operation = "rename"; name = topic; editing = true }
                    Button("合并主题到…") { operation = "merge"; name = ""; editing = true }
                }
                Button("排除此文件", role: .destructive) { Task { await model.edit("exclude", [String(member.id)]) } }
            } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize().accessibilityLabel("文件操作").disabled(model.busy)
        }.padding(.vertical, 5)
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 16) {
                Text(operation == "rename" ? "重命名主题" : operation == "merge" ? "合并主题" : "指定主题").font(.system(size: 14)).bold()
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
