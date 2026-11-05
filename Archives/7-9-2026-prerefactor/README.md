**PWS Rasterizer + Raytracer**
===============================================================================================================

**Dependecies**:
- A macOS computer
- Xcode and Xcode-Tools Installed (compilation requires Metal which only the full app sadly has)
- For saving images macOS version 11.0+ is required
- For checking how long the GPU takes per frame, macOS version 10.15+ is required
- Metal 3.0+

To compile shader code and run:
`make run`

To run quicker after having already compiled:
`swift run`

**Controls**:
- W: Forwards
- S: Backwards
- A: Left
- D: Right
- E: Up
- Q: Down
- R: Switch between Rasterization and Raytracing

**Scenes**
To change Scenes or import more objects, either make a new Save
in the Scenes folder or edit the scene inside /View/AppDelegate.swift
For loading a scene: `scene = importScene(filePath: "...", objectImporter: objectImporter) ?? Scene()`
For importing an .obj without loading another scene: 
`scene.addAsset(importer.importObject(filePath: "..."))`
You can also import a scenes objects into a scene: `importToScene(scene: &scene, filePath: "...", objectImporter: objectImproter)`
