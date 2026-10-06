// SynchronizedKeyValueStoreTests.swift
//
// Reviewer REJECT follow-up (senior-dev pass): the reviewer's blocking
// finding was that `LinuxAppLifecycle.restoreIBusEngineBeforeQuit()` used
// to construct its OWN fresh `PlatformDefaults.keyValueStore()` instance
// rather than reusing `LinuxAppEnvironment`'s single, `SynchronizedKeyValueStore`-
// wrapped one -- a real data-loss bug, not a theoretical race, since
// `JSONFileKeyValueStore.persist()` rewrites the WHOLE settings file per
// write. `LinuxAppEnvironment.init` itself cannot be constructed in a unit
// test (real SQLite/uinput/X11 I/O -- manual-verify only, same as
// `IBusCommitClient`), so this suite pins the actual mechanism the fix
// relies on directly against `SynchronizedKeyValueStore` (now `internal`,
// not `private`, specifically so this file can reach it via `@testable
// import`):
//   1. Two INDEPENDENT `JSONFileKeyValueStore` instances over the same file
//      DO lose a write -- this is the bug, reproduced directly, not assumed.
//   2. The SAME `SynchronizedKeyValueStore` instance, hit by writes in an
//      order that mirrors "marker set -> an unrelated concurrent settings
//      write -> marker cleared at quit," loses neither -- this is the fix.
//   3. Concurrent writes from multiple real OS threads through the SAME
//      instance all land, with no crash and no dropped write -- the actual
//      concurrency shape `IBusCommitClient`'s nonisolated background work
//      (writing the crash-safety marker) and `SettingsStore`'s `@MainActor`
//      writes create together.
import ClipnestViewModels
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("SynchronizedKeyValueStore (reviewer REJECT: quit-time store race)")
struct SynchronizedKeyValueStoreTests {

  private func makeTempFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("SynchronizedKeyValueStoreTests-\(UUID().uuidString)")
      .appendingPathComponent("settings.json")
  }

  // MARK: - 1. The bug, reproduced directly

  @Test(
    "Two independent JSONFileKeyValueStore instances over the SAME file lose a write -- the exact mechanism behind the reviewer's data-loss finding"
  )
  func twoIndependentInstancesOverTheSameFileLoseAWrite() {
    let fileURL = makeTempFileURL()

    // Mirrors the pre-fix shape: one instance stands in for
    // `LinuxAppEnvironment`'s long-lived store (an ordinary settings write
    // happens through it); the other stands in for the quit path's own
    // fresh `PlatformDefaults.keyValueStore()` -- both loaded their
    // in-memory snapshot from the same, still-empty file.
    let environmentStore = JSONFileKeyValueStore(fileURL: fileURL)
    let quitPathFreshStore = JSONFileKeyValueStore(fileURL: fileURL)

    // A real setting change lands through the environment's own instance
    // and is persisted to disk.
    environmentStore.set("dark", forKey: "settings.theme")
    #expect(JSONFileKeyValueStore(fileURL: fileURL).string(forKey: "settings.theme") == "dark")

    // The quit path's SEPARATE instance never saw that write -- its
    // snapshot is still the empty one it loaded at construction. Clearing
    // a marker it never even had (mirrors `IBusCrashSafetyStateMachine
    // .restoreAfterCommit`'s `store.set(nil, forKey:)`) rewrites the WHOLE
    // file from that stale, empty snapshot.
    quitPathFreshStore.set(nil, forKey: "ibus.pendingRestoreGlobalEngineName")

    // The theme change is gone -- silently, with no error anywhere in this
    // sequence. This is the data-loss bug the reviewer rejected on.
    #expect(JSONFileKeyValueStore(fileURL: fileURL).string(forKey: "settings.theme") == nil)
  }

  // MARK: - 2. The fix, reproduced directly

  @Test(
    "The SAME SynchronizedKeyValueStore instance loses neither write, even interleaved with a marker set/clear -- what routing the quit path through LinuxAppEnvironment.keyValueStore actually buys"
  )
  func sharedSynchronizedInstanceLosesNeitherWrite() {
    let fileURL = makeTempFileURL()
    let shared: any KeyValueStore = SynchronizedKeyValueStore(
      wrapping: JSONFileKeyValueStore(fileURL: fileURL))
    let markerKey = "ibus.pendingRestoreGlobalEngineName"

    // 1. IBusCrashSafetyStateMachine.persistBeforeSwitch, right before
    //    IBusCommitClient switches the global engine.
    shared.set("xkb:us::eng", forKey: markerKey)
    // 2. An UNRELATED settings write lands in between -- e.g. the user
    //    changes a setting while a snippet expansion is mid-flight.
    shared.set("dark", forKey: "settings.theme")
    // 3. LinuxAppEnvironment.restoreIBusEngineIfNeeded()'s marker-clear, at
    //    quit -- through THIS SAME instance, never a second one.
    shared.set(nil, forKey: markerKey)

    let onDisk = JSONFileKeyValueStore(fileURL: fileURL)
    #expect(onDisk.string(forKey: "settings.theme") == "dark")
    #expect(onDisk.string(forKey: markerKey) == nil)
  }

  // MARK: - 3. Real concurrency, not just sequential interleaving

  @Test(
    "Concurrent writes from multiple real OS threads through the SAME instance all land -- IBusCommitClient's nonisolated background writes and SettingsStore's @MainActor writes never drop each other"
  )
  func concurrentWritesThroughSharedInstanceAllLand() {
    let fileURL = makeTempFileURL()
    let shared = SynchronizedKeyValueStore(wrapping: JSONFileKeyValueStore(fileURL: fileURL))
    let writerCount = 25

    DispatchQueue.concurrentPerform(iterations: writerCount) { index in
      shared.set("value-\(index)", forKey: "key-\(index)")
    }

    for index in 0..<writerCount {
      #expect(shared.string(forKey: "key-\(index)") == "value-\(index)")
    }

    // Reload from disk, independent of the in-memory instance above, to
    // confirm every write actually persisted -- not just that it landed in
    // `shared`'s own in-memory `storage`.
    let onDisk = JSONFileKeyValueStore(fileURL: fileURL)
    for index in 0..<writerCount {
      #expect(onDisk.string(forKey: "key-\(index)") == "value-\(index)")
    }
  }
}
