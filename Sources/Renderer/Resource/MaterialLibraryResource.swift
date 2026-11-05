import Foundation

/// A Resource for Wavefront .mtl files
final class MaterialLibraryResource : Resource, @unchecked Sendable {
    private unowned let resourceManager: ResourceManager
    var materials: [Material] = []

    /// Raw materialResources
    var ownedMaterialResources: [MaterialResource] = []

    /// New Material Resources from this .mtl Resource
    var ownedMaterialResourceHandles: [ResourceHandle<MaterialResource>] = []

    /// Re-used Material Resources for this .mtl Resource
    var unownedMaterialResourceHandles: [ResourceHandle<MaterialResource>] = []

    /// Unowned and Owned Material Resources for this .mtl Resource
    var usedMaterialResourceHandles: [ResourceHandle<MaterialResource>] {
        ownedMaterialResourceHandles + unownedMaterialResourceHandles
    }

    private var currentMaterial: BaseMaterial? = nil
    private var currentMaterialName: String = "Unnamed Material"
    private var currentMaterialDiffuseTextureURL: URL? = nil
    private var currentMaterialDissolveTextureURL: URL? = nil

    init(from resourceManager: ResourceManager, name: String = "Unnamed MaterialLibraryResource", assetURL: URL? = nil) {
        self.resourceManager = resourceManager
        super.init(name: name, assetURL: assetURL)
    }

    private func flushPendingMaterialResource() throws {
        if var currentMaterial = currentMaterial {
            let materialResourceHandle: ResourceHandle<MaterialResource>
            let materialResourceDescription: MaterialResourceDescription = MaterialResourceDescription(
                diffuseTextureURL: currentMaterialDiffuseTextureURL, 
                dissolveTextureURL: currentMaterialDissolveTextureURL, 
                baseMaterial: currentMaterial
            )

            if let equivalentMaterialResource = resourceManager.getEquivalentMaterialResource(with: materialResourceDescription) {
                materialResourceHandle = ResourceHandle(equivalentMaterialResource)
                unownedMaterialResourceHandles.append(materialResourceHandle)
            } else {
                // Register a new Material
                let materialResource = MaterialResource(name: currentMaterialName, assetURL: assetURL)

                materialResource.materialHandle = resourceManager.materialAllocator.allocAndInit(pointer: &currentMaterial)
                materialResourceHandle = ResourceHandle(materialResource)
                ownedMaterialResources.append(materialResource)
                ownedMaterialResourceHandles.append(materialResourceHandle)
                resourceManager.cachedMaterialResources.append(materialResource)

                // TODO: check why putting Task{} around it doesn't work
                //Task {
                    if let textureURL = currentMaterialDiffuseTextureURL {
                        materialResource.diffuseTextureResource = try resourceManager.loadTextureResource(url: textureURL)
                    } else {
                        materialResource.diffuseTextureResource = resourceManager.defaultTexture.textureResourceHandle
                    }
                    if let textureURL = currentMaterialDissolveTextureURL {
                        materialResource.dissolveTextureResource = try resourceManager.loadTextureResource(url: textureURL)
                    }
                //}
            }

            materials.append(Material(materialResourceHandle: materialResourceHandle))
        }

        currentMaterial = nil
        currentMaterialName = "Unnamed Material"
        currentMaterialDiffuseTextureURL = nil
        currentMaterialDissolveTextureURL = nil
    }

    override func performLoad() throws {
        guard let assetURL = assetURL else { throw NSError(domain: "MaterialLibraryResource", code: 1, userInfo: [NSLocalizedDescriptionKey: "performLoad() failed, assetURL must not be nil"]) }

        // Open the File if it exists
        let contents = try! String(contentsOf: assetURL, encoding: .utf8)

        let lines = contents.components(separatedBy: .newlines)

        for line in lines {
            let cleanLine = line.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanLine.isEmpty || cleanLine.hasPrefix("#") { continue }

            let tokens = cleanLine.components(separatedBy: .whitespaces).filter{ !$0.isEmpty }
            guard let command = tokens.first else { continue }

            switch command {
            case "Kd", "Ka": // Diffuse Color, (Ka = ambient color, but they get used interchangeably)
                guard tokens.count >= 4 else { continue }
                currentMaterial?.diffuseColor.r = Float(tokens[1])!
                currentMaterial?.diffuseColor.g = Float(tokens[2])!
                currentMaterial?.diffuseColor.b = Float(tokens[3])!

            case "Ke": // Emit Color
                guard tokens.count >= 4 else { continue }
                currentMaterial?.emissionColor.r = Float(tokens[1])!
                currentMaterial?.emissionColor.g = Float(tokens[2])!
                currentMaterial?.emissionColor.b = Float(tokens[3])!

            case "d": // Dissolve
                guard tokens.count >= 2 else { continue }
                currentMaterial?.diffuseColor.a = Float(tokens[1])!

            case "Tr": // Transparency
                guard tokens.count >= 2 else { continue }
                currentMaterial?.diffuseColor.a = 1.0 - Float(tokens[1])!

            case "Ns": // Specular Exponent
                guard tokens.count >= 2, let ns = Float(tokens[1]) else { continue }
                let roughness = sqrt(2.0 / (ns + 2.0))
                currentMaterial?.roughness = max(0.01, min(1.0, roughness))

            case "Ior": // Index of Refraction
                guard tokens.count >= 2 else { continue }
                currentMaterial?.refractiveIndex = Float(tokens[1])!

            case "Pr": // Phyiscal Roughness
                guard tokens.count >= 2 else { continue }
                currentMaterial?.roughness = Float(tokens[1])!

            case "Pm": // Phyiscal Metallic
                guard tokens.count >= 2 else { continue }
                currentMaterial?.metallic = Float(tokens[1])!

            case "illum": // Illumination Model
                guard tokens.count >= 2 else { continue }
                let illum = Int(tokens[1])!
                if illum == 0 { currentMaterial?.isSky = true }

            case "map_Kd": // Diffuse Texture
                guard tokens.count >= 2 else { continue }
                currentMaterialDiffuseTextureURL = resolveTextureURL(from: tokens[1], mtlAssetURL: assetURL)

            case "map_d": // Dissolve Texture
                guard tokens.count >= 2 else { continue }
                currentMaterialDissolveTextureURL = resolveTextureURL(from: tokens[1], mtlAssetURL: assetURL)

            case "sky": // Skybox Flag (Custom flag, not part of the .mtl spec)
                currentMaterial?.isSky = true

            case "newmtl":
                try flushPendingMaterialResource()
                currentMaterial = BaseMaterial()
                guard tokens.count > 1 else { continue }
                currentMaterialName = tokens[1]

            default:
                break
            }

        }

        try flushPendingMaterialResource()
    }

    override func unload() {
        materials.removeAll()
        ownedMaterialResources.removeAll()
        ownedMaterialResourceHandles.removeAll()
        unownedMaterialResourceHandles.removeAll()
    }

    func getMaterialByName(_ name: String) -> Material? {
        return materials.first(where: { $0.name == name })
    }

    func getMaterialResourceHandleByName(_ name: String) -> ResourceHandle<MaterialResource>? {
        return usedMaterialResourceHandles.first(where: { $0.resource.name == name })
    }

    func asModel() -> Model {
        let model = Model(name: self.name)
        model.addChildren(materials)
        return model
    }
}


extension MaterialLibraryResource {
    
    /// Resolves texture paths from .mtl files, handling exporter suffixes like _diff, _norm, etc.
    func resolveTextureURL(from originalPath: String, mtlAssetURL: URL) -> URL {
        let exactURL = mtlAssetURL.deletingLastPathComponent().appendingPathComponent(originalPath)
        if FileManager.default.fileExists(atPath: exactURL.path) {
            return exactURL
        }
        
        let url = URL(fileURLWithPath: originalPath)
        let filename = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        
        let suffixesToStrip = ["_diff", "_albedo", "_kd", "_norm", "_normal", "_bump", "_spec", "_rough", "_metal"]
        
        var cleanedFilename = filename
        for suffix in suffixesToStrip {
            if cleanedFilename.hasSuffix(suffix) {
                cleanedFilename.removeLast(suffix.count)
                break
            }
        }
        
        let fallbackURL = mtlAssetURL.deletingLastPathComponent().appendingPathComponent("\(cleanedFilename).\(ext)")
        if FileManager.default.fileExists(atPath: fallbackURL.path) {
            print("ResourceManager: Resolved texture suffix mismatch. Using fallback: \(fallbackURL.lastPathComponent)")
            return fallbackURL
        }
        
        return exactURL
    }

}