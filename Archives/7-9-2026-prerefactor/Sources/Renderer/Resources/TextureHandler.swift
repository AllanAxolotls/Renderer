import Metal
import MetalKit

public final class TextureHandler {
    private let device: MTLDevice
    private var mtkTextureLoader: MTKTextureLoader

    public var textures: [MTLTexture] = []
    public var links: [String : Int16] = [:]

    init(device: MTLDevice) {
        self.device = device
        self.mtkTextureLoader = MTKTextureLoader(device: device)

        links["Default"] = 0

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: 1,
            height: 1,
            mipmapped: false
        )
        desc.usage = .shaderRead

        let defaultTexture = device.makeTexture(descriptor: desc)!
        var rgbaColor: [UInt8] = [255, 255, 255, 255]
        defaultTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &rgbaColor,
            bytesPerRow: 4
        )
        self.textures.append(defaultTexture)
    }

    public func loadTexture(filePath: String) -> MTLTexture? {
        if let fixedPath = resolveFilePath(filePath: filePath) {
            let textureURL = URL(fileURLWithPath: fixedPath)
            let options: [MTKTextureLoader.Option: Any] = [
                .origin: MTKTextureLoader.Origin.bottomLeft, // important for OBJ UVs
                .SRGB: true,
            ]
            
            do {
                print("Loading Texture")
                let texture = try mtkTextureLoader.newTexture(URL: textureURL, options: options)
                return texture
            } catch {
                print("An error occured while trying to load texture \(fixedPath): \n\(error.localizedDescription)")
                return nil
            }
        } else {
            print("Loading texture '\(filePath)' failed, not found in directory")
            return nil
        }
    }

    public func getTextureIndex(texturePath: String) -> Int16 {
        if URL(fileURLWithPath: texturePath).lastPathComponent == "Default" { return 0 }
        print("Getting Texture: \(texturePath)")
        let index = links[texturePath]
        if let index = index { return index }

        guard let texture = loadTexture(filePath: texturePath) else { return 0 }
        let newIndex = Int16(textures.count)
        links[texturePath] = newIndex
        textures.append(texture)

        return newIndex
    }
}