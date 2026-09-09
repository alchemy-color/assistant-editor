import SwiftUI

// MARK: - Shared UI Kit
// Canonical patterns for the whole app. When in doubt, use these.

enum UIDesign {
    static let cornerChip: CGFloat = 6        // chips, small badges
    static let cornerCard: CGFloat = 6        // panels, banners, notes
    static let padH: CGFloat = 16             // horizontal page padding
    static let padHeaderTop: CGFloat = 14
    static let padHeaderBottom: CGFloat = 10
}

// MARK: Section Title (top of a panel)
// Canonical panel/section header: title2 text, UIDesign paddings, trailing slot for
// per-header action buttons (find clips, clear, etc.). Use wherever a manual
// `Text(...).scaledFont(.title2)` + padding header would otherwise be written.

struct SectionTitle<Trailing: View>: View {
    let text: String
    @ViewBuilder private let trailing: () -> Trailing

    init(_ text: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(text)
                .scaledFont(.title3)
            Spacer()
            trailing()
        }
        .padding(.horizontal, UIDesign.padH)
        .padding(.top, UIDesign.padHeaderTop)
        .padding(.bottom, 4)
    }
}

// MARK: Activity Spinner (canonical busy indicator)
// One sizing for all in-progress affordances. `.controlSize` variants used elsewhere
// render differently in every context; this keeps a steady visual.

struct Activity: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
    }
}

// MARK: Loading Page (centered spinner + label for full-panel load states)

struct LoadingPage: View {
    let title: String
    var body: some View {
        VStack(spacing: 12) {
            Activity()
            Text(title)
                .scaledFont(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Folder Chip

struct FolderChip: View {
    let text: String
    var healthy: Bool? = nil   // green dot when the folder carries a project file, red when not
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if let healthy {
                Circle()
                    .fill(healthy ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                    .help(healthy
                        ? "Project file detected in \(text)"
                        : "No project file detected in \(text)")
            }
            Image(systemName: "folder")
                .scaledFont(.caption)
                .foregroundColor(.secondary)
            Text(text)
                .scaledFont(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200, alignment: .leading)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove folder")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: UIDesign.cornerChip).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: Speaker Chip (compact toggle for timeline filter)

struct SpeakerChip: View {
    let title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .scaledFont(.caption2)
                Text(title)
                    .scaledFont(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundColor(selected ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: UIDesign.cornerChip, style: .continuous)
                    .fill(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIDesign.cornerChip, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: Status Chip (green = present, orange = missing)

struct StatusChip: View {
    let label: String
    let count: Int
    let icon: String
    var missingHint: String = "missing"

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .scaledFont(.caption2)
            Text("\(count)")
                .scaledFont(.caption2)
                .monospacedDigit()
            Text(label)
                .scaledFont(.caption2)
                .lineLimit(1)
        }
        .foregroundColor(count > 0 ? .green : .orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background((count > 0 ? Color.green : Color.orange).opacity(0.1))
        .cornerRadius(UIDesign.cornerChip)
        .help(count > 0 ? "\(count) \(label.lowercased())" : missingHint)
    }
}

// MARK: Banner (error / warning / success strip)

struct Banner: View {
    enum Kind {
        case error, warning, success, info

        var color: Color {
            switch self {
            case .error: return .red
            case .warning: return .orange
            case .success: return .green
            case .info: return .accentColor
            }
        }

        var icon: String {
            switch self {
            case .error: return "exclamationmark.triangle.fill"
            case .warning: return "exclamationmark.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }

    let kind: Kind
    let text: String
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: kind.icon)
                .scaledFont(.caption)
                .foregroundColor(kind.color)
            Text(text)
                .scaledFont(.caption)
                .foregroundColor(kind.color == .accentColor ? .primary : kind.color)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let onDismiss {
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.plain)
                    .scaledFont(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, UIDesign.padH)
        .padding(.vertical, 8)
        .background(kind.color.opacity(0.07))
    }
}

// MARK: Empty State

struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String = ""

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .scaledFontSize(40)
                .foregroundColor(.secondary.opacity(0.4))
            Text(title)
                .scaledFont(.title3)
                .foregroundColor(.secondary)
            if !message.isEmpty {
                Text(message)
                    .scaledFont(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Collapse Header (persisted chevron pattern)

struct CollapseHeader: View {
    let title: String
    var systemImage: String? = nil
    var summary: String = ""
    var detail: String = ""     // extra accent-colored note (e.g. "2 selected")
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .scaledFont(.caption)
                    .foregroundColor(.secondary)
            }
            Text(title)
                .scaledFont(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            if isCollapsed && !summary.isEmpty {
                Text(summary)
                    .scaledFont(.caption2)
                    .monospacedDigit()
                    .foregroundColor(.secondary.opacity(0.7))
            }
            if !isCollapsed && !detail.isEmpty {
                Text(detail)
                    .scaledFont(.caption2)
                    .foregroundColor(.accentColor)
            }
            Spacer()
            Button(action: onToggle) {
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    .scaledFont(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
        }
    }
}

// MARK: Draggable Divider (vertical, between side-by-side panels)

/// A hairline divider the user can drag horizontally.
/// Reports translation deltas; the parent clamps and persists its layout value.
// MARK: Draggable Vertical Divider (between side-by-side panels)

/// Hairline separator the user can drag left/right.
///
/// Reports **absolute translation from drag origin** (not per-frame cumulative deltas)
/// and calls `onStart` once at the moment the drag begins. The parent should capture its
/// current value in `onStart` and drive it as `clamp(snapshot + translation)` — monotonic
/// and immune to accumulation error, so the divider never "sticks" at the clamp or jitters
/// when dragged back after reaching a boundary.
struct DragDivider: View {
    var color: Color = Color(nsColor: .separatorColor)
    let onStart: () -> Void
    let onChanged: (CGFloat) -> Void

    @State private var hovering = false
    @State private var started = false

    var body: some View {
        Rectangle()
            .fill(hovering ? Color.accentColor.opacity(0.6) : color)
            .frame(width: hovering ? 4 : 1)
            .frame(width: 1)
            .contentShape(Rectangle().size(CGSize(width: 14, height: CGFloat.greatestFiniteMagnitude)))
            .onHover { h in
                hovering = h
                if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !started {
                            started = true
                            onStart()
                        }
                        onChanged(value.translation.width)
                    }
                    .onEnded { _ in started = false }
            )
            .animation(hovering ? .easeInOut(duration: 0.1) : .none, value: hovering)
    }
}

// MARK: Draggable Horizontal Divider (between vertically stacked sections)

/// Hairline separator the user can drag up/down. Reports translation deltas;
/// the parent clamps and persists the affected height.
struct HDragDivider: View {
    var color: Color = Color(nsColor: .separatorColor)
    let onChanged: (CGFloat) -> Void

    @State private var hovering = false
    @State private var lastTranslation: CGFloat?

    var body: some View {
        Rectangle()
            .fill(hovering ? Color.accentColor.opacity(0.6) : color)
            .frame(height: hovering ? 4 : 1)
            .contentShape(Rectangle().size(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 14)))
            .onHover { h in
                hovering = h
                if h { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let prev = lastTranslation ?? 0
                        lastTranslation = value.translation.height
                        onChanged(value.translation.height - prev)
                    }
                    .onEnded { _ in lastTranslation = nil }
            )
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

// MARK: Compact Slider Row

struct CompactSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var format: String = "%.1f"
    var labelWidth: CGFloat = 105
    let onValueChange: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .scaledFont(.caption)
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .onChange(of: value) { _, _ in onValueChange() }
            Text(String(format: format, value))
                .scaledFont(.caption, monospacedDigit: true)
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}


extension View {
    /// AI Edit's rounded content-card treatment: text background, 6pt corners,
    /// hairline stroke. The reference look for list/scroll containers.
    func editorCard(paddingH: CGFloat = 10, paddingV: CGFloat = 6) -> some View {
        self
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            .padding(.horizontal, paddingH)
            .padding(.vertical, paddingV)
    }
}

// MARK: - Primary Action Button
// Uniform size/font/presentation for the app's "big" action buttons
// (Create Chapters and Synopsis, Create Beats, Create Timeline in Resolve,
// Regenerate Themes). Fixed width — relevant but NOT full-window.
extension View {
    func primaryActionBar(width: CGFloat = 360) -> some View {
        self
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(width: width)
    }
}


// MARK: - Unified project bar (two columns: source folders left, materials right)

/// One header used at the top of every tab. Two side-by-side columns, each with
/// its content vertically centered and spreading across its own width:
/// **Source Folder(s)** — ＋ ↻ 🗑 actions + folder chips (green/red project-file
/// health dot on each chip) + trailing status caption; **Materials** — compact
/// total counts with a subfolder expander that grows the column into the
/// material tree. Each tab supplies its own storage + reload path.
struct ProjectBar<Status: View>: View {
    let folders: [String]
    var emptyPrompt: String = "Choose work folder…"
    let onAdd: () -> Void
    let onRemove: (String) -> Void
    var onRescan: (() -> Void)? = nil
    let onClear: () -> Void
    let trees: [MaterialNode]
    @Binding var materialsExpanded: Bool
    @ViewBuilder var status: () -> Status

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Left section — source folders (labels / actions+status / folder list)
            VStack(alignment: .leading, spacing: 3) {
                Text("Source Folder(s)")
                    .scaledFont(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .opacity(folders.isEmpty ? 0.5 : 1)

                HStack(spacing: 10) {
                    HStack(spacing: 9) {
                        Button(action: onAdd) {
                            Image(systemName: "folder.badge.plus")
                                .scaledFont(.title3)
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help(folders.isEmpty ? emptyPrompt : "Add folder")

                        if let onRescan {
                            Button(action: onRescan) {
                                Image(systemName: "arrow.clockwise")
                                    .scaledFont(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Re-read work folders from disk")
                        }

                        Button(action: onClear) {
                            Image(systemName: "trash")
                                .scaledFont(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear all folders")
                    }

                    Spacer(minLength: 8)

                    status()
                }

                if folders.isEmpty {
                    Text(emptyPrompt)
                        .scaledFont(.subheadline)
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                        .frame(maxWidth: 460, alignment: .leading)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(folders, id: \.self) { f in
                                FolderChip(text: (f as NSString).lastPathComponent,
                                           healthy: healthByPath[f],
                                           onDelete: { onRemove(f) })
                            }
                        }
                    }
                    .frame(height: 22)
                    .frame(maxWidth: 460, alignment: .leading)
                }
            }
            .frame(minWidth: 240, maxWidth: 520, alignment: .topLeading)

            // Vertical divider between the two sections — FIXED height so it
            // can never stretch the bar when the tab proposes ample space
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1, height: 40)

            // Right section — materials (labels / summary+expander / toggleable tree)
            if !folders.isEmpty && !trees.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Materials")
                        .scaledFont(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .opacity(folders.isEmpty ? 0.5 : 1)

                    HStack(spacing: 6) {
                        Text(MaterialTree.summary(trees))
                            .scaledFont(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(MaterialTree.summary(trees))
                        Spacer(minLength: 4)
                        if MaterialTree.subfolderCount(trees) > 0 {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.15)) { materialsExpanded.toggle() }
                            }) {
                                HStack(spacing: 3) {
                                    Text(materialsExpanded ? "hide" : "subfolders")
                                        .scaledFont(.caption2)
                                    Image(systemName: materialsExpanded ? "chevron.up" : "chevron.down")
                                        .scaledFont(.caption2)
                                }
                                .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(materialsExpanded ? "Collapse subfolder tree" : "Show subfolder tree")
                        }
                    }

                    if materialsExpanded {
                        ProjectBarMaterials(trees: trees)
                            .frame(maxHeight: 150, alignment: .top)
                    }
                }
                .frame(minWidth: 260, maxWidth: 430, alignment: .topLeading)
            }
        }
        .padding(.horizontal, UIDesign.padH)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    /// path → hasProjectFile, for the health dots drawn on folder chips.
    private var healthByPath: [String: Bool] {
        Dictionary(uniqueKeysWithValues: trees.map { ($0.path, $0.hasProjectFile) })
    }
}
