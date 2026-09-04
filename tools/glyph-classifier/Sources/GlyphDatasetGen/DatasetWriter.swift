// DatasetWriter.swift
//
// T-GLY1: writes rendered PNG data into CreateML's expected on-disk
// layout — `<root>/<split>/<classLabel>/<file>.png`, where `<classLabel>`
// becomes the training label `MLImageClassifier` reports metrics against
// (`.labeledDirectories(at:)`). One tiny type so `main.swift`'s generation
// loops don't each hand-roll `FileManager` directory creation.

import Foundation

enum DatasetSplit: String {
  case train
  case test
}

struct DatasetWriter {
  let rootURL: URL

  func write(_ data: Data, classID: String, split: DatasetSplit, index: Int) throws {
    let dir = rootURL.appendingPathComponent(split.rawValue).appendingPathComponent(classID)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent(
      "\(classID)_\(String(format: "%05d", index)).png")
    try data.write(to: fileURL)
  }
}
