import AppKit
import SwiftUI

/// Text colors keep contrast on both document surfaces and inactive table selections.
/// System primary text remains in charge of active selection and disabled controls.
enum AppColors {
    static let secondaryText = adaptive(light: 0x53565C, dark: 0xC2C4C8)
    static let positive = adaptive(light: 0x17632D, dark: 0x9CE0AB)
    static let negative = adaptive(light: 0x992929, dark: 0xFFAAAA)
    static let modified = adaptive(light: 0x754000, dark: 0xF4C88C)
    static let link = adaptive(light: 0x174A93, dark: 0xA9CBFF)
    static let keyword = adaptive(light: 0x672C85, dark: 0xE3B3FF)
    static let string = adaptive(light: 0x70461B, dark: 0xE3C490)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat((value >> 16) & 255) / 255,
                    green: CGFloat((value >> 8) & 255) / 255,
                    blue: CGFloat(value & 255) / 255, alpha: 1)
            })
    }
}
