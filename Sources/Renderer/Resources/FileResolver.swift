import Foundation

// Use to check if a file path exists or a variant of it, and if it does exist then it returns that path
public func resolveFilePath(filePath: String) -> String? {
    let fileManager = FileManager.default

     // Strips off '_diff' and other _... in for example: ImageName_diff.png, some 3D programs export the image as ImageName.png but append _diff in the .mtl
    func makeVariant(_ name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        guard let idx = base.lastIndex(of: "_") else { return nil }

        let stripped = String(base[..<idx])
        return ext.isEmpty ? stripped : "\(stripped).\(ext)"        
    }

    print("Resolving: \(filePath)")
    if fileManager.fileExists(atPath: filePath) { return filePath }
    if let variant = makeVariant(filePath) {
        if fileManager.fileExists(atPath: variant) { return variant }
    }
    print("Unsuccessful: \(filePath) nor its variants were found")
    return nil
}