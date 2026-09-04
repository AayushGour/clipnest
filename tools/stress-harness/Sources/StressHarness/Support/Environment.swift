// Environment.swift
//
// Builds a fresh, isolated `SwiftDataClipStore` + `BlobStore` rooted at a
// throwaway temp directory for one scenario — HARD CONSTRAINT: never the
// real `~/Library/Application Support/Clipnest`. Every scenario calls
// `makeStressEnvironment(label:)` for its own private root, so scenarios
// never share state and nothing survives the run unless `keepOnDisk` is
// passed (used once, deliberately, to inspect final disk state before
// cleanup — see `main.swift`).
import ClipnestCore
import Foundation

struct StressEnvironment {
  let store: SwiftDataClipStore
  let blobStore: BlobStore
  let root: URL
}

enum EnvironmentError: Error {
  case couldNotCreateTempDir(String)
}

func makeStressEnvironment(label: String) throws -> StressEnvironment {
  let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("clipnest-stress-\(label)-\(UUID().uuidString)", isDirectory: true)
  do {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  } catch {
    throw EnvironmentError.couldNotCreateTempDir(String(describing: error))
  }
  let storeURL = root.appendingPathComponent("ClipItems.store")
  let container = try SwiftDataClipStore.makeContainerForTesting(at: storeURL)
  let blobStore = BlobStore(baseDirectory: root)
  let store = SwiftDataClipStore(modelContainer: container, blobStore: blobStore)
  return StressEnvironment(store: store, blobStore: blobStore, root: root)
}

/// Total bytes under `root/blobs` — used to confirm retention/clear actually
/// reclaims disk, not just metadata rows.
func directorySizeBytes(_ url: URL) -> Int64 {
  let fm = FileManager.default
  guard
    let enumerator = fm.enumerator(
      at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
  else { return 0 }
  var total: Int64 = 0
  for case let fileURL as URL in enumerator {
    if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
      total += Int64(size)
    }
  }
  return total
}

func fileCount(_ url: URL) -> Int {
  let fm = FileManager.default
  guard let entries = try? fm.contentsOfDirectory(atPath: url.path) else { return 0 }
  return entries.count
}
