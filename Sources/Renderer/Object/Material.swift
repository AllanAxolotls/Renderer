import Metal

class Material : Object {
    var materialResourceHandle: ResourceHandle<MaterialResource>
    var materialResource: MaterialResource { materialResourceHandle.resource }
    var baseMaterial: BaseMaterial? { materialResource.baseMaterial }

    // TODO: link the handle indices to the BaseMaterial texture indices
    var diffuseTexture     : Texture? = nil
    var dissolveTexture    : Texture? = nil
    var diffuseMTLTexture  : MTLTexture? { diffuseTexture?.mtlTexture  }
    var dissolveMTLTexture : MTLTexture? { dissolveTexture?.mtlTexture }

    init(materialResourceHandle: ResourceHandle<MaterialResource>) {
        self.materialResourceHandle = materialResourceHandle

        if let diffuseTextureResourceHandle = materialResourceHandle.resource.diffuseTextureResource {
            self.diffuseTexture = Texture(textureResourceHandle: diffuseTextureResourceHandle)
        }
        if let dissolveTextureResourceHandle = materialResourceHandle.resource.dissolveTextureResource {
            self.dissolveTexture = Texture(textureResourceHandle: dissolveTextureResourceHandle)
        }

        super.init()
        self.name = materialResource.name
    }
}