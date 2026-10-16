import SwiftUI
import AppKit

struct CatalogApp: Codable {
    let title: String
    let icon: String?
    let aliases: [String]?
    /// Samsung app IDs, newest first. The first one is launched when the TV cannot list its apps.
    let ids: [String]?
    /// 4 for native Tizen apps; store apps (2) open through a deep link.
    let type: Int?
    /// Name under the TV's DIAL service (port 8080), the most reliable way to open these apps.
    let dial: String?
}

/// Bundled tiles for well-known apps, matched by the name the TV reports. Tizen 5 and later
/// no longer list installed apps, so the IDs here also stand in for that list.
enum AppCatalog {
    static let entries: [CatalogApp] = {
        guard let url = AppResources.bundle.url(forResource: "app-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CatalogApp].self, from: data)) ?? []
    }()
    static func normalized(_ title: String) -> String {
        title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func match(title: String, id: String = "") -> CatalogApp? {
        let name = normalized(title)
        return entries.first { entry in
            entry.ids?.contains(id) == true || (entry.aliases ?? [entry.title]).contains { normalized($0) == name }
        }
    }
}

/// Bundled tiles first, then icons the TV sent, cached under Application Support.
enum AppIcons {
    static let cacheDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("br.local.TizenRemote").appendingPathComponent("icons")
    static func cacheFile(for appID: String) -> URL {
        let safe = String(appID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" ? Character($0) : "_" })
        return cacheDirectory.appendingPathComponent(safe + ".img")
    }
    static func url(for app: TVApp) -> URL? {
        if let icon = app.icon, let bundled = AppResources.bundle.url(forResource: icon, withExtension: nil, subdirectory: "AppAssets") { return bundled }
        let cached = cacheFile(for: app.id)
        return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
    }
}

struct BrandTheme {
    static let samsungBlue = Color(red: 0.25, green: 0.43, blue: 1)
    let color: Color
    let label: String
    let tagline: String
    @MainActor private static var logoColors: [String: Color] = [:]
    /// The dominant saturated hue of a logo, so unknown apps still get a matching accent.
    @MainActor static func logoColor(_ url: URL) -> Color {
        if let known = logoColors[url.path] { return known }
        var result = Color(white: 0.78)
        if let data = try? Data(contentsOf: url), let image = NSImage(data: data), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
            var buckets: [Int: (count: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [:]
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 24)) {
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 24)) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.6,
                          color.saturationComponent > 0.25, color.brightnessComponent > 0.25 else { continue }
                    let bucket = Int(color.hueComponent * 20)
                    let previous = buckets[bucket] ?? (0, 0, 0, 0)
                    buckets[bucket] = (previous.count + 1, previous.r + color.redComponent, previous.g + color.greenComponent, previous.b + color.blueComponent)
                }
            }
            if let best = buckets.values.max(by: { $0.count < $1.count }) {
                let n = CGFloat(best.count)
                result = Color(red: Double(best.r / n), green: Double(best.g / n), blue: Double(best.b / n))
            }
        }
        logoColors[url.path] = result
        return result
    }
    @MainActor static func forApp(_ id: String, title: String = "", icon: URL? = nil) -> BrandTheme {
        let key = (id + " " + title).lowercased()
        if key.contains("ps5") || key.contains("playstation") { return .init(color: Color(red: 0.12, green: 0.43, blue: 1), label: "PlayStation 5", tagline: "Your next adventure starts here.") }
        if key.contains("netflix") { return .init(color: Color(red: 0.94, green: 0.08, blue: 0.13), label: "Netflix", tagline: "A great story is waiting for you.") }
        if key.contains("youtube") { return .init(color: Color(red: 1, green: 0.18, blue: 0.23), label: "YouTube", tagline: "Everything you love, on the big screen.") }
        if key.contains("amazon") || key.contains("prime") { return .init(color: Color(red: 0.08, green: 0.64, blue: 1), label: "Prime Video", tagline: "Time for popcorn.") }
        if key.contains("disney") { return .init(color: Color(red: 0.20, green: 0.38, blue: 1), label: "Disney+", tagline: "A universe of stories.") }
        if key.contains("spotify") { return .init(color: Color(red: 0.12, green: 0.84, blue: 0.43), label: "Spotify", tagline: "Set the mood. Press play.") }
        if key.contains("twitch") { return .init(color: Color(red: 0.61, green: 0.35, blue: 1), label: "Twitch", tagline: "Your community, live.") }
        if key.contains("hbo") || key.contains(" max") { return .init(color: Color(red: 0.60, green: 0.34, blue: 1), label: title.isEmpty ? "Max" : title, tagline: "Great stories. Unforgettable moments.") }
        if key.contains("globo") { return .init(color: Color(red: 1, green: 0.33, blue: 0.23), label: title, tagline: "Your entertainment, your way.") }
        if key.contains("apple") { return .init(color: Color(white: 0.9), label: title, tagline: "Cinema in your living room.") }
        if key.contains("chromecast") { return .init(color: Color(red: 0.28, green: 0.66, blue: 0.93), label: "Chromecast", tagline: "From your device to your TV.") }
        return .init(color: icon.map(logoColor) ?? samsungBlue, label: title, tagline: "Your Samsung. Your room. Your remote.")
    }
}
