// OCRPipeline.swift
//
// P6-C (Linux OCR): the full decode → detect → postprocess → crop →
// recognize → decode pipeline, wiring together every piece built for this
// task: `PNGDecoder`, `ImagePreprocessing`, `OrtSessionSet.runDetection`,
// `TensorReshaping`, `DBPostProcess`, `BoxScaling`, `PolygonUnclip`,
// `BoxOrdering`, `TextLineCropper`, `OrtSessionSet.runRecognition`,
// `CTCDecoder`, `CharacterDictionary`.
//
// UNVERIFIED END TO END: every ORT-touching call in this file can only be
// exercised against a real ONNX Runtime + real PP-OCRv5 model files, neither
// of which exists in this task's environment (see `OrtSession.swift`'s doc
// comment). The individual NON-ORT pieces this file calls into (listed
// above, minus the two `OrtSessionSet.run*` calls) are each independently
// unit-tested; this file is the integration glue that cannot be.
//
// v1 SCOPE: recognition runs ONE text line per `Run` call, not truly
// batched to `OCRTierConfiguration.recognitionBatchSize` — real batching
// requires padding multiple variable-width crops to a common width before
// stacking them into one tensor, which needs real model output to validate
// the padding-vs-accuracy tradeoff against. `recognitionBatchSize` is
// still selected per-tier and stays part of the public tier contract for
// when batching is implemented; this is a disclosed, deliberate limitation
// (same family as `PolygonUnclip.expand`'s and `TextLineCropper
// .boundingBox`'s v1 scoping notes), not a bug.
#if CLIPNEST_HAS_ONNXRUNTIME
  import Dispatch

  enum OCRPipeline {
    /// DB postprocess's unclip ratio — restores shrunk detection polygons
    /// to roughly true text size (`PolygonUnclip.offsetDistance`'s
    /// `ratio` parameter). 1.5 is DB's own paper/PaddleOCR reference
    /// default — UNVERIFIED against this specific PP-OCRv5 export (no
    /// real model output available to tune against here; see
    /// `DBPostProcess.binarizationThreshold`'s doc comment for the same
    /// caveat).
    static let unclipRatio: Double = 1.5

    /// Runs the full pipeline. MUST be called from
    /// `OrtEnvironment.shared.queue` — every `OrtSessionSet.run*` call
    /// inside is a blocking `OrtRun`, and that queue is the ONE place this
    /// module allows a blocking ORT call to happen (see
    /// `OrtEnvironment.swift`'s doc comment).
    static func run(bytes: [UInt8], modelPaths: OCRModelPaths, tier: OCRTierConfiguration)
      -> String?
    {
      dispatchPrecondition(condition: .onQueue(OrtEnvironment.shared.queue))
      guard let image = PNGDecoder.decode(bytes) else { return nil }
      guard
        let prepared = ImagePreprocessing.prepareForDetection(
          image, longSide: tier.detectionInputLongSide)
      else { return nil }
      let dictionary = CharacterDictionary.load(path: modelPaths.characterDictionaryPath)
      guard !dictionary.isEmpty else { return nil }

      let recognized = OrtEnvironment.shared.withSessions(modelPaths: modelPaths, tier: tier) {
        sessions in
        recognizedText(image: image, prepared: prepared, sessions: sessions, dictionary: dictionary)
      }
      // `withSessions` itself returns `Result?` (outer `nil` = couldn't get
      // sessions at all); `recognized`'s inner value is ALSO `String?`
      // (nil = no text found) — flattening is correct here, not a bug:
      // both "no sessions" and "sessions but no text" mean the same thing
      // to this pipeline's caller.
      return recognized.flatMap { $0 }
    }

    private static func recognizedText(
      image: RGBAImageBuffer, prepared: ImagePreprocessing.PreparedDetectionInput,
      sessions: OrtSessionSet, dictionary: [String]
    ) -> String? {
      guard
        let detectionOutput = sessions.runDetection(
          inputData: prepared.tensor,
          inputShape: [1, 3, Int64(prepared.paddedHeight), Int64(prepared.paddedWidth)])
      else { return nil }
      guard
        let probabilityMap = TensorReshaping.probabilityMap(
          fromFlat: detectionOutput.data, shape: detectionOutput.shape)
      else { return nil }

      let rawBoxes = DBPostProcess.findTextBoxes(probabilityMap: probabilityMap)
      guard !rawBoxes.isEmpty else { return nil }

      let orderedBoxes = BoxOrdering.sortReadingOrder(
        rawBoxes.map { box -> Quadrilateral in
          let scaled = BoxScaling.scale(
            box, resizedWidth: prepared.resizedWidth, resizedHeight: prepared.resizedHeight,
            toOriginalWidth: image.width, originalHeight: image.height)
          let distance = PolygonUnclip.offsetDistance(
            area: scaled.area, perimeter: scaled.perimeter, ratio: unclipRatio)
          return PolygonUnclip.expand(scaled, distance: distance)
        })

      let lines = orderedBoxes.compactMap {
        recognizeLine(box: $0, image: image, sessions: sessions, dictionary: dictionary)
      }
      guard !lines.isEmpty else { return nil }
      return lines.joined(separator: "\n")
    }

    private static func recognizeLine(
      box: Quadrilateral, image: RGBAImageBuffer, sessions: OrtSessionSet, dictionary: [String]
    ) -> String? {
      let boundingBox = TextLineCropper.boundingBox(
        of: box, imageWidth: image.width, imageHeight: image.height)
      guard let cropped = TextLineCropper.crop(image, boundingBox: boundingBox) else { return nil }
      let lineImage = TextLineCropper.resizedToRecognitionHeight(cropped)

      guard let tensor = recognitionTensor(from: lineImage) else { return nil }
      guard let output = sessions.runRecognition(inputData: tensor.data, inputShape: tensor.shape)
      else { return nil }
      guard
        let logits = TensorReshaping.recognitionLogits(
          fromFlat: output.data, shape: output.shape, batchIndex: 0)
      else { return nil }

      let classIndices = CTCDecoder.argmax(logits: logits)
      let text = CTCDecoder.greedyDecode(classIndices: classIndices, dictionary: dictionary)
      return text.isEmpty ? nil : text
    }

    /// Builds an NCHW batch=1 `Float` tensor from one cropped/resized text
    /// line — same normalization as detection (PP-OCR's published
    /// recognition preprocessing also normalizes against ImageNet
    /// mean/std; see `ImagePreprocessing.normalizationMean/.normalizationStd`'s
    /// own "unverified against this export" caveat, which applies equally
    /// here).
    private static func recognitionTensor(from image: RGBAImageBuffer) -> (
      data: [Float], shape: [Int64]
    )? {
      guard image.width > 0, image.height > 0 else { return nil }
      let planeSize = image.width * image.height
      var tensor = [Float](repeating: 0, count: planeSize * 3)
      for pixelIndex in 0..<planeSize {
        let offset = pixelIndex * RGBAImageBuffer.bytesPerPixel
        let r = Float(image.pixels[offset]) / 255
        let g = Float(image.pixels[offset + 1]) / 255
        let b = Float(image.pixels[offset + 2]) / 255
        tensor[pixelIndex] =
          (r - ImagePreprocessing.normalizationMean.r) / ImagePreprocessing.normalizationStd.r
        tensor[planeSize + pixelIndex] =
          (g - ImagePreprocessing.normalizationMean.g) / ImagePreprocessing.normalizationStd.g
        tensor[2 * planeSize + pixelIndex] =
          (b - ImagePreprocessing.normalizationMean.b) / ImagePreprocessing.normalizationStd.b
      }
      return (data: tensor, shape: [1, 3, Int64(image.height), Int64(image.width)])
    }
  }
#endif
