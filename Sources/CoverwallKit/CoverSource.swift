import Foundation

/// CLI-only: where covers come from (CLAUDE.md 9). `TileCache` turns any source into a tile cache.
public protocol CoverSource: Sendable {
    var policy: SourcePolicy { get }
    /// The complete list, or throw — never a partial one.
    func items() async throws -> [CoverItem]
    /// The cover's encoded image; `nil` = this item has no cover (a track without art). Throwing `UnreadableCover`
    /// skips the item; any other error fails the whole sync, so the old cache stays (e.g. offline mid-download).
    func data(for item: CoverItem) async throws -> Data?
    /// How many `data(for:)` calls may run at once.
    var maxConcurrentReads: Int { get }
}

extension CoverSource {
    public var maxConcurrentReads: Int { 1 }
}

/// This one cover can't be read or isn't an image: reported as skipped, the sync goes on.
public struct UnreadableCover: Error {
    public init() {}
}

/// A path or URL plus its mtime (0 when the source is content-addressed): the same pair the manifest keeps per tile,
/// so an unchanged item is never read again.
public typealias CoverItem = CacheManifest.Tile

/// A folder of images and/or music files with embedded art, scanned recursively.
public struct LocalFolderSource: CoverSource {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "tiff", "tif"]
    static let scanned = extensions.union(AudioArtwork.extensions)

    public let folder: String
    public var policy: SourcePolicy { .localFolder }

    public init(folder: String) {
        self.folder = folder
    }

    /// Sorted, so dedupe keeps the same original.
    public func items() async throws -> [CoverItem] {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
            throw TileCacheError.sourceMissing(folder)
        }
        let files = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.contentModificationDateKey],
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return (files?.compactMap { $0 as? URL } ?? [])
            .filter { Self.scanned.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
            .map { file in
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
                return CoverItem(source: file.path, mtime: mtime)
            }
    }

    public func data(for item: CoverItem) async throws -> Data? {
        let ext = (item.source as NSString).pathExtension.lowercased(), isAudio = AudioArtwork.extensions.contains(ext)
        // Audio is mapped: only the tag's pages are read, not the whole track. Tracks of one album share these bytes.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: item.source), options: isAudio ? .alwaysMapped : []) else {
            throw UnreadableCover()
        }
        return isAudio ? AudioArtwork.picture(in: data, ext: ext) : data
    }
}
