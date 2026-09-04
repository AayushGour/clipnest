// RealBlobFixtures.swift
//
// HARD CONSTRAINT (T-STRESS1): reads real image bytes from the user's real
// `~/Library/Application Support/Clipnest/blobs/` directory for realistic
// payload sizes — via `Data(contentsOf:)` ONLY, never `Data.write`,
// `FileManager.removeItem`, or anything else that mutates that directory or
// any file in it. Every store this harness actually WRITES to lives under a
// fresh `NSTemporaryDirectory()` subdirectory instead — see `main.swift`.
//
// `maxTotalBytes` on `loadRealImages` matters beyond tidiness: this
// directory holds 265MB across 41 real images (confirmed via `du`/`file`
// before writing this harness), and this machine was observed already
// under real memory pressure from other agents' concurrent work at the
// time this harness was run (`vm.swapusage` ~87% full, ~94MB free physical
// — see the T-STRESS1 report) — loading the entire directory into `Data`
// eagerly, unconditionally, on every run would itself risk compounding
// that pressure regardless of what any scenario then does with the bytes.
// File sizes are read via `resourceValues` (no content read) and sorted
// ascending BEFORE any `Data(contentsOf:)` call, so files past the budget
// are never read into memory at all, not just discarded after.
import ClipnestCore
import Foundation

enum RealBlobFixtures {
  /// The user's real blob directory — READ-ONLY. Never passed to `BlobStore`
  /// or any writer; only ever opened via `Data(contentsOf:)` below.
  static var realBlobsDirectory: URL {
    BlobStore.defaultBaseDirectory().appendingPathComponent(
      BlobStore.blobsDirectoryName, isDirectory: true)
  }

  struct ImageFixture {
    let bytes: Data
    let byteCount: Int
    let hashPrefix: String
  }

  /// Loads real TIFF blobs (the format every image blob in this store
  /// happens to be, confirmed via `file` before writing this harness),
  /// smallest-first, stopping once `maxTotalBytes` (default 60MB — a
  /// deliberately conservative budget given this machine's observed memory
  /// pressure) or `limit` (whichever binds first) is reached. Returns `[]`
  /// (never throws) if the directory is empty/missing, so a machine with no
  /// prior Clipnest usage can still run the harness (falling back to
  /// synthetic fixtures — see `SyntheticFixtures.swift`).
  static func loadRealImages(limit: Int? = nil, maxTotalBytes: Int = 60_000_000) -> [ImageFixture]
  {
    let fm = FileManager.default
    guard
      let entries = try? fm.contentsOfDirectory(
        at: realBlobsDirectory, includingPropertiesForKeys: [.fileSizeKey])
    else {
      return []
    }
    let sortedBySize = entries.sorted { lhs, rhs in
      let lhsSize = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      let rhsSize = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      return lhsSize < rhsSize
    }

    var fixtures: [ImageFixture] = []
    var totalBytes = 0
    for url in sortedBySize {
      if let limit, fixtures.count >= limit { break }
      guard let data = try? Data(contentsOf: url) else { continue }
      guard isTIFF(data) else { continue }
      guard totalBytes + data.count <= maxTotalBytes || fixtures.isEmpty else { continue }
      fixtures.append(
        ImageFixture(
          bytes: data, byteCount: data.count, hashPrefix: String(url.lastPathComponent.prefix(12)))
      )
      totalBytes += data.count
    }
    return fixtures
  }

  /// The specific 25MB blob the brief names explicitly
  /// (`d83704388f25c562fc9cb1e64f580fcfb2f3b9f392b6389e3c9df617e850f4f2`).
  /// Loaded on demand, never held alongside the full `loadRealImages()` pool
  /// unless a scenario explicitly asks for both.
  static func loadNamedLargeBlob() -> ImageFixture? {
    let url = realBlobsDirectory.appendingPathComponent(
      "d83704388f25c562fc9cb1e64f580fcfb2f3b9f392b6389e3c9df617e850f4f2")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return ImageFixture(bytes: data, byteCount: data.count, hashPrefix: "d8370438...")
  }

  private static func isTIFF(_ data: Data) -> Bool {
    guard data.count >= 4 else { return false }
    let bytes = [UInt8](data.prefix(4))
    // Big-endian ("MM\0*") or little-endian ("II*\0") TIFF magic.
    return bytes == [0x4D, 0x4D, 0x00, 0x2A] || bytes == [0x49, 0x49, 0x2A, 0x00]
  }
}
