// ModelLocating.swift
//
// P6-C (Linux OCR): where PP-OCRv5's model files + character dictionary
// live on disk. A narrow, injectable seam (mirrors this codebase's existing
// `PasteboardReading`/`EventSynthesizing` pattern — see
// `Sources/ClipnestCore/OCR/TextRecognizing.swift`'s own doc comment) so
// `OnnxTextRecognizer` never hardcodes a filesystem path itself, and tests
// can supply fake/missing paths without touching a real filesystem.
//
// NOTHING is ever downloaded here — this locates files the `clipnest-ocr`
// `.deb` already installed (see `Package.swift`'s `COnnxRuntime` comment for
// the packaging split this mirrors); this module's whole reason for being
// separate from `ClipnestPlatformLinux` is that ONNX Runtime + its ~21.7MB
// of models are vendored by that separate package, never fetched at
// runtime — matching this product's "the only network traffic is a daily
// GitHub release check" privacy promise.
import Foundation

public struct OCRModelPaths: Sendable, Equatable {
  /// PP-OCRv5 mobile detection model (~4.7MB per the plan).
  public let detectionModelPath: String
  /// PP-OCRv5 mobile recognition model (~16MB per the plan).
  public let recognitionModelPath: String
  /// PP-OCRv5 text-line orientation classifier (~0.96MB per the plan). Only
  /// loaded/run when `OCRTierConfiguration.runsOrientationClassifier` is
  /// true for the active tier.
  public let orientationModelPath: String
  /// The character dictionary `CTCDecoder.greedyDecode` maps recognition
  /// class indices to — one line per character, in class-index-minus-one
  /// order (PP-OCR's own convention; see `CTCDecoder.blankClassIndex`'s
  /// doc comment).
  public let characterDictionaryPath: String

  public init(
    detectionModelPath: String, recognitionModelPath: String, orientationModelPath: String,
    characterDictionaryPath: String
  ) {
    self.detectionModelPath = detectionModelPath
    self.recognitionModelPath = recognitionModelPath
    self.orientationModelPath = orientationModelPath
    self.characterDictionaryPath = characterDictionaryPath
  }
}

/// Locates the installed model files. Separated from any single "default"
/// implementation (there's deliberately no `LiveModelLocator` hardcoding a
/// path in THIS file) because the real install location is a packaging
/// decision the `clipnest-ocr` `.deb` spec owns, not something this task
/// should freeze without that spec in hand — `StandardOCRModelLocator`
/// below documents the assumed convention and is trivially swappable if the
/// packaging task lands a different one.
public protocol OCRModelLocating: Sendable {
  /// Returns `nil` if the model directory (or any required file within it)
  /// doesn't exist — `OnnxTextRecognizer` treats this exactly like any
  /// other best-effort OCR failure (returns `nil` from `recognizeText`,
  /// never crashes), which is the correct behavior for a machine that
  /// simply doesn't have `clipnest-ocr` installed (`clipnest` only
  /// `Recommends` it, never `Depends`).
  func locate() -> OCRModelPaths?
}

/// Assumes the FHS-conventional install root a `.deb` package would use for
/// read-only architecture-independent data: `/usr/share/<package>/...`.
/// UNVERIFIED against an actual `clipnest-ocr` packaging spec (none exists
/// yet in this repo) — treat this constant as the documented assumption to
/// reconcile once that spec lands, not a frozen contract.
public struct StandardOCRModelLocator: OCRModelLocating {
  /// No magic string repeated at each path below — named once per
  /// coding-standards.md.
  private static let installRoot = "/usr/share/clipnest-ocr/models"

  private let fileExists: @Sendable (String) -> Bool

  /// `fileExists` defaults to a real `FileManager.default.fileExists`
  /// check but is injectable so tests can simulate "package not installed"
  /// or "one file missing" without a real filesystem.
  public init(
    fileExists: @escaping @Sendable (String) -> Bool = { FileManagerExistenceCheck.check($0) }
  ) {
    self.fileExists = fileExists
  }

  public func locate() -> OCRModelPaths? {
    let paths = OCRModelPaths(
      detectionModelPath: "\(Self.installRoot)/det.onnx",
      recognitionModelPath: "\(Self.installRoot)/rec.onnx",
      orientationModelPath: "\(Self.installRoot)/cls.onnx",
      characterDictionaryPath: "\(Self.installRoot)/dict.txt")
    let allPaths = [
      paths.detectionModelPath, paths.recognitionModelPath, paths.orientationModelPath,
      paths.characterDictionaryPath,
    ]
    guard allPaths.allSatisfy(fileExists) else { return nil }
    return paths
  }
}

/// Wraps `FileManager.default.fileExists(atPath:)` as a free function so it
/// can be `StandardOCRModelLocator`'s default parameter value (a method
/// reference on a singleton works fine as a `@Sendable` closure default
/// too, but a named top-level function is clearer at the call site about
/// what's being defaulted).
public enum FileManagerExistenceCheck {
  public static func check(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }
}
