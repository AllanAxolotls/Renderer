import Cocoa

// AppDelegate Menu
extension AppDelegate {
    
    @MainActor public func initMenu() {
        let mainMenu = NSMenu()

        let fileMenu = NSMenu(title: "File")

        // Loading
        fileMenu.addItem(
            NSMenuItem(title: "Load Scene (.ryx)",     action: #selector(loadRyxPanel), keyEquivalent: "o")
        )
        fileMenu.addItem(
            NSMenuItem(title: "Load Scene (.json)",    action: #selector(loadJsonPanel), keyEquivalent: "j")
        )
        
        fileMenu.addItem(.separator())

        // Saving
        fileMenu.addItem(
            NSMenuItem(title: "Save Scene (.ryx)",     action: #selector(saveRyxPanel), keyEquivalent: "s")
        )
        fileMenu.addItem(
            NSMenuItem(title: "SaveAs Scene (.ryx)",   action: #selector(saveAsRyxPanel), keyEquivalent: "" )
        )

        fileMenu.addItem(.separator())

        // Importing
        fileMenu.addItem(
            NSMenuItem(title: "Import Wavefront OBJ (.obj)", action: #selector(importObjPanel), keyEquivalent: "o")
        )
        fileMenu.addItem(
            NSMenuItem(title: "Import Wavefront MTL (.mtl)", action: #selector(importMtlPanel), keyEquivalent: "o")
        )


        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenu = NSMenu(title: "Edit")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // Loading
    @objc func loadRyxPanel() {

    }

    @objc func loadJsonPanel() {

    }

    // Importing
    @objc func importObjPanel() {

    }

    @objc func importMtlPanel() {

    }

    // Saving
    @objc func saveRyxPanel() {

    }

    @objc func saveAsRyxPanel() {

    }
}