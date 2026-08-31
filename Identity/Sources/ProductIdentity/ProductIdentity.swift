import Foundation

/// The one source of truth for the product's public identity.
///
/// `name` is the renameable value. Package names, app/executable names,
/// configuration paths, environment prefixes, MCP namespaces, release assets,
/// and the default GitHub repository are derived from it.
///
/// Stable identifiers live beside it deliberately. A marketing rename should
/// not silently invalidate macOS preferences, updates, signatures, or existing
/// Extension receipts.
public struct ProductIdentity: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let name: String
    public let repositoryOwner: String
    public let bundleIdentifier: String
    public let extensionIdentifierNamespace: String
    public let codeSigningIdentifierNamespace: String
    public let legacyNames: [String]

    public init(
        schemaVersion: Int = 1,
        name: String,
        repositoryOwner: String,
        bundleIdentifier: String,
        extensionIdentifierNamespace: String,
        codeSigningIdentifierNamespace: String,
        legacyNames: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.repositoryOwner = repositoryOwner
        self.bundleIdentifier = bundleIdentifier
        self.extensionIdentifierNamespace = extensionIdentifierNamespace
        self.codeSigningIdentifierNamespace = codeSigningIdentifierNamespace
        self.legacyNames = legacyNames
    }

    public static let current: ProductIdentity = {
        guard let bundle = ProductResourceBundle.bundle(
                named: "ProductIdentity_ProductIdentity"),
              let url = bundle.url(
            forResource: "product-identity", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let identity = try? JSONDecoder().decode(ProductIdentity.self, from: data),
              identity.isValid else {
            fatalError("Product identity is missing or invalid")
        }
        return identity
    }()

    public var slug: String { Self.slug(for: name) }
    public var displayName: String { name }
    /// The public name with the exact casing chosen in the identity manifest.
    /// Kept as a compatibility accessor for call sites that want prose rather
    /// than a slug; it must not silently title-case intentionally lowercase
    /// brands such as `cmdy`.
    public var titleName: String { name }
    public var executableName: String { slug }
    public var appBundleName: String { "\(slug).app" }
    public var iconBaseName: String { slug }
    public var configurationDirectoryName: String { slug }
    public var projectDirectoryName: String { ".\(slug)" }
    public var environmentPrefix: String { Self.environmentPrefix(for: slug) }
    public var mcpNamespace: String { slug }
    public var releaseAssetPrefix: String { slug }
    public var repositoryName: String { slug }
    public var githubRepository: String { "\(repositoryOwner)/\(repositoryName)" }
    public var marketplaceRepositoryName: String { "\(slug)-registry" }
    public var compatibleMarketplaceRepositoryNames: [String] {
        [marketplaceRepositoryName] + legacySlugs.map { "\($0)-registry" }
    }
    public var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(githubRepository)/releases/latest")!
    }

    public var marketplaceRegistryURL: URL {
        marketplaceRegistryURL(repositoryName: marketplaceRepositoryName)
    }

    public var compatibleMarketplaceRegistryURLs: [URL] {
        compatibleMarketplaceRepositoryNames.map {
            marketplaceRegistryURL(repositoryName: $0)
        }
    }

    public var legacySlugs: [String] {
        legacyNames.map(Self.slug(for:)).filter { !$0.isEmpty && $0 != slug }
    }

    public var legacyProjectDirectoryNames: [String] {
        legacySlugs.map { ".\($0)" }
    }

    public var compatibleEnvironmentPrefixes: [String] {
        [environmentPrefix] + legacySlugs.map(Self.environmentPrefix(for:))
    }

    public func environmentKey(_ suffix: String) -> String {
        "\(environmentPrefix)_\(suffix)"
    }

    public func environmentValue(
        _ suffix: String,
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let prefixes = [environmentPrefix, "PRODUCT"]
            + Array(compatibleEnvironmentPrefixes.dropFirst())
        for prefix in prefixes {
            if let value = environment["\(prefix)_\(suffix)"], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    public func configurationDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(configurationDirectoryName, isDirectory: true)
    }

    public func legacyConfigurationDirectories(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        legacySlugs.map {
            homeDirectory
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent($0, isDirectory: true)
        }
    }

    public func extensionIdentifier(_ component: String) -> String {
        "\(extensionIdentifierNamespace).\(component)"
    }

    public func codeSigningIdentifier(_ component: String) -> String {
        "\(codeSigningIdentifierNamespace).\(component)"
    }

    public func mcpServerName(_ component: String) -> String {
        "\(mcpNamespace)-\(component)"
    }

    public func compatibleMCPServerNames(_ component: String) -> [String] {
        [mcpServerName(component)]
            + legacySlugs.map { "\($0)-\(component)" }
    }

    private func marketplaceRegistryURL(repositoryName: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(repositoryOwner)/\(repositoryName)/main/registry.json")!
    }

    public static func slug(for value: String) -> String {
        var result = ""
        var previousWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            let isASCIIAlphaNumeric =
                (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 122)
            if isASCIIAlphaNumeric {
                result.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !result.isEmpty && !previousWasDash {
                result.append("-")
                previousWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func environmentPrefix(for slug: String) -> String {
        slug.uppercased().map {
            ($0.isLetter || $0.isNumber) ? String($0) : "_"
        }.joined()
    }

    private var isValid: Bool {
        schemaVersion == 1
            && !slug.isEmpty
            && !repositoryOwner.isEmpty
            && bundleIdentifier.contains(".")
            && extensionIdentifierNamespace.contains(".")
            && codeSigningIdentifierNamespace.contains(".")
    }
}

/// Locates SwiftPM resource bundles in both development executables and a
/// conventional macOS application bundle.
///
/// SwiftPM's generated `Bundle.module` accessor for an executable checks the
/// app-bundle root and an absolute build-machine path. Packaged resources live
/// in `Contents/Resources`, so that accessor can appear healthy in a source
/// checkout and then trap immediately on another Mac. This locator deliberately
/// has no compile-machine fallback.
public enum ProductResourceBundle {
    private final class Token: NSObject {}

    public static func bundle(named name: String,
                              mainBundle: Bundle = .main) -> Bundle? {
        var roots: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return }
            roots.append(standardized)
        }

        func appendRoots(for bundle: Bundle) {
            append(bundle.resourceURL)
            append(bundle.bundleURL)
            appendExecutableAncestors(bundle.executableURL)
        }

        func appendExecutableAncestors(_ executableURL: URL?) {
            guard let executableURL else { return }
            var ancestor = executableURL.deletingLastPathComponent()
            for _ in 0..<6 {
                append(ancestor)
                let parent = ancestor.deletingLastPathComponent()
                guard parent.path != ancestor.path else { break }
                ancestor = parent
            }
        }

        appendRoots(for: mainBundle)
        appendRoots(for: Bundle(for: Token.self))
        if let executablePath = CommandLine.arguments.first,
           !executablePath.isEmpty {
            appendExecutableAncestors(URL(fileURLWithPath: executablePath))
        }

        for root in roots {
            let url = root.appendingPathComponent("\(name).bundle", isDirectory: true)
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }
}
