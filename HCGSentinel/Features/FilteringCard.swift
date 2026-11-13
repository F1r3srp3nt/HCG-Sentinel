import SentinelCore
import SwiftUI

/// Own-device traffic filtering. Separate from the test requests above: it does not inspect or modify traffic,
/// it only asks a verified privileged helper to block or allow connections. Without such a helper it explains
/// exactly what is missing and offers no controls.
struct FilteringCard: View {
    @EnvironmentObject private var helper: HelperModel
    @EnvironmentObject private var router: Router
    @State private var rules: [EditableRule] = [EditableRule()]
    @State private var result: String?

    struct EditableRule: Identifiable, Equatable {
        let id = UUID()
        var address = ""
        var port = ""
        var transport = "tcp"
        var action = "block"
    }

    var body: some View {
        SentinelCard {
            AdaptiveStack {
                SectionLabel(text: "Own-device filtering", tone: .accent)
                StatusPill(text: helper.canUseFiltering ? "Helper verified" : "Unavailable", tone: helper.canUseFiltering ? .verified : .off)
            }
            Explanation("Not part of the test requests above. Filtering asks a privileged helper on this device to block or allow connections; it never reads or changes their content and never decrypts HTTPS.")
            if let requirement = helper.filteringRequirement {
                NoticeBanner(icon: "lock.shield", text: requirement, tone: .warning)
                Explanation("iOS gives ordinary apps no way to filter other apps’ traffic. Sentinel does not install profiles, VPNs or network extensions to work around that.")
                Button("Open Settings") { router.open(.settings) }
                    .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
            } else {
                ForEach(rules) { item in
                    let rule = binding(for: item.id)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Remote address, e.g. 203.0.113.0/24", text: rule.address)
                            .technicalInput()
                            .keyboardType(.numbersAndPunctuation)
                            .sentinelField()
                        AdaptiveStack {
                            TextField("Port (optional)", text: rule.port)
                                .keyboardType(.numberPad)
                                .sentinelField()
                            Picker("Transport", selection: rule.transport) {
                                Text("TCP").tag("tcp")
                                Text("UDP").tag("udp")
                                Text("Any").tag("any")
                            }
                            .pickerStyle(SegmentedPickerStyle())
                        }
                        Picker("Action", selection: rule.action) {
                            Text("Block").tag("block")
                            Text("Allow").tag("allow")
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                    .padding(.vertical, 4)
                }
                AdaptiveStack {
                    Button("Add rule") { rules.append(EditableRule()) }
                        .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
                        .disabled(rules.count >= HelperRequestValidator.maxFilterRules)
                    Button("Remove last") { if rules.count > 1 { rules.removeLast() } }
                        .buttonStyle(SentinelButtonStyle(kind: .secondary, fullWidth: true))
                }
                Button(action: apply) { Label("Send rules to helper", systemImage: "shield.lefthalf.filled") }
                    .buttonStyle(SentinelButtonStyle(kind: .primary, fullWidth: true))
                    .disabled(helper.operationInFlight != nil)
                if helper.verifiedOperations.contains(.clearFilterRules) {
                    Button("Remove all rules on the helper") { helper.clearFilterRules { result = $0 } }
                        .buttonStyle(SentinelButtonStyle(kind: .destructive, fullWidth: true))
                        .disabled(helper.operationInFlight != nil)
                }
            }
            if let result = result {
                NoticeBanner(icon: "info.circle", text: result, tone: .info)
            }
        }
    }

    private func binding(for id: UUID) -> Binding<EditableRule> {
        Binding(
            get: { rules.first { $0.id == id } ?? EditableRule() },
            set: { updated in
                if let index = rules.firstIndex(where: { $0.id == id }) { rules[index] = updated }
            })
    }

    private func apply() {
        let converted = rules.enumerated().map { index, rule in
            FilterRule(id: "rule\(index + 1)", action: rule.action, transport: rule.transport,
                       remoteAddress: rule.address.trimmingCharacters(in: .whitespaces),
                       remotePort: Int(rule.port.trimmingCharacters(in: .whitespaces)))
        }
        helper.applyFilterRules(converted) { result = $0 }
    }
}
