// AppDelegateSingleInstanceTests.swift
//
// Covers `AppDelegate.otherRunningInstance`, the pure check behind the
// single-instance guard: two copies of Clipnest (an installed one plus a
// build-output .app) used to run side by side and fight over ⌥⌘V/⌥⌘E.

import Foundation
import Testing

@testable import Clipnest

@Suite("AppDelegate.otherRunningInstance")
struct AppDelegateSingleInstanceTests {
  private let bundleID = "com.clipnest.app"

  @Test("Another process with the same bundle ID is reported")
  func detectsSecondCopy() {
    let running: [(bundleID: String?, pid: pid_t)] = [
      (bundleID: "com.apple.finder", pid: 10),
      (bundleID: bundleID, pid: 20),
      (bundleID: bundleID, pid: 30),
    ]
    #expect(
      AppDelegate.otherRunningInstance(bundleID: bundleID, ownPID: 30, running: running) == 20)
  }

  @Test("Only this process running: no other instance")
  func ignoresSelf() {
    let running: [(bundleID: String?, pid: pid_t)] = [
      (bundleID: "com.apple.finder", pid: 10),
      (bundleID: bundleID, pid: 30),
    ]
    #expect(
      AppDelegate.otherRunningInstance(bundleID: bundleID, ownPID: 30, running: running) == nil)
  }

  @Test("No bundle ID (unbundled run): never treats anything as a duplicate")
  func nilBundleIDNeverMatches() {
    let running: [(bundleID: String?, pid: pid_t)] = [(bundleID: nil, pid: 20)]
    #expect(AppDelegate.otherRunningInstance(bundleID: nil, ownPID: 30, running: running) == nil)
  }
}
