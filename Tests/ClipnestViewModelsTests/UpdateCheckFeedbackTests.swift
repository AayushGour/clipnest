import Testing

@testable import ClipnestViewModels

struct UpdateCheckFeedbackTests {
  @Test func upToDateNamesInstalledVersion() {
    let feedback = UpdateCheckFeedback(outcome: .upToDate(installed: "1.4.0"))
    #expect(feedback.title == "You're up to date (1.4.0)")
    #expect(!feedback.offersUpdate)
  }

  @Test func availableOffersUpdate() {
    let feedback = UpdateCheckFeedback(outcome: .updateAvailable(latest: "1.5.0"))
    #expect(feedback.title.contains("1.5.0"))
    #expect(feedback.offersUpdate)
  }

  @Test func failureOffersNothing() {
    let feedback = UpdateCheckFeedback(outcome: .failed)
    #expect(feedback.title == "Couldn't check for updates")
    #expect(!feedback.offersUpdate)
  }
}
