import AppKit
import SwiftUI

/// Settings → Outside MCP clients, below its switch: the endpoint, each
/// client's token (shown once) and copyable configuration snippets.
struct OutsideClientsSettingsView: View {
    @ObservedObject var model: AppModel
    /// The client whose snippets are open (with a placeholder for its token).
    @State var selected: String?
    @State var naming: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MCP clients on this Mac, such as Claude Desktop, Codex or Cursor, can list and read your sessions, send to them and start new ones, with a token you create. They cannot delegate, stop or change a session, or answer questions and approvals.")
                .fixedSize(horizontal: false, vertical: true)
            if let url = model.outsideURL {
                row {
                    Text(url.absoluteString).font(.system(size: 11, design: .monospaced)).foregroundStyle(CompanionStyle.text).textSelection(.enabled)
                        .fixedSize()
                } trailing: { copyButton(url.absoluteString, label: "Copy URL") }
                if model.outsidePortChanged {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("The port changed since you last looked. Clients set up earlier need this new URL.")
                            .foregroundStyle(CompanionStyle.amber).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("OK") { model.acknowledgeOutsidePort() }.buttonStyle(NotchPillButtonStyle(small: true))
                    }
                }
            } else {
                Text("Starting the local server…")
            }
            if let revealed = model.revealedOutsideToken, let client = model.outsideClients.first(where: { $0.id == revealed.clientID }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Token for \(client.name). Copy it now: it is not shown again.").foregroundStyle(CompanionStyle.text)
                    HStack(spacing: 8) {
                        Text(revealed.token).font(.system(size: 11, design: .monospaced)).foregroundStyle(CompanionStyle.text)
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        copyButton(revealed.token, label: "Copy token")
                    }
                    snippets(token: revealed.token)
                    HStack {
                        Spacer(minLength: 0)
                        Button("Done") { model.revealedOutsideToken = nil }.buttonStyle(NotchPillButtonStyle(prominent: true, small: true))
                    }
                }
            }
            ForEach(model.outsideClients) { client in
                VStack(alignment: .leading, spacing: 6) {
                    row {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(client.name).foregroundStyle(CompanionStyle.text).fixedSize(horizontal: false, vertical: true)
                            Text("Created \(client.createdAt.formatted(date: .abbreviated, time: .omitted)) · "
                                 + (client.lastUsedAt.map { "last used \(SessionDigest.compactAge(Date().timeIntervalSince($0))) ago" } ?? "never used"))
                                .fixedSize()
                        }
                    } trailing: {
                        if model.revealedOutsideToken?.clientID != client.id {
                            Button("Setup") { selected = selected == client.id ? nil : client.id }
                                .buttonStyle(NotchPillButtonStyle(small: true, selected: selected == client.id))
                                .help("Configuration snippets for this client, with a placeholder for its token")
                        }
                        Button("Revoke") { model.revokeOutsideClient(client.id); if selected == client.id { selected = nil } }
                            .buttonStyle(NotchPillButtonStyle(small: true))
                            .help("Delete this token and disconnect the client")
                    }
                    if selected == client.id, model.revealedOutsideToken?.clientID != client.id { snippets(token: nil) }
                }
            }
            if let name = naming {
                HStack(spacing: 8) {
                    TextField("Client name, such as Claude Desktop", text: Binding(get: { name }, set: { naming = $0 }))
                        .gitField(lines: 1...1)
                        .onSubmit(create)
                        .accessibilityLabel("Client name")
                    Button("Cancel") { naming = nil }.buttonStyle(NotchPillButtonStyle(small: true))
                    Button("Create", action: create).buttonStyle(NotchPillButtonStyle(prominent: true, small: true))
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button("New client token") { naming = ""; selected = nil }.buttonStyle(NotchPillButtonStyle(small: true))
            }
        }
        .font(PanelTheme.pick(CompanionStyle.caption, .system(size: 10.5), .system(size: 11)))
        .foregroundStyle(PanelTheme.current == .refined ? CompanionStyle.tertiary : CompanionStyle.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PanelTheme.pick(14, 12, 12)).padding(.bottom, 10)
    }

    private func create() {
        guard let name = naming, model.createOutsideClient(name: name) != nil else { return }
        naming = nil
        selected = nil
    }

    @ViewBuilder private func snippets(token: String?) -> some View {
        if let url = model.outsideURL {
            ForEach(OutsideClients.snippets(url: url, token: token, bridge: Bundle.main.executableURL?.path), id: \.title) { snippet in
                VStack(alignment: .leading, spacing: 3) {
                    row { Text(snippet.title).fixedSize() } trailing: { copyButton(snippet.text, label: "Copy") }
                    Text(snippet.text).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(CompanionStyle.text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    /// Side by side where it fits, else the controls under the text, so nothing truncates in the narrow sidebar.
    private func row<Leading: View, Trailing: View>(@ViewBuilder _ leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) -> some View {
        let leading = leading(), trailing = trailing()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { leading; Spacer(minLength: 0); HStack(spacing: 8) { trailing } }
            VStack(alignment: .leading, spacing: 4) { leading; HStack(spacing: 8) { trailing } }
        }
    }

    private func copyButton(_ text: String, label: String) -> some View {
        Button(label) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        .buttonStyle(NotchPillButtonStyle(small: true))
    }
}
