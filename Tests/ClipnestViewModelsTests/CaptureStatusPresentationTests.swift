import Testing

@testable import ClipnestViewModels

@Suite("CaptureStatusPresentation")
struct CaptureStatusPresentationTests {
  @Test func activeStateIsPlainAppName() {
    let p = CaptureStatusPresentation(isPaused: false)
    #expect(p.accessibilityLabel == "Clipnest")
    #expect(p.tooltipDescription.isEmpty)
  }

  @Test func pausedStateSaysCapturePaused() {
    let p = CaptureStatusPresentation(isPaused: true)
    #expect(p.accessibilityLabel == "Clipnest — capture paused")
    #expect(p.tooltipDescription.contains("paused"))
  }
}
