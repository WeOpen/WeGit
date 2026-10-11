import SwiftUI

struct EmptyPanel: View {
    let title: String
    let symbol: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(
                AppColors.secondaryText
            )
            .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(AppColors.secondaryText).multilineTextAlignment(
                .center
            ).frame(
                maxWidth: 360)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBadge: View {
    let symbol: String
    private var tint: Color {
        symbol == "U" || symbol == "D"
            ? AppColors.negative
            : symbol == "A" || symbol == "?" ? AppColors.positive : AppColors.modified
    }
    var body: some View {
        Text(symbol).font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(width: 22, height: 21).background(tint.opacity(0.14), in: .rect(cornerRadius: 4))
            .accessibilityLabel(
                "状态："
                    + ([
                        "U": "冲突", "A": "新增", "M": "修改", "D": "删除", "R": "重命名", "C": "复制", "T": "类型变化",
                        "?": "未跟踪",
                    ][symbol] ?? symbol))
    }
}

struct DetailHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline).lineLimit(1).truncationMode(.middle).help(title)
            Text(subtitle).font(.caption).foregroundStyle(AppColors.secondaryText)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
