import SwiftUI
import AppKit

/// The main area in Skills mode: one library skill's SKILL.md and where it is attached.
struct SkillDetailView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.deskTheme) private var theme
    let skill: LibrarySkill
    @State private var text = ""
    @State private var original: String?
    @State private var problem: String?
    @State private var saved = false
    @State private var confirmReload = false
    private var dirty: Bool { original != nil && text != original }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name).font(.system(size: 24, weight: .bold, design: .monospaced))
                    Text(skill.url.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([skill.file]) } label: { Label("Reveal in Finder", systemImage: "folder") }
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("SKILL.md").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $text).font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden).padding(6)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        .disabled(original == nil)
                    if let problem { Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if saved { Text("Saved. Agents pick up the change in new conversations, or after /reload-skills.").font(.caption).foregroundStyle(.green) }
                    HStack {
                        Button("Reload from disk") { if dirty { confirmReload = true } else { load() } }
                        Spacer()
                        Button("Save", action: save).keyboardShortcut("s").disabled(!dirty)
                    }
                }.padding(20).frame(maxWidth: .infinity)
                Divider()
                attachedTo.frame(width: 280)
            }
        }
        .background(Color(nsColor: theme.background))
        .onAppear(perform: load)
        .onChange(of: text) { _, _ in saved = false }
        .alert("Reload and discard your edits?", isPresented: $confirmReload) {
            Button("Keep editing", role: .cancel) {}
            Button("Reload", role: .destructive, action: load)
        }
    }

    private var attachedTo: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("ATTACHED TO").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Attaching links this skill into the target's skills folder. Edits here reach every attached place.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(store.skillTargets) { target in
                    let state = store.attachment(of: skill, to: target)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: Binding(get: { state == .attached }, set: { store.setSkill(skill, attached: $0, to: target) })) {
                            Label(target.label, systemImage: icon(for: target)).lineLimit(1)
                        }.disabled(state == .conflict)
                        if state == .conflict {
                            Text("A different skill with this name is already there.").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                Text("Projects get the link listed in their .gitignore.").font(.caption2).foregroundStyle(.tertiary)
            }.padding(18)
        }
    }

    private func icon(for target: SkillTarget) -> String {
        switch target {
        case .global: return "globe"
        case .agent: return "person.crop.square"
        case .project: return "folder"
        }
    }

    private func load() {
        do {
            let content = try SkillLibrary.read(skill)
            text = content; original = content; problem = nil; saved = false
        } catch { problem = error.localizedDescription; original = nil }
    }

    private func save() {
        guard let original else { return }
        do {
            try SkillLibrary.save(text, skill: skill, original: original)
            self.original = text; problem = nil; saved = true
            store.log("skill.edited", subject: skill.name)
            store.refreshSkills()
        } catch { problem = error.localizedDescription }
    }
}

struct NewSkillView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    private var slug: String { name.trimmingCharacters(in: .whitespaces).lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New skill").font(.title2.bold())
            Text("Creates a folder in your skill library with a SKILL.md to fill in.").foregroundStyle(.secondary)
            TextField("Name", text: $name, prompt: Text("e.g. daily-news"))
            if !slug.isEmpty && !SkillLibrary.isValidName(slug) {
                Text("Use lowercase letters, numbers, and hyphens.").font(.caption).foregroundStyle(.orange)
            }
            Text("When should Claude use it?").font(.headline)
            TextEditor(text: $summary).frame(height: 90).overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create skill") { if store.createSkill(name: slug, description: summary) { dismiss() } }
                    .keyboardShortcut(.defaultAction).disabled(!SkillLibrary.isValidName(slug))
            }
        }.padding(24).frame(width: 460)
    }
}

/// The Skills row in an agent's sidebar section: shows attached skills and toggles any library skill.
struct AgentSkillsMenu: View {
    @EnvironmentObject var store: DeskStore
    let agent: AgentProfile

    var body: some View {
        let target = SkillTarget.agent(agent)
        let attached = store.librarySkills.filter { store.attachment(of: $0, to: target) == .attached }
        Menu {
            if store.librarySkills.isEmpty { Text("Your skill library is empty") }
            ForEach(store.librarySkills) { skill in
                let state = store.attachment(of: skill, to: target)
                Button { store.setSkill(skill, attached: state != .attached, to: target) } label: {
                    if state == .detached { Text(skill.name) }
                    else { Label(skill.name, systemImage: state == .attached ? "checkmark" : "exclamationmark.triangle") }
                }.disabled(state == .conflict)
            }
            Divider()
            Button("Open skill library") { store.mode = .skills }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "wand.and.stars").font(.system(size: 12))
                Text(attached.isEmpty ? "No skills attached" : attached.map(\.name).joined(separator: ", "))
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
        }.menuStyle(.borderlessButton).help("Attach or detach library skills")
    }
}
