import Foundation

/// On-disk layout (ADR-007): ~/Library/Application Support/Utter/Models/<id>/<file>.gguf
public enum ModelLocation {
    public static var appSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Utter", isDirectory: true)
    }

    public static var modelsDirectory: URL {
        appSupport.appendingPathComponent("Models", isDirectory: true)
    }

    /// Default model until the model manager (M3) lets the user choose.
    public static let defaultModelID = "parakeet-tdt-0.6b-v3"
    public static let defaultModelFile = "parakeet-tdt-0.6b-v3-Q8_0.gguf"
    public static let defaultModelName = "Parakeet V3"

    public static var defaultModelURL: URL {
        modelsDirectory.appendingPathComponent(defaultModelID, isDirectory: true).appendingPathComponent(defaultModelFile)
    }
}
