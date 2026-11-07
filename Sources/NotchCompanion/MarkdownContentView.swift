import AppKit
import SwiftUI

/// Natural-size conversation content. Horizontal code scrolling is contained
/// within the transcript's proposed width; this view never sizes the notch.
struct MarkdownContentView: View {
    var text: String
    var interpretsMarkdown = true

    var body: some View {
        Group {
            if interpretsMarkdown {
                MarkdownBlocksView(blocks: MarkdownDocument.parse(text))
            } else {
                Text(verbatim: text)
                    .font(.system(size: 13)).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .tint(PanelTheme.pick(CompanionStyle.accent, CompanionStyle.accent, CompanionStyle.text))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlocksView: View {
    var blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.pick(10, 11, 11)) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                MarkdownBlockView(block: block)
                    .padding(.top, isHeading(block) && index > 0 ? 6 : 0)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isHeading(_ block: MarkdownBlock) -> Bool {
        if case .heading = block.content { return true }
        return false
    }
}

extension EnvironmentValues {
    /// Prose size: 13 for answers, a step smaller for commentary between tool calls.
    @Entry var markdownBodySize: CGFloat = 13
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    @Environment(\.markdownBodySize) private var bodySize

    var body: some View {
        switch block.content {
        case .paragraph(let text):
            inline(text).font(.system(size: bodySize)).lineSpacing(bodySize < 13 ? 3 : 4)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            inline(text).font(.system(size: headingSize(level), weight: PanelTheme.pick(.semibold, .bold, .semibold))).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .code(let language, let text):
            MarkdownCodeBlock(language: language, text: text)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: PanelTheme.pick(6, 7, 7)) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: PanelTheme.pick(8, 7, 7)) {
                        Group {
                            if ordered {
                                if PanelTheme.current == .instrument {
                                    Text(String(format: "%02d", item.number ?? 1))
                                        .font(CompanionStyle.mono(11).monospacedDigit())
                                        .padding(.top, 1.5)
                                } else {
                                    Text("\(item.number ?? 1).")
                                        .font(.system(size: bodySize).monospacedDigit())
                                }
                            } else {
                                switch PanelTheme.current {
                                case .refined:
                                    Image(systemName: "circle.fill").font(.system(size: 4))
                                        .frame(height: 16)
                                        .accessibilityHidden(true)
                                case .tahoe:
                                    Image(systemName: "circle.fill").font(.system(size: 4.5))
                                        .frame(height: 17)
                                        .accessibilityHidden(true)
                                case .instrument:
                                    Rectangle().frame(width: 4, height: 4)
                                        .frame(height: 17)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .foregroundStyle(PanelTheme.pick(CompanionStyle.tertiary, CompanionStyle.secondary, CompanionStyle.faint))
                        .frame(minWidth: ordered ? PanelTheme.pick(18, 19, 19) : 8, alignment: PanelTheme.pick(.trailing, .trailing, .leading))
                        MarkdownBlocksView(blocks: item.blocks)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: PanelTheme.pick(12, 11, 11)) {
                switch PanelTheme.current {
                case .refined: Rectangle().fill(CompanionStyle.tertiary.opacity(0.6)).frame(width: 2)
                case .tahoe: Capsule().fill(CompanionStyle.faint).frame(width: 3)
                case .instrument: Rectangle().fill(CompanionStyle.ruleStrong).frame(width: 2)
                }
                MarkdownBlocksView(blocks: blocks).foregroundStyle(CompanionStyle.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle().fill(PanelTheme.pick(CompanionStyle.hairline, CompanionStyle.separator, CompanionStyle.rule))
                .frame(height: PanelTheme.pick(1, 0.5, 0.5))
                .padding(.vertical, PanelTheme.pick(4, 5, 5)).accessibilityHidden(true)
        }
    }

    private func inline(_ source: String) -> Text {
        var formatted = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        if PanelTheme.current == .instrument {
            // Links stay white like the prose and carry an underline instead of a color.
            for run in formatted.runs where run.link != nil {
                formatted[run.range].underlineStyle = .single
            }
        }
        return Text(formatted)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return PanelTheme.pick(17, 20, 19)
        case 2: return PanelTheme.pick(15, 17, 16)
        default: return PanelTheme.pick(13, 14.5, 14)
        }
    }
}

private struct MarkdownCodeBlock: View {
    let language: String?
    let text: String
    @State private var copied = false

    var body: some View {
        let theme = PanelTheme.current
        let lines = text.isEmpty ? 1 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        let shape = RoundedRectangle(cornerRadius: PanelTheme.pick(CompanionStyle.Radius.row, 12, CompanionStyle.cardRadius), style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            switch theme {
            case .refined:
                HStack(spacing: 8) {
                    Text(language ?? "Code").font(.system(size: 11, weight: .medium)).foregroundStyle(CompanionStyle.tertiary).lineLimit(1)
                    Spacer(minLength: 8)
                    copyButton.buttonStyle(NotchToolbarButtonStyle(height: 24))
                }
                .padding(.leading, 12).padding(.trailing, 4).padding(.top, 4)
                Rectangle().fill(CompanionStyle.hairline).frame(height: 0.5)
            case .tahoe:
                HStack(spacing: 8) {
                    Text(language ?? "Code").font(.system(size: 11.5, weight: .medium, design: .monospaced)).lineLimit(1)
                    Spacer(minLength: 8)
                    copyButton.buttonStyle(NotchTextButtonStyle()).padding(.vertical, 6)
                }
                .foregroundStyle(CompanionStyle.secondary)
                .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 2)
                .background(alignment: .bottom) { Rectangle().fill(CompanionStyle.separator).frame(height: 0.5) }
            case .instrument:
                HStack(spacing: 8) {
                    Text(language ?? "Code").microLabel(10, weight: .semibold).foregroundStyle(CompanionStyle.text).lineLimit(1)
                    Text("\(lines) \(lines == 1 ? "line" : "lines")").microLabel(9.5, weight: .regular, tracking: 0.6).foregroundStyle(CompanionStyle.faint)
                    Spacer(minLength: 8)
                    copyButton.buttonStyle(NotchPillButtonStyle(small: true)).padding(.vertical, 2)
                }
                .foregroundStyle(CompanionStyle.secondary)
                .padding(.leading, 11).padding(.trailing, 5).padding(.vertical, 4)
                Rectangle().fill(CompanionStyle.rule).frame(height: 0.5)
            }
            if theme == .instrument {
                HStack(alignment: .top, spacing: 0) {
                    // Line numbers share the code's font and spacing, so they stay level with it.
                    Text((1...lines).map { String(format: "%02d", $0) }.joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced)).lineSpacing(4)
                        .foregroundStyle(CompanionStyle.faint.opacity(0.8))
                        .fixedSize()
                        .padding(.leading, 11).padding(.trailing, 4).padding(.vertical, 10)
                        .accessibilityHidden(true)
                    code
                }
            } else {
                code
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelTheme.pick(CompanionStyle.well, Color.white.opacity(0.055), CompanionStyle.inset), in: shape)
        .overlay(shape.strokeBorder(PanelTheme.pick(Color.white.opacity(0.06), Color.white.opacity(0.07), CompanionStyle.rule), lineWidth: 0.5))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            let label = Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            if PanelTheme.current == .tahoe { label.font(.system(size: 11.5, weight: .medium)) } else { label }
        }
        .help("Copy code")
        .accessibilityLabel(copied ? "Code copied" : "Copy code")
    }

    private var code: some View {
        ScrollView(.horizontal) {
            Text(verbatim: text.isEmpty ? " " : text)
                .font(.system(size: 12, design: .monospaced)).lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, PanelTheme.pick(12, 12, 8))
                .padding(.top, PanelTheme.pick(10, 9, 10)).padding(.bottom, PanelTheme.pick(12, 11, 10))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(language.map { "\($0) code" } ?? "Code")
    }
}
