import SwiftUI

/// Native grouped forms for built-ins; explicit application surfaces for the custom palette.
struct ThemedForm<Content: View>: View {
    @Environment(\.themeColors) private var colors
    @ViewBuilder var content: Content

    var body: some View {
        if colors.isCustom {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(sections: content) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            if !section.header.isEmpty {
                                section.header.font(.headline).accessibilityAddTraits(.isHeader)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(subviews: section.content) { row in
                                    if row.id != section.content.first?.id {
                                        Rectangle().fill(colors.border).frame(height: 0.5)
                                    }
                                    row.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                                }
                            }.padding(.horizontal, 12).background(colors.surface, in: .rect(cornerRadius: 12))
                            if !section.footer.isEmpty {
                                section.footer.font(.caption).foregroundStyle(colors.secondaryText)
                            }
                        }
                    }
                }.padding(20)
            }.background(colors.canvas).toggleStyle(.switch).labeledContentStyle(TrailingThemeValue())
        } else {
            Form { content }.formStyle(.grouped).scrollContentBackground(.hidden).background(colors.canvas)
        }
    }
}

private struct TrailingThemeValue: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content
        }
    }
}
