// ClipnestApp.swift
//
// App entry point. Declares the menu bar presence (`MenuBarExtra`) that is Clipnest's
// only always-visible UI surface — there is no Dock icon and no main window.
//
// "Open Clipnest" (plan tasks T10–T12) is the menu-driven trigger for the picker
// panel until the global hotkey lands (T27). Later tasks extend this menu further
// (T24 quick menu content, T29 the right-click quick menu with Settings/Pause) —
// don't over-build it here.

import SwiftUI

@main
struct ClipnestApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra {
      Button("Open Clipnest") {
        appDelegate.showPicker()
      }
      Divider()
      Button("Quit") {
        NSApplication.shared.terminate(nil)
      }
    } label: {
      // Clipnest logo (Assets.xcassets/MenuBarIcon), rendered as a monochrome
      // template so the whole mark is a single color (white on a dark menu
      // bar, black on a light one) — no multi-color outline.
      Image("MenuBarIcon")
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 18, height: 18)
    }
    .menuBarExtraStyle(.menu)
  }
}
