import Foundation

/// Reads the edition list out of a `.wim` / `.esd` without any external tools.
///
/// A WIM stores an uncompressed UTF-16LE XML blob describing every image it
/// contains, and the header says exactly where it is. That is all ImageHub needs
/// to show "which editions are in this ISO", so inspection works on a stock Mac
/// even when wimlib isn't installed.
enum WimReader {
    struct WimError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Header {
        var imageCount: Int
        var partNumber: Int
        var totalParts: Int
        var xmlOffset: UInt64
        var xmlSize: UInt64
    }

    private static let magic = Data("MSWIM\0\0\0".utf8)

    /// Parses the 208-byte WIM header.
    static func readHeader(at url: URL) throws -> Header {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let head = try handle.read(upToCount: 208), head.count == 208 else {
            throw WimError(message: "\(url.lastPathComponent) is too small to be a WIM.")
        }
        guard head.prefix(8) == magic else {
            throw WimError(message: "\(url.lastPathComponent) is not a WIM/ESD image.")
        }

        // Header layout: part/total at 40/42, image count at 44,
        // then 24-byte resource headers — xml_data starts at offset 72.
        let partNumber = Int(head.u16(at: 40))
        let totalParts = Int(head.u16(at: 42))
        let imageCount = Int(head.u32(at: 44))

        // Resource header: [size:7|flags:1][offset:8][original size:8]
        let xmlSize = head.u64(at: 72) & 0x00FF_FFFF_FFFF_FFFF
        let xmlOffset = head.u64(at: 80)

        guard xmlSize > 0, xmlSize < 64 * 1024 * 1024 else {
            throw WimError(message: "\(url.lastPathComponent) has no readable image metadata.")
        }

        return Header(
            imageCount: imageCount,
            partNumber: partNumber,
            totalParts: totalParts,
            xmlOffset: xmlOffset,
            xmlSize: xmlSize
        )
    }

    /// Returns the raw XML metadata blob as a string.
    static func readXML(at url: URL) throws -> String {
        let header = try readHeader(at: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: header.xmlOffset)
        guard let raw = try handle.read(upToCount: Int(header.xmlSize)), !raw.isEmpty else {
            throw WimError(message: "Couldn't read the image metadata from \(url.lastPathComponent).")
        }

        // The blob is UTF-16LE and starts with a BOM.
        if let text = String(data: raw, encoding: .utf16LittleEndian) {
            return text.replacingOccurrences(of: "\u{FEFF}", with: "")
        }
        if let text = String(data: raw, encoding: .utf8) {
            return text
        }
        throw WimError(message: "The image metadata in \(url.lastPathComponent) isn't valid text.")
    }

    /// Editions inside the image, in index order.
    static func editions(at url: URL) throws -> [ImageEdition] {
        let xml = try readXML(at: url)
        guard let document = try? XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace]) else {
            throw WimError(message: "Couldn't parse the image metadata XML.")
        }
        let nodes = (try? document.nodes(forXPath: "//IMAGE")) ?? []

        var editions: [ImageEdition] = []
        for node in nodes {
            guard let element = node as? XMLElement else { continue }
            let index = Int(element.attribute(forName: "INDEX")?.stringValue ?? "") ?? (editions.count + 1)
            let name = element.firstText(for: "NAME")
                ?? element.firstText(for: "DISPLAYNAME")
                ?? "Image \(index)"
            let description = element.firstText(for: "DESCRIPTION")
                ?? element.firstText(for: "DISPLAYDESCRIPTION")
                ?? ""
            let bytes = Int64(element.firstText(for: "TOTALBYTES") ?? "") ?? 0
            editions.append(
                ImageEdition(index: index, name: name, editionDescription: description, sizeBytes: bytes)
            )
        }
        return editions.sorted { $0.index < $1.index }
    }
}

private extension XMLElement {
    func firstText(for name: String) -> String? {
        guard let child = elements(forName: name).first,
              let value = child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }
}

private extension Data {
    func u16(at offset: Int) -> UInt16 {
        guard count >= offset + 2 else { return 0 }
        return UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func u32(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        var value: UInt32 = 0
        for byte in 0..<4 {
            value |= UInt32(self[startIndex + offset + byte]) << (8 * UInt32(byte))
        }
        return value
    }

    func u64(at offset: Int) -> UInt64 {
        guard count >= offset + 8 else { return 0 }
        var value: UInt64 = 0
        for byte in 0..<8 {
            value |= UInt64(self[startIndex + offset + byte]) << (8 * UInt64(byte))
        }
        return value
    }
}
