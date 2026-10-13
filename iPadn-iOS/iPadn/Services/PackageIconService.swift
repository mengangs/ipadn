import Foundation
import UIKit
import ImageIO
import ZIPFoundation

enum PackageIconService {
    static func cacheURL(_ id: UUID) -> URL {
        LocalResources.support.appendingPathComponent("PackageIcons", isDirectory: true)
            .appendingPathComponent(id.uuidString + ".png")
    }

    /// `minimumPixels` rejects icons too small to look sharp (older packages
    /// often ship only a 120 px PNG) when better store artwork exists.
    static func save(from ipa: URL, id: UUID, minimumPixels: Int = 0) throws -> Bool {
        guard let data = try png(from: ipa, minimumPixels: minimumPixels) else { return false }
        let url = cacheURL(id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return true
    }

    // tvOS frequently ships its icons only inside Apple TV asset catalogs.
    // iOS cannot reliably decode those renditions, so cache the public Apple
    // Store artwork as a stable local fallback instead of showing a placeholder.
    static func pixelWidth(_ file: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
        return props[kCGImagePropertyPixelWidth] as? Int ?? 0
    }

    static func normalizedArtwork(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= 6_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image).pngData()
    }

    static func saveCatalogArtwork(from url: URL, id: UUID) async throws -> Bool {
        guard url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { return false }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.mimeType?.lowercased().hasPrefix("image/") == true,
              let png = normalizedArtwork(data) else { return false }
        try Task.checkCancellation()
        let destination = cacheURL(id)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: destination, options: .atomic)
        return true
    }

    static func png(from ipa: URL, minimumPixels: Int = 0) throws -> Data? {
        let archive = try Archive(url: ipa, accessMode: .read)
        guard let info = archive.first(where: {
            let parts = $0.path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }), let infoData = try read(info, archive: archive, limit: 2_000_000),
              let plist = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else { return nil }
        let prefix = String(info.path.dropLast("Info.plist".count))
        let phone = (plist["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
        let pad = (plist["CFBundleIcons~ipad"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
        let declared = (phone["CFBundleIconFiles"] as? [String] ?? []) +
            (pad["CFBundleIconFiles"] as? [String] ?? []) + (plist["CFBundleIconFiles"] as? [String] ?? []) +
            [plistString(plist["CFBundleIconFile"])]
        let names = declared.filter { !$0.isEmpty }.map { ($0 as NSString).deletingPathExtension.lowercased() }
        let mainPNGs = archive.filter { entry in
            guard entry.type == .file, entry.path.hasPrefix(prefix) else { return false }
            let relative = String(entry.path.dropFirst(prefix.count))
            return !relative.contains("/") && relative.lowercased().hasSuffix(".png")
        }
        let primary = mainPNGs.filter { entry in
            let name = (entry.path as NSString).lastPathComponent.lowercased()
            return names.contains { name == $0 + ".png" || name.hasPrefix($0 + "@") || name.hasPrefix($0 + "~") }
        }
        let conventional = mainPNGs.filter {
            let name = ($0.path as NSString).lastPathComponent.lowercased()
            return name.hasPrefix("appicon") || name.hasPrefix("icon.") || name.hasPrefix("icon@");
        }
        // A declared primary icon wins over alternate icons, extensions and store artwork.
        var smallFallback: Data?
        for candidates in [primary, conventional] {
            var best: (pixels: Int, image: CGImage)?
            for entry in candidates {
                guard let data = try read(entry, archive: archive, limit: 8_000_000),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = props[kCGImagePropertyPixelWidth] as? Int,
                      let height = props[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 4096, height <= 4096,
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 512
                      ] as CFDictionary) else { continue }
                if width * height > (best?.pixels ?? 0) { best = (width * height, image) }
            }
            if let best {
                let data = UIImage(cgImage: best.image).pngData()
                if best.image.width >= minimumPixels { return data }
                smallFallback = smallFallback ?? data
            }
        }
        // Some packages contain only a compiled asset catalog. Read it as resources;
        // no executable from the IPA is extracted or loaded.
        let assetName = plistString(phone["CFBundleIconName"] ?? pad["CFBundleIconName"])
        if !assetName.isEmpty, let car = archive[prefix + "Assets.car"],
           let data = try read(car, archive: archive, limit: 64_000_000) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            try data.write(to: folder.appendingPathComponent("Assets.car"))
            let resourceInfo = ["CFBundleIdentifier": "app.local.iPadn.icon." + UUID().uuidString, "CFBundlePackageType": "BNDL"]
            try PropertyListSerialization.data(fromPropertyList: resourceInfo, format: .binary, options: 0)
                .write(to: folder.appendingPathComponent("Info.plist"))
            if let bundle = Bundle(url: folder), let image = UIImage(named: assetName, in: bundle, compatibleWith: nil),
               Int(image.size.width * image.scale) >= minimumPixels {
                return image.pngData()
            }
        }
        return minimumPixels > 0 ? nil : smallFallback
    }

    private static func read(_ entry: Entry, archive: Archive, limit: Int) throws -> Data? {
        guard entry.type == .file, entry.uncompressedSize <= UInt64(limit) else { return nil }
        var data = Data()
        let checksum = try archive.extract(entry) { chunk in
            guard data.count + chunk.count <= limit else { throw ToolError.message("图标资源过大") }
            data.append(chunk)
        }
        guard checksum == entry.checksum else { throw ToolError.message("安装包已损坏") }
        return data
    }
}
