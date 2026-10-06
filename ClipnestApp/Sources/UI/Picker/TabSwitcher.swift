// TabSwitcher.swift
//
// Plan task T23: the segmented control that switches between the picker's
// tabs — History (unchanged from T11), Pinned (pinned items only, same
// `pinnedAt`-ascending order as History's pinned group), and Snippets
// (user-authored text snippets, T22/T23). The "+  New Snippet" trigger lives
// in `PickerView.swift` (only relevant on the Snippets tab), not here — this
// file is purely the tab switcher itself, per its own name.
//
// P5 (Phase 3, Linux port): the tab model itself, `PickerTab`, moved to
// `ClipnestViewModels/UI/Picker/PickerTab.swift` — `PickerViewModel.activeTab`
// needs it and `PickerViewModel` is now shared cross-platform, while this
// `View` stays macOS/SwiftUI-only. Pure code motion of the enum; this file
// just imports it now instead of declaring it locally.

import ClipnestViewModels
import SwiftUI

/// A minimal segmented control for switching `PickerTab`s by click.
/// `PickerView` wires `⌘1`/`⌘2`/`⌘3` to the same `selection` binding via
/// its existing `.onKeyPress` handler, so keyboard and click stay in sync
/// through one source of truth.
struct TabSwitcher: View {
  @Binding var selection: PickerTab

  var body: some View {
    HStack(spacing: 4) {
      ForEach(PickerTab.allCases) { tab in
        Button {
          selection = tab
        } label: {
          Text(tab.title)
            .font(.caption)
            .fontWeight(selection == tab ? .semibold : .regular)
            .foregroundStyle(selection == tab ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
              RoundedRectangle(cornerRadius: 6)
                .fill(selection == tab ? Color.secondary.opacity(0.2) : Color.clear)
            }
        }
        .buttonStyle(.plain)
      }
    }
  }
}
