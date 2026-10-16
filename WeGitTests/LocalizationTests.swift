import Foundation
import Testing

@testable import WeGitCore

@Suite("Localization")
struct LocalizationTests {
    @Test func menuContextDoesNotChangeFileListWording() {
        #expect(L10n.menuTitle("File", language: .english) == "File")
        #expect(L10n.menuTitle("File", language: .simplifiedChinese) == "文件")
        #expect(L10n.menuTitle("Copy", language: .english) == "Copy")
        #expect(L10n.menuTitle("Copy", language: .simplifiedChinese) == "拷贝")
        #expect(L10n.text("文件", language: .english) == "Files")
    }

    @Test func translatesInterfaceAndRecoveryMessages() {
        #expect(L10n.text("更改", language: .english) == "Changes")
        #expect(L10n.text("提交并推送…", language: .english) == "Commit and Push…")
        #expect(L10n.text("跟随系统", language: .english) == "Follow system")
        #expect(L10n.text("设置分类", language: .english) == "Settings categories")
        #expect(L10n.text("提交历史", language: .simplifiedChinese) == "提交历史")
        #expect(
            L10n.text("操作已取消。写入结果可能已生效，请刷新仓库核对。", language: .english)
                == "Operation cancelled. Writes may already have taken effect. Refresh the repository to verify."
        )
    }

    @Test func argumentsArePreservedVerbatimAndCannotBecomeFormatStrings() {
        let value = "提交/\t中文🙂 %1$@ 100%\nmain"
        #expect(L10n.text("当前提交：\(value)", language: .english) == "Current commit: " + value)
        #expect(L10n.text("当前提交：\(value)", language: .simplifiedChinese) == "当前提交：" + value)
        #expect(
            L10n.text("当前阶段 \(50)%", language: .english) == "Current stage 50%")
    }

    @Test func countsUseEnglishPluralRulesAndChineseSourceWording() {
        #expect(L10n.count("提交（%lld 个文件）", 0, language: .english) == "Commit (0 files)")
        #expect(L10n.count("提交（%lld 个文件）", 1, language: .english) == "Commit (1 file)")
        #expect(L10n.count("提交（%lld 个文件）", 2, language: .english) == "Commit (2 files)")
        #expect(L10n.count("%lld 个提交", 1, language: .english) == "1 commit")
        #expect(L10n.count("%lld 个提交", 2, language: .english) == "2 commits")
        #expect(L10n.count("展开 %lld 行", 1, language: .english) == "Expand 1 line")
        #expect(L10n.count("展开 %lld 行", 20, language: .english) == "Expand 20 lines")
        #expect(L10n.count("%lld 行未显示", 1, language: .english) == "1 line hidden")
        #expect(L10n.count("提交（%lld 个文件）", 1, language: .simplifiedChinese) == "提交（1 个文件）")
    }

    @Test func missingKeysFallBackWithoutLosingInterpolatedData() {
        let value = "中文🙂%1$@"
        #expect(L10n.text("未收录提示 \(value)", language: .english) == "未收录提示 " + value)
    }

    @Test func resolvesSupportedLanguagesWithoutChangingStableIDs() {
        #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "zh-Hans"]) == .simplifiedChinese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["en-GB", "zh-Hans"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: []) == .english)
        #expect(AppLanguage.english.resolved(preferredLanguages: ["zh-Hans"]) == .english)
        #expect(L10n.key("提交历史", language: .english) == "History")
        #expect(AppLanguage.simplifiedChinese.rawValue == "zh-Hans")
        #expect(L10n.text("\("Staged")（\(1)）", language: .english) == "Staged (1)")
    }

    @Test func explicitLanguagesAreIndependentAcrossConcurrentReaders() async {
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let language: AppLanguage = index.isMultiple(of: 2) ? .english : .simplifiedChinese
                    let result = L10n.text("提交并推送…", language: language)
                    #expect(result == (language == .english ? "Commit and Push…" : "提交并推送…"))
                }
            }
        }
    }
}
