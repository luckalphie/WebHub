import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class LauncherModel: ObservableObject {
    @Published var apps: [WebApp] = []
    @Published var icons: [String: NSImage] = [:]
    @Published var running: Set<String> = []
    @Published var editor: EditorRequest?
    @Published var iconSize = AppCenterIconSize.preference
    var action: ([String: Any]) -> Void = { _ in }
    var edit: (String?) -> Void = { _ in }
    var settings: () -> Void = {}
}

struct EditorRequest: Identifiable {
    let id = UUID()
    let app: WebApp?
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredID: String?
    @State private var draggedID: String?
    @State private var dropTargetID: String?

    private var iconSize: CGFloat { model.iconSize }
    private var tileWidth: CGFloat { iconSize + 10 }
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: iconSize + 12, maximum: iconSize + 32), spacing: 20)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("WebHub").font(.title.bold())
                Spacer()
                Button(WebHubLanguage.text("Settings"), action: model.settings)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(model.apps) { app in
                        tile(app)
                            .overlay(alignment: insertionAfter(app.id) ? .trailing : .leading) {
                                if dropTargetID == app.id && draggedID != app.id {
                                    RoundedRectangle(cornerRadius: 1).fill(Color.accentColor).frame(width: 3).padding(.vertical, 8).offset(x: insertionAfter(app.id) ? 8 : -8)
                                }
                            }
                            .onDrag {
                                draggedID = app.id
                                return NSItemProvider(object: app.id as NSString)
                            } preview: { tile(app).frame(width: tileWidth) }
                            .onDrop(of: [.plainText], delegate: AppTileDropDelegate(targetID: app.id, draggedID: $draggedID, dropTargetID: $dropTargetID, action: model.action))
                    }
                    Button(action: { model.edit(nil) }) {
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: iconSize * 0.32))
                                .frame(width: iconSize * 0.8, height: iconSize * 0.8)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: iconSize * 0.18))
                            Text(WebHubLanguage.text("Add")).font(.caption)
                        }.frame(width: tileWidth)
                    }.buttonStyle(.plain)
                }.padding(8)
            }
        }
        .sheet(item: $model.editor) { request in AppEditor(model: model, app: request.app) }
        .padding(24)
        .background {
            ZStack {
                LinearGradient(colors: colorScheme == .dark ? [Color(red: 16/255, green: 22/255, blue: 39/255), Color(red: 19/255, green: 26/255, blue: 44/255), Color(red: 12/255, green: 18/255, blue: 32/255)] : [Color(red: 244/255, green: 248/255, blue: 1), Color(red: 234/255, green: 240/255, blue: 250/255), Color(red: 232/255, green: 238/255, blue: 247/255)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(red: 16/255, green: 185/255, blue: 129/255).opacity(colorScheme == .dark ? 0.24 : 0.28), .clear], center: UnitPoint(x: 0.20, y: 0.92), startRadius: 0, endRadius: 510)
                RadialGradient(colors: [Color(red: 251/255, green: 146/255, blue: 60/255).opacity(colorScheme == .dark ? 0.30 : 0.32), .clear], center: UnitPoint(x: 0.72, y: 0.96), startRadius: 0, endRadius: 620)
                RadialGradient(colors: [Color(red: 232/255, green: 121/255, blue: 249/255).opacity(colorScheme == .dark ? 0.30 : 0.38), .clear], center: UnitPoint(x: 0.88, y: 0.04), startRadius: 0, endRadius: 560)
                RadialGradient(colors: [Color(red: 96/255, green: 165/255, blue: 250/255).opacity(colorScheme == .dark ? 0.42 : 0.50), .clear], center: UnitPoint(x: 0.12, y: 0.06), startRadius: 0, endRadius: 680)
            }.ignoresSafeArea()
        }
    }

    private func insertionAfter(_ targetID: String) -> Bool {
        guard let from = model.apps.firstIndex(where: { $0.id == draggedID }), let target = model.apps.firstIndex(where: { $0.id == targetID }) else { return false }
        return from < target
    }

    private func tile(_ app: WebApp) -> some View {
        Button(action: { model.action(["type": "open", "id": app.id]) }) {
            VStack(spacing: 5) {
                Group {
                    if let image = model.icons[app.id] {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Text(app.name).font(.headline).multilineTextAlignment(.center).lineLimit(3).padding(6)
                    }
                }
                .frame(width: iconSize, height: iconSize)
                // 图标图片四周有透明边距，扣除底部留白以居中运行指示点。
                .padding(.bottom, model.icons[app.id] == nil ? 0 : -iconSize * 0.1)
                Circle().fill(model.running.contains(app.id) ? Color.primary.opacity(0.55) : .clear).frame(width: 5, height: 5)
                Text(app.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            }.frame(width: tileWidth)
        }
        .buttonStyle(.plain)
        .offset(y: hoveredID == app.id ? -2 : 0)
        .animation(.easeOut(duration: 0.16), value: hoveredID == app.id)
        .onHover { hoveredID = $0 ? app.id : (hoveredID == app.id ? nil : hoveredID) }
        .contextMenu {
            Button(WebHubLanguage.text("Open")) { model.action(["type": "open", "id": app.id]) }
            Button(WebHubLanguage.text("Edit…")) { model.edit(app.id) }
            if app.effectiveIconMode == .website { Button(WebHubLanguage.text("Refresh Icon")) { model.action(["type": "reicon", "id": app.id]) } }
            Divider()
            Button(WebHubLanguage.text("Clear Sign-in Data")) { model.action(["type": "clearlogin", "id": app.id]) }
            Button(WebHubLanguage.text("Remove App")) { model.action(["type": "delete", "id": app.id]) }
        }
    }
}

private struct AppEditor: View {
    @ObservedObject var model: LauncherModel
    let app: WebApp?
    @State private var name: String
    @State private var url: String
    @State private var domains: String
    @State private var isolated: Bool
    @State private var iconURL: String
    @State private var iconMode: String
    @State private var accent: String

    init(model: LauncherModel, app: WebApp?) {
        self.model = model
        self.app = app
        _name = State(initialValue: app?.name ?? "")
        _url = State(initialValue: app?.url ?? "")
        _domains = State(initialValue: app?.supportedDomains?.joined(separator: ", ") ?? "")
        _isolated = State(initialValue: app?.usesIsolatedLogin ?? false)
        _iconURL = State(initialValue: app?.iconURL ?? "")
        _iconMode = State(initialValue: app?.effectiveIconMode.rawValue ?? "website")
        _accent = State(initialValue: app?.accent ?? AccentPalette.defaultColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(WebHubLanguage.text(app == nil ? "Add App" : "Edit App")).font(.headline)
            Form {
                TextField(WebHubLanguage.text("Name"), text: $name)
                TextField("URL", text: $url)
                TextField(WebHubLanguage.text("Supported Domains"), text: $domains)
                Toggle(WebHubLanguage.text("Separate Sign-in Data"), isOn: $isolated)
                Picker(WebHubLanguage.text("Icon Source"), selection: $iconMode) {
                    Text(WebHubLanguage.text("Website Icon")).tag("website")
                    Text(WebHubLanguage.text("App Name")).tag("name")
                }
                if iconMode == "website" { TextField(WebHubLanguage.text("Custom Icon URL"), text: $iconURL) }
                Picker(WebHubLanguage.text("Accent Color"), selection: $accent) {
                    ForEach(AccentPalette.colors, id: \.self) { Text($0).tag($0) }
                }
            }
            HStack {
                Spacer()
                Button(WebHubLanguage.text("Cancel")) { model.editor = nil }
                Button(WebHubLanguage.text("Save")) {
                    var body: [String: Any] = ["type": app == nil ? "add" : "update", "name": name.trimmingCharacters(in: .whitespacesAndNewlines), "url": url.trimmingCharacters(in: .whitespacesAndNewlines), "supportedDomains": domains.trimmingCharacters(in: .whitespacesAndNewlines), "isolatedLogin": isolated, "iconURL": iconURL.trimmingCharacters(in: .whitespacesAndNewlines), "iconMode": iconMode, "accent": accent]
                    if let app { body["id"] = app.id }
                    model.action(body)
                    model.editor = nil
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 460)
    }
}

private struct AppTileDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggedID: String?
    @Binding var dropTargetID: String?
    let action: ([String: Any]) -> Void

    func dropEntered(info: DropInfo) { if draggedID != targetID { dropTargetID = targetID } }
    func dropExited(info: DropInfo) { if dropTargetID == targetID { dropTargetID = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        defer { draggedID = nil; dropTargetID = nil }
        guard let from = draggedID, from != targetID else { return false }
        action(["type": "move", "from": from, "to": targetID])
        return true
    }
}
