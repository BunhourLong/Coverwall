import Foundation

/// CLI-only: the cover embedded in an audio file, read straight from its tags (PLAN.md Phase 6).
/// Not AVFoundation: its artwork API is async-only (TileCache is sync) and it doesn't read FLAC pictures.
enum AudioArtwork {
    static let extensions: Set<String> = ["mp3", "m4a", "flac"]

    /// The first embedded picture's bytes in `file` (an audio file with extension `ext`), or nil when there is none.
    // shortcut: first picture, not necessarily the "front cover" one; pick by picture type if back covers show up.
    static func picture(in file: Data, ext: String) -> Data? {
        let picture: Data? = switch ext {
        case "mp3": id3Picture(file)
        case "m4a": mp4Cover(file)
        case "flac": flacPicture(file)
        default: nil
        }
        return picture.map { Data($0) }   // copy out of the (mapped) file
    }

    /// ID3v2.2 `PIC` / v2.3–2.4 `APIC` frame at the start of an mp3.
    // shortcut: no art from tags with the unsynchronisation flag, v2.4 frames with a data-length indicator, or v2.4
    // tags written with plain (not synchsafe) frame sizes (old iTunes); handle them if real libraries show gaps.
    static func id3Picture(_ d: Data) -> Data? {
        guard d.bytes(0, 3) == Data("ID3".utf8), let version = d.uint(3, 1), (2...4).contains(version),
              let flags = d.uint(5, 1), flags & 0x80 == 0, let tagSize = d.synchsafe(6) else { return nil }
        let end = min(10 + tagSize, d.count)
        var at = 10
        if flags & 0x40 != 0, version > 2 {   // extended header: v2.3 size excludes itself, v2.4 includes it
            guard let size = version == 4 ? d.synchsafe(at) : d.uint(at, 4).map({ $0 + 4 }) else { return nil }
            at += size
        }
        let (idLength, headerLength) = version == 2 ? (3, 6) : (4, 10)
        while at + headerLength <= end, let id = d.bytes(at, idLength), id.first != 0 {
            guard let size = version == 4 ? d.synchsafe(at + 4) : d.uint(at + idLength, idLength) else { return nil }
            let body = at + headerLength
            if id == Data((version == 2 ? "PIC" : "APIC").utf8) {
                // A frame cut short (truncated file) would decode as a half-drawn cover: none instead.
                return size <= end - body ? d.bytes(body, size).flatMap { picture(inFrame: $0, v22: version == 2) } : nil
            }
            at = body + size
        }
        return nil
    }

    /// Frame body: encoding, image format (v2.2: 3 chars, else NUL-terminated MIME), picture type, description, data.
    private static func picture(inFrame f: Data, v22: Bool) -> Data? {
        guard let encoding = f.uint(0, 1) else { return nil }
        var at = 1
        if v22 { at += 3 } else { guard let nul = f.offset(of: [0], from: at) else { return nil }; at = nul + 1 }
        at += 1
        let wide = encoding == 1 || encoding == 2   // UTF-16 descriptions end in 00 00
        guard let nul = f.offset(of: wide ? [0, 0] : [0], from: at, step: wide ? 2 : 1) else { return nil }
        let start = nul + (wide ? 2 : 1)
        return f.bytes(start, f.count - start)
    }

    /// `moov/udta/meta/ilst/covr/data` atom of an m4a.
    static func mp4Cover(_ d: Data) -> Data? {
        var body = 0..<d.count
        // meta is a full box (4 bytes version + flags); data starts with 4 bytes type + 4 bytes locale.
        for (type, skip) in [("moov", 0), ("udta", 0), ("meta", 4), ("ilst", 0), ("covr", 0), ("data", 8)] {
            guard let box = d.mp4Box(type, in: body), box.count >= skip else { return nil }
            body = (box.lowerBound + skip)..<box.upperBound
        }
        return d.bytes(body.lowerBound, body.count)
    }

    /// First PICTURE metadata block of a FLAC file.
    // shortcut: a FLAC with an ID3v2 tag in front of `fLaC` (some rippers) gives no art; skip the tag if that shows up.
    static func flacPicture(_ d: Data) -> Data? {
        guard d.bytes(0, 4) == Data("fLaC".utf8) else { return nil }
        var at = 4
        while let header = d.uint(at, 1), let length = d.uint(at + 1, 3) {
            let body = at + 4
            if header & 0x7F == 6 {   // type, MIME, description, width/height/depth/colors, data
                guard let mime = d.uint(body + 4, 4), let description = d.uint(body + 8 + mime, 4) else { return nil }
                let size = body + 12 + mime + description + 16
                return d.uint(size, 4).flatMap { d.bytes(size + 4, $0) }
            }
            if header & 0x80 != 0 { return nil }   // that was the last metadata block
            at = body + length
        }
        return nil
    }
}

private extension Data {
    /// `count` bytes at offset `at` (from the start of this Data), or nil past the end.
    func bytes(_ at: Int, _ count: Int) -> Data? {
        guard at >= 0, count >= 0, count <= self.count - at else { return nil }
        return self[(startIndex + at)..<(startIndex + at + count)]
    }

    /// Big-endian unsigned integer of `count` bytes.
    func uint(_ at: Int, _ count: Int) -> Int? {
        bytes(at, count)?.reduce(0) { $0 << 8 | Int($1) }
    }

    /// ID3 synchsafe 28-bit integer (7 bits per byte).
    func synchsafe(_ at: Int) -> Int? {
        bytes(at, 4)?.reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }

    func offset(of terminator: [UInt8], from start: Int, step: Int = 1) -> Int? {
        var at = start
        while let candidate = bytes(at, terminator.count) {
            if candidate.elementsEqual(terminator) { return at }
            at += step
        }
        return nil
    }

    /// Body of the first `type` box directly inside `range`.
    func mp4Box(_ type: String, in range: Range<Int>) -> Range<Int>? {
        var at = range.lowerBound
        while at + 8 <= range.upperBound, let size32 = uint(at, 4), let name = bytes(at + 4, 4) {
            let (header, size) = size32 == 1 ? (16, uint(at + 8, 8) ?? 0) : (8, size32 == 0 ? range.upperBound - at : size32)
            guard size >= header, size <= range.upperBound - at else { return nil }
            if name == Data(type.utf8) { return (at + header)..<(at + size) }
            at += size
        }
        return nil
    }
}
