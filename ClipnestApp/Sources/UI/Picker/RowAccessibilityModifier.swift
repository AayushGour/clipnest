// RowAccessibilityModifier.swift
//
// T-AUD-VO: the one place that turns a picker row into a single VoiceOver
// element, shared by `ItemRow` and `SnippetRow` (DRY). Rows are
// `.onTapGesture` containers, so without this VoiceOver sees an unlabeled
// group with no actions. The label strings come from `RowAccessibility`
// (ClipnestViewModels, unit-tested); this file only applies them.

import SwiftUI

struct RowAccessibilityModifier: ViewModifier {
  struct NamedAction {
    let name: String
    let perform: () -> Void
  }

  let label: String
  let isSelected: Bool
  /// VoiceOver's default action (VO+Space): the same closure as a click/Return.
  let onDefaultAction: () -> Void
  let actions: [NamedAction]

  func body(content: Content) -> some View {
    content
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(label)
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
      .accessibilityAction(.default, onDefaultAction)
      .accessibilityActions {
        ForEach(actions, id: \.name) { action in
          Button(action.name, action: action.perform)
        }
      }
  }
}
