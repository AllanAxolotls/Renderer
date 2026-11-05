import Foundation
import Metal
import ImageIO
import CoreGraphics

class TextureResource : Resource, @unchecked Sendable {
    private unowned let device: MTLDevice
    weak var resourceManager: ResourceManager?
    var mtlTexture: MTLTexture? = nil
    weak var parentMaterialResource: MaterialResource? = nil
    var slot: Int = 0

    init(
        device: MTLDevice,
        from resourceManager: ResourceManager,
        name: String = "Unnamed TextureResource", 
        assetURL: URL? = nil
    ) {
        self.device = device
        self.resourceManager = resourceManager
        super.init(name: name, assetURL: assetURL)
    } 

    func syncTextureIndices(
        diffuseTextureIndex: UInt16 = 0, 
        dissolveTextureIndex: Int16 = -1
    ) {
        guard let materialResource = parentMaterialResource,
              let handle = materialResource.materialHandle,
              let pointer = handle.getPointer() else { return }
        var updatedBaseMaterial = materialResource.baseMaterial ?? BaseMaterial()
        updatedBaseMaterial.diffuseTextureIndex = diffuseTextureIndex
        updatedBaseMaterial.dissolveTextureIndex = dissolveTextureIndex
        pointer.initialize(to: updatedBaseMaterial)
        
    }

    override func performLoad() throws {
        guard let resourceManager = resourceManager else { 
            throw NSError(domain: "TextureResource", code: 1, userInfo: [NSLocalizedDescriptionKey: "ResourceManager is nil"])
        }

        guard let url = assetURL else {
            throw NSError(domain: "TextureResource", code: 2, userInfo: [NSLocalizedDescriptionKey: "assetURL was nil when trying to load texture URL"])
        }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw NSError(domain: "TextureLoader", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage from URL: \(url)"])
        }

        let width = cgImage.width
        let height = cgImage.height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width

        guard let pixelData = calloc(height, bytesPerRow) else {
            throw NSError(domain: "TextureLoader", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate memory for texture bytes"])
        }
        defer { free(pixelData) }

        guard let context = CGContext(
            data: pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw NSError(domain: "TextureLoader", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }

        // Set UV origin
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = .rgba8Unorm_srgb // Automatically handles sRGB gamma correctly
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = .shaderRead

        guard let mtlTexture = device.makeTexture(descriptor: descriptor) else {
            throw NSError(domain: "TextureLoader", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to create MTLTexture from device"])
        }

        let region = MTLRegionMake2D(0, 0, width, height)
        mtlTexture.replace(region: region, mipmapLevel: 0, withBytes: pixelData, bytesPerRow: bytesPerRow)

        self.mtlTexture = mtlTexture
        self.slot = resourceManager.textureSlotCollection.insert(mtlTexture)
    }

    override func unload() {
        self.slot = 0
        self.mtlTexture = nil
    }
}