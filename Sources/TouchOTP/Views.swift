import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TouchOTPCore

struct ManagerView: View {
    @ObservedObject var vault: Vault
    @State private var selected: UUID?
    @State private var search = ""
    @State private var importing = false
    @State private var setup = false
    @State private var accessibility = AXIsProcessTrusted()
    @State private var dirty = false
    @State private var accountBusy = false
    @State private var pendingSelection: UUID?
    @State private var discardChanges = false
    let shortcutAvailable: Bool

    private var accounts: [AccountRecord] {
        vault.accounts.sorted { $0.issuer.localizedStandardCompare($1.issuer) == .orderedAscending }
    }
    private var filtered: [AccountRecord] {
        accounts.filter { search.isEmpty || $0.issuer.localizedStandardContains(search) || $0.username.localizedStandardContains(search) }
    }
    private var selection: Binding<UUID?> { Binding(get: { selected }, set: select) }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(TouchStyle.muted)
                    TextField("Search accounts", text: $search).textFieldStyle(.plain)
                        .accessibilityLabel("Search accounts")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(TouchStyle.muted) }
                            .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                    }
                }.padding(.horizontal, 10).padding(.vertical, 8)
                    .background(TouchStyle.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(TouchStyle.border))
                    .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 14)
                HStack {
                    Text("Accounts").font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Text("\(vault.accounts.count)").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 1).background(TouchStyle.well, in: Capsule())
                }.foregroundStyle(TouchStyle.muted).padding(.horizontal, 20).padding(.bottom, 6)
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: search.isEmpty ? "key.horizontal" : "magnifyingglass").font(.title2).foregroundStyle(TouchStyle.faint)
                        Text(search.isEmpty ? "Your accounts will appear here" : "No matching accounts")
                            .font(.caption).foregroundStyle(TouchStyle.muted).multilineTextAlignment(.center)
                    }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // A custom list instead of `List(selection:)`, whose system highlight ignores the palette.
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(filtered) { account in
                                SidebarRow(account: account, selected: account.id == selected)
                                    .contentShape(Rectangle())
                                    .onTapGesture { select(account.id) }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(account.id == selected ? [.isButton, .isSelected] : .isButton)
                                    .accessibilityAction { select(account.id) }
                            }
                        }.padding(.horizontal, 10).padding(.vertical, 2)
                    }
                    .focusable()
                    .hideFocusRing()
                    .onMoveCommand(perform: moveSelection)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Button { importing = true } label: {
                        Label("Import accounts", systemImage: "plus")
                    }.buttonStyle(.warm(.secondary, large: true, fill: true))
                        .disabled(vault.loadError != nil || accountBusy || vault.needsMigration)
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Fill a code").font(.system(size: 11)).foregroundStyle(TouchStyle.muted)
                            ShortcutKeys()
                        }
                        Spacer()
                        Button { setup = true } label: { Image(systemName: "gearshape").font(.system(size: 15, weight: .medium)) }
                            .buttonStyle(.plain).foregroundStyle(TouchStyle.muted).help("Autofill setup").accessibilityLabel("Autofill setup")
                            .keyboardShortcut(",", modifiers: .command)
                    }
                }.padding(16)
                    .overlay(alignment: .top) { Rectangle().fill(TouchStyle.border).frame(height: 1) }
            }
            .background(TouchStyle.sidebar)
            .navigationSplitViewColumnWidth(min: 215, ideal: 245, max: 290)
        } detail: {
            VStack(spacing: 0) {
                if let error = vault.loadError { InlineNotice(text: error).padding([.horizontal, .top], 20) }
                if vault.needsMigration {
                    ScrollView {
                        MigrationPanel(vault: vault).padding(32).frame(maxWidth: 560, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if let account = accounts.first(where: { $0.id == selected }) {
                    AccountDetail(vault: vault, record: account, dirty: $dirty, isBusy: $accountBusy).id(account.id)
                } else {
                    welcome
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(TouchStyle.background)
        }
        .tint(TouchStyle.honeyText)
        .frame(minWidth: 780, minHeight: 570)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { setup = true } label: {
                    Label(accessibility && shortcutAvailable ? "Autofill ready" : "Set up autofill",
                          systemImage: accessibility && shortcutAvailable ? "checkmark.circle" : "exclamationmark.circle")
                }.help("Permissions and keyboard shortcut")
            }
        }
        .sheet(isPresented: $importing) {
            ImportView(vault: vault) { accountID in
                search = ""
                if let accountID { select(accountID) }
            }
        }
        .sheet(isPresented: $setup) { SetupView(vault: vault, shortcutAvailable: shortcutAvailable) }
        .onReceive(NotificationCenter.default.publisher(for: .touchOTPImportRequested)) { _ in
            if vault.loadError == nil, !vault.needsMigration, !accountBusy { importing = true }
        }
        .alert("Discard unsaved destinations?", isPresented: $discardChanges) {
            Button("Keep editing", role: .cancel) { pendingSelection = nil }
            Button("Discard changes", role: .destructive) {
                dirty = false; selected = pendingSelection; pendingSelection = nil
            }
        } message: { Text("Save your changes with Touch ID before switching accounts, or discard them.") }
        .onAppear { if selected == nil { selected = vault.accounts.first?.id } }
        .onChange(of: vault.accounts.map(\.id)) { ids in
            if let selected, !ids.contains(selected) { self.selected = accounts.first?.id; dirty = false; accountBusy = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in accessibility = AXIsProcessTrusted() }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down, !filtered.isEmpty else { return }
        let index = filtered.firstIndex { $0.id == selected }
        let next = index.map { direction == .up ? max(0, $0 - 1) : min(filtered.count - 1, $0 + 1) } ?? 0
        select(filtered[next].id)
    }

    private func select(_ id: UUID?) {
        guard id != selected, !accountBusy else { return }
        if dirty { pendingSelection = id; discardChanges = true }
        else { selected = id }
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "touchid").font(.system(size: 36, weight: .regular)).foregroundStyle(TouchStyle.onHoney)
                    .frame(width: 68, height: 68).background(TouchStyle.honey, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .shadow(color: TouchStyle.honey.opacity(0.35), radius: 12, y: 5)
                    .padding(.top, 12)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your codes,\none touch away.").font(TouchStyle.title(32)).tracking(-0.6).foregroundStyle(TouchStyle.ink)
                    Text("Bring your authenticator accounts to this Mac.\nUse Touch ID whenever you need a code.")
                        .font(.system(size: 14)).foregroundStyle(TouchStyle.muted).lineSpacing(3)
                }
                Button { importing = true } label: { Label("Import accounts", systemImage: "qrcode.viewfinder") }
                    .buttonStyle(.warm(.primary, large: true)).disabled(vault.loadError != nil || vault.needsMigration)
                Rectangle().fill(TouchStyle.border).frame(height: 1)
                VStack(alignment: .leading, spacing: 18) {
                    InstructionRow(number: 1, title: "Scan your accounts", detail: "Import an export QR from Google Authenticator.")
                    InstructionRow(number: 2, title: "Choose where to fill", detail: "Link each account to a website or Mac app.")
                    InstructionRow(number: 3, title: "Use your fingerprint", detail: "Click the code field and press ⌃⌥⌘O.")
                }
                Label("Stored locally. Protected by Touch ID.", systemImage: "lock")
                    .font(.caption).foregroundStyle(TouchStyle.muted)
            }.padding(32).frame(maxWidth: 530, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AccountDetail: View {
    @ObservedObject var vault: Vault
    let record: AccountRecord
    @Binding var dirty: Bool
    @Binding var isBusy: Bool
    @State private var draft: DestinationDraft
    @State private var saved: Bindings
    @State private var website = ""
    @State private var addingWebsite = false
    @State private var websiteError: String?
    @State private var message: String?
    @State private var succeeded = false
    @State private var code: String?
    @State private var expires: Date?
    @State private var codePeriod: Double = 30
    @State private var deleting = false
    @State private var revealGeneration = UUID()
    @FocusState private var websiteFocused: Bool

    init(vault: Vault, record: AccountRecord, dirty: Binding<Bool>, isBusy: Binding<Bool>) {
        self.vault = vault; self.record = record; _dirty = dirty; _isBusy = isBusy
        _draft = State(initialValue: DestinationDraft(record.bindings))
        _saved = State(initialValue: DestinationDraft(record.bindings).bindings)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 14) {
                        AccountSymbol(issuer: record.issuer, size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.issuer).font(TouchStyle.title(26)).tracking(-0.4).foregroundStyle(TouchStyle.ink)
                            Text(record.username).font(.system(size: 13)).foregroundStyle(TouchStyle.muted).textSelection(.enabled)
                        }.padding(.top, 3)
                        Spacer()
                        Menu {
                            Button("Remove account…", role: .destructive) { deleting = true }
                        } label: { Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(TouchStyle.muted) }
                            .menuStyle(.borderlessButton).fixedSize().help("Account actions").accessibilityLabel("Account actions").disabled(isBusy)
                    }
                    codePanel
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Autofill destinations").font(TouchStyle.title(16)).foregroundStyle(TouchStyle.ink)
                            Spacer()
                            Text("\(saved.hosts.count + saved.bundleIDs.count) linked").font(.caption.weight(.medium)).foregroundStyle(TouchStyle.muted)
                        }
                        Text("Choose the websites and apps that can receive this account’s codes.")
                            .font(.callout).foregroundStyle(TouchStyle.muted)
                        GroupSurface {
                            HStack {
                                Text("Websites").font(.system(size: 12, weight: .semibold)).foregroundStyle(TouchStyle.muted)
                                Spacer()
                                Button { addingWebsite = true; websiteFocused = true } label: { Label("Add website", systemImage: "plus") }
                                    .buttonStyle(.warmQuiet).disabled(isBusy)
                            }.padding(14)
                            if draft.hosts.isEmpty && !addingWebsite {
                                Text("No websites linked").font(.callout).foregroundStyle(TouchStyle.faint).padding([.horizontal, .bottom], 14)
                            }
                            ForEach(draft.hosts, id: \.self) { host in
                                destinationRow(name: host, symbol: "globe") { draft.hosts.removeAll { $0 == host } }
                            }
                            if addingWebsite {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        TextField("example.com or https://…", text: $website).textFieldStyle(.roundedBorder)
                                            .focused($websiteFocused).onSubmit(addWebsite).accessibilityLabel("Website address")
                                        Button("Add", action: addWebsite).buttonStyle(.warmPrimary).disabled(website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                        Button { addingWebsite = false; website = ""; websiteError = nil } label: { Image(systemName: "xmark") }
                                            .buttonStyle(.borderless).help("Cancel adding website").accessibilityLabel("Cancel adding website")
                                    }
                                    Text(websiteError ?? "Use the address of the page that asks for your code.")
                                        .font(.caption).foregroundStyle(websiteError == nil ? TouchStyle.muted : TouchStyle.coral)
                                }.padding([.horizontal, .bottom], 14).disabled(isBusy)
                            }
                            Rectangle().fill(TouchStyle.border).frame(height: 1)
                            HStack {
                                Text("Mac apps").font(.system(size: 12, weight: .semibold)).foregroundStyle(TouchStyle.muted)
                                Spacer()
                                Button(action: chooseApp) { Label("Choose app…", systemImage: "plus") }
                                    .buttonStyle(.warmQuiet).disabled(isBusy)
                            }.padding(14)
                            if draft.apps.isEmpty {
                                Text("No apps linked").font(.callout).foregroundStyle(TouchStyle.faint).padding([.horizontal, .bottom], 14)
                            }
                            ForEach(draft.apps, id: \.self) { id in
                                let app = NativeAppPresentation(bundleID: id)
                                HStack(spacing: 10) {
                                    Image(nsImage: app.icon).resizable().scaledToFit().frame(width: 24, height: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name).font(.callout.weight(.medium)).foregroundStyle(TouchStyle.ink)
                                        if !app.installed { Text("Not installed on this Mac").font(.caption).foregroundStyle(TouchStyle.muted) }
                                    }
                                    Spacer()
                                    removeButton("Remove \(app.name)") { draft.apps.removeAll { $0 == id } }
                                }.padding(.horizontal, 14).padding(.bottom, 12)
                            }
                        }
                    }
                    if let message { InlineNotice(text: message, success: succeeded) }
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "cursorarrow.click").foregroundStyle(TouchStyle.honeyText)
                        Text("To autofill, click an empty code field in a linked app or website, press **⌃⌥⌘O**, then use Touch ID.")
                            .font(.caption).foregroundStyle(TouchStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(28).frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .top)
            }
            if dirty {
                HStack(spacing: 12) {
                    Circle().fill(TouchStyle.honey).frame(width: 7, height: 7)
                    Text("Unsaved changes").font(.callout.weight(.medium)).foregroundStyle(TouchStyle.ink)
                    Spacer()
                    Button("Revert") { draft = DestinationDraft(saved); message = nil }.buttonStyle(.warmSecondary).disabled(isBusy)
                    Button(action: save) { Label(isBusy ? "Saving…" : "Save changes", systemImage: "touchid") }
                        .buttonStyle(.warmPrimary).disabled(isBusy).keyboardShortcut("s", modifiers: .command)
                }.padding(.horizontal, 24).padding(.vertical, 12).background(TouchStyle.sidebar)
                    .overlay(alignment: .top) { Rectangle().fill(TouchStyle.border).frame(height: 1) }
            }
        }
        .onChange(of: draft) { value in dirty = value.bindings != saved; message = nil }
        .onChange(of: record.bindings) { _ in
            if !isBusy { saved = DestinationDraft(record.bindings).bindings; draft = DestinationDraft(saved); dirty = false }
        }
        .onDisappear { hideCode() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in code = nil }
        .confirmationDialog("Remove \(record.issuer) from TouchOTP?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Remove with Touch ID", role: .destructive) {
                isBusy = true
                Task {
                    do { try await vault.remove(record) }
                    catch { message = error.localizedDescription; succeeded = false }
                    isBusy = false
                }
            }
        } message: { Text("Google Authenticator keeps its copy. You can import the account again later.") }
    }

    private var codePanel: some View {
        GroupSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Verification code").font(.system(size: 12, weight: .semibold)).foregroundStyle(TouchStyle.muted)
                    Spacer()
                    Label("Touch ID", systemImage: "lock.fill").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(TouchStyle.honeyText)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(TouchStyle.selection, in: Capsule())
                }
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(code.map(CodeFormat.grouped) ?? "••• •••")
                            .font(TouchStyle.code(42)).tracking(1)
                            .foregroundStyle(code == nil ? TouchStyle.faint : TouchStyle.ink)
                            .textSelection(.enabled).accessibilityLabel(code == nil ? "Code hidden" : "Verification code: \(code!)")
                        if let expires, code != nil {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                HStack(spacing: 6) {
                                    let remaining = expires.timeIntervalSince(context.date)
                                    CountdownRing(fraction: remaining / codePeriod, urgent: remaining < 6, lineWidth: 2.5).frame(width: 13, height: 13)
                                    Text("Hides in \(max(0, Int(ceil(remaining))))s")
                                        .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(TouchStyle.muted)
                                }
                            }
                        } else { Text("Unlock to view your current code").font(.caption).foregroundStyle(TouchStyle.muted) }
                    }
                    Spacer(minLength: 0)
                    if code == nil {
                        Button(action: reveal) { Label(isBusy ? "Waiting…" : "Show code", systemImage: "touchid") }
                            .buttonStyle(.warm(.primary, large: true)).disabled(isBusy)
                    } else {
                        Button(action: hideCode) { Label("Hide code", systemImage: "eye.slash") }.buttonStyle(.warm(.secondary, large: true))
                    }
                }
            }.padding(20)
        }
    }
    private func destinationRow(name: String, symbol: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(TouchStyle.honeyText)
                .frame(width: 24, height: 24).background(TouchStyle.selection, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(name).font(.callout.weight(.medium)).foregroundStyle(TouchStyle.ink).textSelection(.enabled)
            Spacer()
            removeButton("Remove \(name)", action: remove)
        }.padding(.horizontal, 14).padding(.bottom, 12)
    }
    private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle").foregroundStyle(TouchStyle.muted) }
            .buttonStyle(.borderless).help(label).accessibilityLabel(label).disabled(isBusy)
    }
    private func addWebsite() {
        do { try draft.addWebsite(website); website = ""; websiteError = nil; addingWebsite = false }
        catch { websiteError = error.localizedDescription }
    }
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.prompt = "Add app"
        panel.message = "Choose the app where this account asks for a code."
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let schemes = (bundle.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        if TargetReader.safari.contains(id) || TargetReader.chromium.contains(id) || schemes.contains("http") || schemes.contains("https") {
            message = "For a browser, add the login website under Websites instead."; succeeded = false; return
        }
        do { try draft.addApp(id) } catch { message = error.localizedDescription; succeeded = false }
    }
    private func save() {
        let bindings = draft.bindings
        isBusy = true; message = nil
        Task {
            defer { isBusy = false }
            do {
                try await vault.update(record, bindings: bindings)
                saved = bindings; dirty = false; succeeded = true; message = "Autofill destinations saved."
            } catch { message = error.localizedDescription; succeeded = false }
        }
    }
    private func hideCode() { code = nil; expires = nil; revealGeneration = UUID() }
    private func reveal() {
        isBusy = true; message = nil; code = nil
        let generation = UUID(); revealGeneration = generation
        Task {
            do {
                let payload = try await vault.unlock(record, reason: "Show the verification code for \(record.issuer)")
                guard revealGeneration == generation, NSApp.isActive else { isBusy = false; return }
                let now = Date()
                code = try payload.otp.code(at: now)
                codePeriod = Double(payload.otp.period)
                expires = now.addingTimeInterval(payload.otp.remaining(at: now))
                isBusy = false
                try await Task.sleep(nanoseconds: UInt64(payload.otp.remaining(at: now) * 1_000_000_000))
                if revealGeneration == generation { code = nil; expires = nil }
            } catch { message = error.localizedDescription; succeeded = false; isBusy = false }
        }
    }
}

struct SidebarRow: View {
    let account: AccountRecord
    let selected: Bool
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) {
            AccountSymbol(issuer: account.issuer, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.issuer).font(.system(size: 13, weight: .semibold)).foregroundStyle(TouchStyle.ink).lineLimit(1)
                Text(account.username).font(.system(size: 11)).foregroundStyle(TouchStyle.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if account.bindings.hosts.isEmpty && account.bindings.bundleIDs.isEmpty {
                Image(systemName: "circle.dashed").font(.caption).foregroundStyle(TouchStyle.faint).help("Add a destination to enable autofill")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(selected ? TouchStyle.selection : hovering ? TouchStyle.well.opacity(0.7) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
    }
}

extension View {
    /// The sidebar list takes keyboard focus for arrow keys; its selected row already shows where focus is.
    @ViewBuilder func hideFocusRing() -> some View {
        if #available(macOS 14.0, *) { focusEffectDisabled() } else { self }
    }
}
