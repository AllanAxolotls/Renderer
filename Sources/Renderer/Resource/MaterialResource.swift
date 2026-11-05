import Foundation
import Metal

class MaterialResource : Resource, @unchecked Sendable {
    var materialHandle: MTLBufferAllocator<BaseMaterial>.Handle? = nil
    var diffuseTextureResource :  ResourceHandle<TextureResource>? = nil { didSet { updateDiffuseTexture() } }
    var dissolveTextureResource : ResourceHandle<TextureResource>? = nil { didSet { updateDissolveTexture() } }

    var baseMaterial: BaseMaterial? { materialHandle?.first }
    var diffuseMTLTexture: MTLTexture? { diffuseTextureResource?.resource.mtlTexture }
    var dissolveMTLTexture: MTLTexture? { dissolveTextureResource?.resource.mtlTexture }

    init(
        name: String = "Unnamed MaterialResource",
        assetURL: URL? = nil,

        materialHandle: MTLBufferAllocator<BaseMaterial>.Handle? = nil
    ) {
        self.materialHandle = materialHandle
        super.init(name: name, assetURL: assetURL)
    }

    func updateDiffuseTexture() {
        guard let slot = diffuseTextureResource?.resource.slot,
              let materialHandle = materialHandle else { return }

        guard let materialRawPtr = materialHandle.getRawPointer() else { return }
        
        let targetPtr = materialRawPtr
            .advanced(by: BaseMaterial.diffuseTextureIndexOffset)
            .bindMemory(to: UInt16.self, capacity: 1)
        
        targetPtr.pointee = UInt16(slot)
    }

    func updateDissolveTexture() {
        guard let slot = dissolveTextureResource?.resource.slot,
              let materialHandle = materialHandle else { return }

        guard let materialRawPtr = materialHandle.getRawPointer() else { return }
        
        let targetPtr = materialRawPtr
            .advanced(by: BaseMaterial.dissolveTextureIndexOffset)
            .bindMemory(to: Int16.self, capacity: 1)
        
        targetPtr.pointee = Int16(slot)
    }

    override func performLoad() throws {
        // Should be used for material files that get stored solo
        // .mtl doesn't have this so this function can stay empty
    }

    override func unload() {
        materialHandle?.free()
        diffuseTextureResource = nil
        dissolveTextureResource = nil
    }

    func matchesDescription(desc: MaterialResourceDescription) -> Bool {
        guard let materialHandle = materialHandle else { return false }

        let baseMaterialEq: Bool = materialHandle.withUnsafeBufferPointer { buffer in
            guard let candidateMaterial = buffer.first else { return false }
            return candidateMaterial == desc.baseMaterial
        }

        if !baseMaterialEq {
            return false
        }

        if desc.diffuseTextureURL != diffuseTextureResource?.resource.assetURL {
            return false
        }

        if desc.dissolveTextureURL != dissolveTextureResource?.resource.assetURL {
            return false
        }

        return true
    }
}

struct MaterialResourceDescription {
    let diffuseTextureURL: URL?
    let dissolveTextureURL: URL?
    let baseMaterial: BaseMaterial
}