import Metal

/// Exact residency for the row cache, including textures shared by several
/// rows or color layers. Update it only when ownership changes so a warm
/// frame's budget check does not walk every cached row and query Metal again.
@MainActor
struct RowTextureResidency {
    private struct Allocation {
        let bytes: Int
        var references: Int
    }

    private var allocations: [ObjectIdentifier: Allocation] = [:]
    private(set) var allocatedBytes = 0

    mutating func retain(_ entry: IndependentRowCacheEntry) {
        if let texture = entry.coverageTexture { retain(texture) }
        for layer in entry.colorLayers { retain(layer.texture) }
    }

    mutating func release(_ entry: IndependentRowCacheEntry) {
        if let texture = entry.coverageTexture { release(texture) }
        for layer in entry.colorLayers { release(layer.texture) }
    }

    mutating func removeAll() {
        allocations.removeAll(keepingCapacity: true)
        allocatedBytes = 0
    }

    private mutating func retain(_ texture: MTLTexture) {
        let identity = ObjectIdentifier(texture as AnyObject)
        if var allocation = allocations[identity] {
            allocation.references += 1
            allocations[identity] = allocation
        } else {
            let bytes = texture.allocatedSize
            allocations[identity] = Allocation(bytes: bytes, references: 1)
            allocatedBytes += bytes
        }
    }

    private mutating func release(_ texture: MTLTexture) {
        let identity = ObjectIdentifier(texture as AnyObject)
        guard var allocation = allocations[identity] else {
            preconditionFailure("released a texture that is not in the row cache")
        }
        allocation.references -= 1
        if allocation.references == 0 {
            allocatedBytes -= allocation.bytes
            allocations.removeValue(forKey: identity)
        } else {
            allocations[identity] = allocation
        }
    }
}
