import SwiftUI

/// "What do the rewrite styles mean" — the same info-circle popover
/// pattern as the Runs and Datasets explainers, since a menu picker can't
/// carry per-option help.
struct RewriteStyleInfoPopover: View {
    @State private var showing = false
    private var loc: Localization { .shared }

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(loc.t(.cpStyleInfoHelp))
        .popover(isPresented: $showing) {
            Text(loc.t(.cpStyleInfoBody))
                .font(.callout)
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
        }
    }
}

/// The §8 grammar's Persona/Medium/Audience/Mode register pickers, shared by
/// `ComposeView` and `VoiceProfileView` so the two screens' register
/// controls (and persona-disambiguation label) can never drift apart.
/// Display labels for raw stored medium/mode tokens — stored/engine values
/// stay raw ("email"/"sms"/"doc"/"chat"; "casual"/"logistics"/…); only the
/// display is localized, reusing the Browse tab's kind labels. Non-generic
/// on purpose: statics on the generic `RegisterControls` can't be referenced
/// from other files without specialization.
@MainActor
enum KindLabels {
    static func medium(_ medium: String) -> String {
        let loc = Localization.shared
        return switch medium {
        case "email": loc.t(.brEmail)
        case "sms": loc.t(.brMessages)
        case "doc": loc.t(.brDocs)
        case "chat": loc.t(.brAIChats)
        default: medium.capitalized
        }
    }

    static func mode(_ mode: String) -> String {
        let loc = Localization.shared
        return switch mode {
        case "casual": loc.t(.cpModeCasual)
        case "logistics": loc.t(.cpModeLogistics)
        case "professional": loc.t(.cpModeProfessional)
        case "pitch": loc.t(.cpModePitch)
        case "essay": loc.t(.cpModeEssay)
        default: mode.capitalized
        }
    }
}

struct RegisterControls<Trailing: View>: View {
    @Binding var personaAccountID: Int64?
    @Binding var medium: String?
    @Binding var audience: String?
    @Binding var mode: String?
    let personas: [AccountSummary]
    /// Right-aligned extra control in the same row — Compose puts the
    /// trained-run picker here; Voice Profile passes nothing.
    let trailing: Trailing

    init(personaAccountID: Binding<Int64?>, medium: Binding<String?>,
         audience: Binding<String?>, mode: Binding<String?>,
         personas: [AccountSummary],
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        _personaAccountID = personaAccountID
        _medium = medium
        _audience = audience
        _mode = mode
        self.personas = personas
        self.trailing = trailing()
    }

    private var loc: Localization { .shared }

    var body: some View {
        GroupBox(loc.t(.cpRegister)) {
            HStack(spacing: 16) {
                Picker(loc.t(.cpPersona), selection: $personaAccountID) {
                    Text(loc.t(.cpAny)).tag(Int64?.none)
                    // Several accounts can share a persona ("Work" × 4), so
                    // the persona alone is ambiguous — the handle is what
                    // actually identifies which voice's mail pool this is.
                    ForEach(personas) { account in
                        Text(Self.personaLabel(for: account)).tag(Int64?.some(account.id))
                    }
                }
                Picker(loc.t(.brMedium), selection: $medium) {
                    Text(loc.t(.cpAny)).tag(String?.none)
                    ForEach(ComposeViewModel.media, id: \.self) { medium in
                        Text(Self.mediumLabel(medium)).tag(String?.some(medium))
                    }
                }
                Picker(loc.t(.audColAudience), selection: $audience) {
                    Text(loc.t(.cpAny)).tag(String?.none)
                    ForEach(ComposeViewModel.audiences, id: \.self) { audience in
                        Text(AudiencesTab.bucketLabel(audience)).tag(String?.some(audience))
                    }
                }
                Picker(loc.t(.cpModeLabel), selection: $mode) {
                    Text(loc.t(.cpStyleAuto)).tag(String?.none)
                    ForEach(ComposeViewModel.modes, id: \.self) { mode in
                        Text(Self.modeLabel(mode)).tag(String?.some(mode))
                    }
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.vertical, 4)
        }
    }

    static func mediumLabel(_ medium: String) -> String {
        KindLabels.medium(medium)
    }

    static func modeLabel(_ mode: String) -> String {
        KindLabels.mode(mode)
    }

    /// "Work — jane@company.com" when a persona name is shared by several
    /// accounts (or always, for clarity); just the handle when unnamed.
    static func personaLabel(for account: AccountSummary) -> String {
        guard let persona = account.persona else { return account.handle }
        return "\(persona) — \(account.handle)"
    }
}
