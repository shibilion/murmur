import CryptoKit
import Foundation
import MurmurCore

/// Shared on-disk verification rules: the `.verified` marker content and the "is it installed" check.
public enum ModelVerification {
    /// Content of the `.verified` marker: SHA-256 over the catalog's file hashes.
    public static func listHash(_ m: CatalogModel) -> String {
        SHA256.hash(data: Data(m.files.map(\.sha256).joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// True when every catalog file exists at its expected size and the marker matches.
    public static func isVerified(folder: URL, model m: CatalogModel) -> Bool {
        let fm = FileManager.default
        for f in m.files {
            let attrs = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(f.relativePath).path)
            guard (attrs?[.size] as? NSNumber)?.int64Value == f.bytes else { return false }
        }
        return (try? String(contentsOf: folder.appendingPathComponent(".verified"), encoding: .utf8)) == listHash(m)
    }

    static func writeMarker(folder: URL, model m: CatalogModel) throws {
        try listHash(m).write(to: folder.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
    }
}

public enum ModelLocations {
    public static let applicationSupport: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    /// Root of Murmur's model folder: `<root>/<catalog id>/...`.
    public static let murmurModels: URL =
        applicationSupport.appendingPathComponent("Murmur/Models", isDirectory: true)
}
