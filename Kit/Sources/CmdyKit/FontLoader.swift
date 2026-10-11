import AppKit
import CoreText
import ProductIdentity

/// Lists bundled fonts without opening font files. Selected faces are registered
/// before name resolution; the renderer requests the remaining faces before
/// CoreText needs a fallback. Registrations last for the process lifetime.
public enum FontLoader {
    public struct BundledFont {
        public let displayName: String
        public let fontName: String
    }

    struct Entry: Decodable {
        let displayName: String
        let fontName: String
        let resource: String
    }

    final class Registry {
        let entries: [Entry]
        private let urls: [URL]
        private let register: (URL) -> Bool
        private let lock = NSLock()
        private var registered = Set<URL>()

        init(entries: [Entry], urls: [URL], register: @escaping (URL) -> Bool) {
            self.entries = entries
            self.urls = urls
            self.register = register
        }

        var fonts: [BundledFont] {
            entries.map { BundledFont(displayName: $0.displayName, fontName: $0.fontName) }
                .sorted { $0.displayName < $1.displayName }
        }

        func entry(named name: String) -> Entry? {
            entries.first {
                $0.fontName.caseInsensitiveCompare(name) == .orderedSame
                    || $0.displayName.caseInsensitiveCompare(name) == .orderedSame
            }
        }

        func registerSelected(_ entry: Entry) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let url = urls.first(where: { $0.lastPathComponent == entry.resource }) else { return false }
            return registerLocked(url)
        }

        func registerAll() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            var success = true
            // Keep the bundle's enumeration order, as in the original loader.
            for url in urls where !registerLocked(url) { success = false }
            return success
        }

        private func registerLocked(_ url: URL) -> Bool {
            if registered.contains(url) { return true }
            guard register(url) else { return false }
            registered.insert(url)
            return true
        }
    }

    static func entries(in bundle: Bundle, urls: [URL]) -> [Entry] {
        if let catalog = bundle.url(forResource: "catalog", withExtension: "json", subdirectory: "Fonts"),
           let data = try? Data(contentsOf: catalog),
           let entries = try? JSONDecoder().decode([Entry].self, from: data),
           entries.count == urls.count,
           Set(entries.map(\.resource)) == Set(urls.map(\.lastPathComponent)),
           Set(entries.map(\.fontName)).count == entries.count,
           entries.allSatisfy({ !$0.fontName.isEmpty && !$0.displayName.isEmpty }) {
            return entries
        }
        // A missing or stale catalog must not remove fonts from older/custom
        // packages. Descriptor discovery is only needed on this recovery path.
        return urls.compactMap { url in
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let descriptor = descriptors.first,
                  let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  !name.isEmpty else { return nil }
            let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String ?? name
            return Entry(displayName: family, fontName: name, resource: url.lastPathComponent)
        }
    }

    private static let registry: Registry = {
        guard let bundle = ProductResourceBundle.bundle(named: "Kit_CmdyKit") else {
            return Registry(entries: [], urls: [], register: { _ in false })
        }
        let urls = (bundle.urls(
            forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
            + (bundle.urls(
                forResourcesWithExtension: "otf", subdirectory: "Fonts") ?? [])
        return Registry(entries: entries(in: bundle, urls: urls), urls: urls) { url in
            var error: Unmanaged<CFError>?
            let success = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            let failure = error?.takeRetainedValue()
            if success { return true }
            return failure.map {
                CFErrorGetDomain($0) == kCTFontManagerErrorDomain
                    && CFErrorGetCode($0) == CTFontManagerError.alreadyRegistered.rawValue
            } ?? false
        }
    }()

    public static var bundledFonts: [BundledFont] { registry.fonts }

    /// Unlike menu enumeration, resolving a selected face may open its font file.
    public static func font(named name: String, size: CGFloat) -> NSFont? {
        if name.caseInsensitiveCompare("System") == .orderedSame { return nil }
        if let entry = registry.entry(named: name) {
            _ = registry.registerSelected(entry)
            return NSFont(name: name, size: size)
        }
        if let font = NSFont(name: name, size: size) { return font }
        // Preserve CoreText's less common aliases and invalid-name behavior.
        _ = ensureFallbackFontsRegistered()
        return NSFont(name: name, size: size)
    }

    /// Safe from render workers as well as the main thread. Failures remain
    /// retryable; successful registrations are never repeated or unregistered.
    @discardableResult
    public static func ensureFallbackFontsRegistered() -> Bool {
        autoreleasepool { registry.registerAll() }
    }

    public static func registerBundledFonts() -> [BundledFont] {
        ensureFallbackFontsRegistered()
        return bundledFonts
    }
}
