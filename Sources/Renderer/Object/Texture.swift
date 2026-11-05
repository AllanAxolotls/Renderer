import Metal

class Texture : Object, @unchecked Sendable {
    let textureResourceHandle: ResourceHandle<TextureResource>
    var mtlTexture: MTLTexture? { textureResourceHandle.resource.mtlTexture }

    init(
        textureResourceHandle: ResourceHandle<TextureResource>,
    ) {
        self.textureResourceHandle = textureResourceHandle

        super.init()
    }
}