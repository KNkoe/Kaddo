import AppKit

/// Brightens saved designs at display time without replacing an agent's identity.
struct AgentPalette {
    let primary: NSColor
    let shadow: NSColor
    let accent: NSColor

    init(appearance: AgentAppearance) {
        let base = Self.components(appearance.primary, fallbackHue: Double(appearance.seed % 3600) / 3600)
        let detail = Self.components(appearance.accent, fallbackHue: (base.hue + 0.38).truncatingRemainder(dividingBy: 1))
        primary = Self.color(base.hue, max(base.saturation, 0.68), max(base.brightness, 0.96))
        shadow = Self.color(base.hue, max(base.saturation, 0.74), 0.80)
        accent = Self.color(detail.hue, max(detail.saturation, 0.75), max(detail.brightness, 0.98))
    }

    private static func color(_ hue: Double, _ saturation: Double, _ brightness: Double) -> NSColor {
        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1).usingColorSpace(.sRGB)!
    }

    private static func components(_ hex: String, fallbackHue: Double) -> (hue: Double, saturation: Double, brightness: Double) {
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0x33CCA8
        let color = NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1).usingColorSpace(.deviceRGB)!
        return (color.saturationComponent < 0.08 ? fallbackHue : color.hueComponent, color.saturationComponent, color.brightnessComponent)
    }

    static func hex(hue: Double, saturation: Double, brightness: Double) -> String {
        let rgb = color(hue, saturation, brightness)
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}
