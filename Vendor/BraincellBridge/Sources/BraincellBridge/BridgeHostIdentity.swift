import ProductIdentity

/// Rename-safe identity for the terminal host that owns Bridge.
///
/// Stable bundle identifiers deliberately remain stable across product-name
/// changes, while user-facing names, terminal session slugs, and MCP names
/// follow the shared product identity.
enum BridgeHostIdentity {
    private static let product = ProductIdentity.current

    static let slug = product.slug
    static let displayName = product.displayName
    static let titleName = product.titleName
    static let bundleIdentifier = product.bundleIdentifier
    static let mcpServerName = product.mcpServerName("bridge")
}
