import SwiftUI
import ForelCore

struct RuleEditorView: View {
    @State private var rule: Rule
    let onSave: (Rule) -> Void
    let onCancel: () -> Void

    init(rule: Rule, onSave: @escaping (Rule) -> Void, onCancel: @escaping () -> Void) {
        _rule = State(initialValue: rule)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewHeader(
                title: rule.name.isEmpty ? "New Rule" : "Edit Rule",
                subtitle: "Conditions decide which files match; actions decide what happens"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel(title: "Basics")
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassField(placeholder: "Rule name", text: $rule.name)

                            HStack {
                                Text("Scope").font(.system(size: 12)).foregroundStyle(ForelTheme.secondaryText)
                                Spacer()
                                Picker("", selection: scopeBinding) {
                                    Text("This folder").tag(0 as Int64?)
                                    Text("1 level").tag(1 as Int64?)
                                    Text("All subfolders").tag(nil as Int64?)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 260)
                            }

                            Picker("", selection: $rule.conditionMatch) {
                                Text("Match all conditions").tag(ConditionMatch.all)
                                Text("Match any condition").tag(ConditionMatch.any)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        .padding(14)
                    }

                    HStack {
                        SectionLabel(title: "Conditions")
                        Spacer()
                        Button {
                            rule.conditions.append(Condition(ruleId: rule.id, kind: .name, operator: .contains, value: ""))
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(IconButtonStyle())
                    }
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            if rule.conditions.isEmpty {
                                placeholder("No conditions — this rule matches every file in scope.")
                            }
                            ForEach($rule.conditions, id: \.id) { $condition in
                                ConditionRow(condition: $condition) {
                                    rule.conditions.removeAll { $0.id == condition.id }
                                }
                            }
                        }
                        .padding(14)
                    }

                    HStack {
                        SectionLabel(title: "Actions")
                        Spacer()
                        Button {
                            rule.actions.append(Action(ruleId: rule.id, kind: .moveToFolder, params: .object(["destination": .string("")]), position: Int64(rule.actions.count)))
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(IconButtonStyle())
                    }
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            if rule.actions.isEmpty {
                                placeholder("No actions yet — add at least one to make this rule do something.")
                            }
                            ForEach($rule.actions, id: \.id) { $action in
                                ActionRow(action: $action) {
                                    rule.actions.removeAll { $0.id == action.id }
                                }
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .scrollIndicators(.never)

            Divider().overlay(ForelTheme.divider)

            HStack {
                Toggle("Enabled", isOn: $rule.enabled)
                    .toggleStyle(.switch)
                    .tint(ForelTheme.accent)
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.primaryText)
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(SecondaryButtonStyle())
                Button("Save") { onSave(rule) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 600, height: 620)
        .background(ForelTheme.background)
        .preferredColorScheme(.dark)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(ForelTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scopeBinding: Binding<Int64?> {
        Binding(get: { rule.recursionDepth }, set: { rule.recursionDepth = $0 })
    }
}

private struct ConditionRow: View {
    @Binding var condition: Condition
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $condition.kind) {
                ForEach(ConditionEditorLabels.kinds, id: \.0) { kind, label in
                    Text(label).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Picker("", selection: $condition.operator) {
                ForEach(ConditionEditorLabels.operators, id: \.0) { op, label in
                    Text(label).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 140)

            if condition.kind == .colorLabel {
                ColorLabelPicker(selection: $condition.value, allowNone: false)
            } else {
                GlassField(placeholder: "Value", text: $condition.value)
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus")
            }
            .buttonStyle(IconButtonStyle(role: .destructive))
        }
    }
}

private struct ActionRow: View {
    @Binding var action: Action
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: kindBinding) {
                    ForEach(ConditionEditorLabels.actionKinds, id: \.0) { kind, label in
                        Text(label).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 160)

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus")
                }
                .buttonStyle(IconButtonStyle(role: .destructive))
            }

            switch action.kind {
            case .moveToFolder, .copyToFolder:
                FolderField(placeholder: "Destination folder", path: paramBinding("destination"))
            case .rename:
                GlassField(placeholder: "Pattern, e.g. {name}-{current_date}.{extension}", text: paramBinding("pattern"))
            case .addTag, .removeTag:
                GlassField(placeholder: "Tag", text: paramBinding("tag"))
            case .setColorLabel:
                ColorLabelPicker(selection: paramBinding("color"), allowNone: true)
            case .runScript:
                GlassField(placeholder: "Bash script (file path in $FOREL_FILE)", text: paramBinding("script"))
            case .moveToTrash, .delete:
                Text("No parameters")
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))
    }

    private var kindBinding: Binding<ActionKind> {
        Binding(
            get: { action.kind },
            set: { newKind in
                action = Action(id: action.id, ruleId: action.ruleId, kind: newKind, params: .object([:]), position: action.position)
            }
        )
    }

    private func paramBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { action.params[key]?.stringValue ?? "" },
            set: { newValue in
                var dict: [String: JSONValue] = [:]
                if case .object(let existing) = action.params { dict = existing }
                dict[key] = .string(newValue)
                action.params = .object(dict)
            }
        )
    }
}

enum ConditionEditorLabels {
    static let kinds: [(ConditionKind, String)] = [
        (.name, "Name"), (.extension_, "Extension"), (.kind, "Kind"), (.sizeBytes, "Size"),
        (.tags, "Tags"), (.colorLabel, "Color label"), (.contents, "Contents"),
        (.createdAt, "Date created"), (.dateModified, "Date modified"), (.dateAdded, "Date added"),
    ]

    static let operators: [(Operator, String)] = [
        (.is, "is"), (.isNot, "is not"), (.contains, "contains"), (.doesNotContain, "does not contain"),
        (.startsWith, "starts with"), (.endsWith, "ends with"), (.matchesRegex, "matches regex"),
        (.greaterThan, "greater than"), (.lessThan, "less than"), (.before, "is before"),
        (.after, "is after"), (.olderThan, "is older than"), (.withinLast, "is within the last"),
    ]

    static let actionKinds: [(ActionKind, String)] = [
        (.moveToFolder, "Move to folder"), (.copyToFolder, "Copy to folder"), (.rename, "Rename"),
        (.moveToTrash, "Move to Trash"), (.delete, "Delete"), (.addTag, "Add tag"),
        (.removeTag, "Remove tag"), (.setColorLabel, "Set color label"), (.runScript, "Run script"),
    ]
}
