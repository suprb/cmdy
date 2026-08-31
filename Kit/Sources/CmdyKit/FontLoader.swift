import AppKit
import CoreText
import ProductIdentity

/// Registers the redistributable fonts bundled in Resources/Fonts at launch so
/// NSFont(name:) resolves them without a system install, and reports their
/// names for the Font menu.
public enum FontLoader {
    public struct BundledFont {
        public let displayName: String
        public let fontName: String
    }

    public static func registerBundledFonts() -> [BundledFont] {
        guard let bundle = ProductResourceBundle.bundle(
            named: "Kit_CmdyKit") else { return [] }
        var result: [BundledFont] = []
        let urls = (bundle.urls(
            forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
            + (bundle.urls(
                forResourcesWithExtension: "otf", subdirectory: "Fonts") ?? [])
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let d = descs.first else { continue }
            let ps = (CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String) ?? ""
            let family = (CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String) ?? ps
            if !ps.isEmpty { result.append(BundledFont(displayName: family, fontName: ps)) }
        }
        return result.sorted { $0.displayName < $1.displayName }
    }
}
