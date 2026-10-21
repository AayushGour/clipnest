// WelcomeView.swift
//
// T-WELCOME1: the macOS first-run welcome window body (design.md "Welcome
// window"). Pure rendering: every string comes from `WelcomeCopy` /
// `WelcomeViewModel` / `WelcomeAccessibilityPresentation` (shared with Linux)
// and every button forwards to the view model or `WelcomeSession`. System
// semantic colors only (light/dark), no animation (satisfies Reduce Motion).

import ClipnestViewModels
import SwiftUI

struct WelcomeView: View {
  @ObservedObject var session: WelcomeSession
  @ObservedObject var viewModel: WelcomeViewModel
  let onClose: () -> Void
  /// Only a `View` can read this; handed to the session on demand.
  @Environment(\.openSettings) private var openSettings

  /// Initial keyboard focus goes to step 1's primary action - "Allow
  /// Accessibility…" while permission is missing, else the footer Continue
  /// button - never Skip (design.md "Welcome window").
  private enum FocusTarget: Hashable {
    case allowAction
    case launchAtLoginToggle
    case primaryButton
    case secondaryButton
  }

  @FocusState private var focus: FocusTarget?

  /// Window size from the spec (520 x ~420 pt).
  static let windowSize = CGSize(width: 520, height: 420)

  private enum Layout {
    static let iconSize: CGFloat = 48
    static let badgeSize: CGFloat = 24
    static let rowSpacing: CGFloat = 6
    static let padding: CGFloat = 20
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      // Scrolls only if the expanded step overflows (e.g. step 1 while
      // waiting on System Settings, with the stale-entry guidance).
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
          permissionRow
          openAtLoginRow
          tryItRow
        }
        .padding(Layout.padding)
      }
      .scrollBounceBehavior(.basedOnSize)
      Divider()
      footer
    }
    .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    .onAppear { refocus() }
    // Granting flips the active step and hides "Allow Accessibility…": move
    // focus to the primary button instead of leaving it on nothing.
    .onChange(of: viewModel.activeStep) { refocus() }
    // "Set up later" swaps the footer to Go back / Set up later anyway.
    .onChange(of: viewModel.isConfirmingSetUpLater) { refocus() }
    .onChange(of: session.accessibilityState) {
      // Only the permission step's own button can vanish here; on later steps a grant
      // must not pull focus off whatever the user tabbed to.
      if viewModel.activeStep == .permission, focus != .primaryButton { refocus() }
    }
  }

  private func refocus() {
    let actionAvailable =
      WelcomeAccessibilityPresentation.content(for: session.accessibilityState).actionTitle != nil
    switch viewModel.focusTarget(permissionActionAvailable: actionAvailable) {
    case .permissionAction: focus = .allowAction
    case .launchAtLoginToggle: focus = .launchAtLoginToggle
    case .primaryButton: focus = .primaryButton
    case .secondaryButton: focus = .secondaryButton
    }
  }

  // MARK: Header / footer

  private var header: some View {
    HStack(spacing: 12) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: Layout.iconSize, height: Layout.iconSize)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(WelcomeCopy.windowTitle).font(.title2.bold())
        Text(WelcomeCopy.subtitle).font(.callout).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(Layout.padding)
  }

  private var footer: some View {
    HStack {
      // Low emphasis on purpose: plain style, never the default action or
      // initial focus (T-WELCOMEGRANT1).
      if viewModel.showsSecondary {
        Button(viewModel.secondaryTitle) {
          if viewModel.skipTapped() == .close { onClose() }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .focused($focus, equals: .secondaryButton)
      }
      Spacer()
      Button(viewModel.primaryTitle) {
        if viewModel.continueTapped() == .close { onClose() }
      }
      .keyboardShortcut(.defaultAction)
      .focused($focus, equals: .primaryButton)
      .disabled(!viewModel.isPrimaryEnabled)
    }
    .padding(Layout.padding)
  }

  // MARK: Rows

  private var permissionRow: some View {
    let content = WelcomeAccessibilityPresentation.content(for: session.accessibilityState)
    return StepRow(viewModel: viewModel, step: .permission) {
      EmptyView()
    } detail: {
      Text(viewModel.permissionBodyText).fixedSize(horizontal: false, vertical: true)
      if let warning = viewModel.setUpLaterConfirmationText {
        Text(warning).font(.callout).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      statusLine(
        viewModel.state(of: .permission) == .skipped
          && session.accessibilityState != .allowed
          ? WelcomeCopy.permissionSkippedStatus : content.statusText)
      if let stale = content.staleGuidance {
        Text(stale).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } actions: {
      if let title = content.actionTitle {
        Button(title) { session.performAccessibilityAction() }
          .accessibilityHint(content.actionHint ?? "")
          .focused($focus, equals: .allowAction)
      }
    }
  }

  private var openAtLoginRow: some View {
    StepRow(viewModel: viewModel, step: .openAtLogin) {
      EmptyView()
    } detail: {
      Text(viewModel.openAtLoginBodyText).fixedSize(horizontal: false, vertical: true)
      Toggle(
        WelcomeCopy.openAtLoginToggleTitle,
        isOn: Binding(
          get: { viewModel.wantsLaunchAtLogin },
          set: { viewModel.setWantsLaunchAtLogin($0) })
      )
      .focused($focus, equals: .launchAtLoginToggle)
      Text(WelcomeCopy.openAtLoginRecommended).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let error = viewModel.launchAtLoginError {
        Text(error).font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    } actions: {
      EmptyView()
    }
  }

  private var tryItRow: some View {
    StepRow(viewModel: viewModel, step: .tryIt) {
      EmptyView()
    } detail: {
      Text(viewModel.tryItBodyText).fixedSize(horizontal: false, vertical: true)
      if viewModel.hotkey.isBound {
        KeyCapsView(hotkey: viewModel.hotkey)
        statusLine(viewModel.tryItStatusText)
      }
      if viewModel.showsTryItHint, !viewModel.hasDetectedHotkey {
        Text(viewModel.tryItHintText).font(.caption).foregroundStyle(.secondary)
      }
    } actions: {
      Button(WelcomeCopy.changeInSettingsTitle) {
        session.openShortcutsSettings(using: { openSettings() })
      }
    }
  }

  private func statusLine(_ text: String) -> some View {
    Text(text).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
  }
}

// MARK: - Step row

/// One of the three stacked rows: badge + heading (+ trailing accessory), the
/// detail body while the step is active, and its action buttons. The whole row
/// is one accessibility group "Step N of 3: heading, state".
private struct StepRow<Accessory: View, Detail: View, Actions: View>: View {
  @ObservedObject var viewModel: WelcomeViewModel
  let step: WelcomeStep
  @ViewBuilder let accessory: () -> Accessory
  @ViewBuilder let detail: () -> Detail
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    let state = viewModel.state(of: step)
    // Expansion follows the ACTIVE step (step 3 stays open after success).
    let isActive = viewModel.activeStep == step
    HStack(alignment: .top, spacing: 12) {
      StepBadge(number: step.number, state: state)
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text(step.heading).font(isActive ? .headline : .body.weight(.medium))
          accessory()
        }
        if isActive {
          detail()
          // Actions only on the active row (design.md tab order / height).
          actions()
        } else if let status = viewModel.collapsedStatusText(for: step) {
          // A collapsed row still says where it stands (B1).
          Text(status).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(viewModel.collapsedStatusAccessibilityText(for: step) ?? status)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(8)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(isActive ? Color.secondary.opacity(0.5) : Color.clear)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(viewModel.accessibilityLabel(for: step))
  }
}

private struct StepBadge: View {
  let number: Int
  let state: WelcomeStepState

  var body: some View {
    Group {
      switch state {
      case .done:
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
          .accessibilityLabel(WelcomeCopy.doneBadgeLabel)
      case .skipped:
        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
          .accessibilityLabel(WelcomeCopy.skippedBadgeLabel)
      case .current, .upcoming:
        Image(systemName: "\(number).circle.fill")
          .foregroundStyle(state == .current ? Color.accentColor : Color.secondary)
          .accessibilityHidden(true)
      }
    }
    .font(.system(size: 20))
    .frame(width: 24, height: 24)
  }
}

// MARK: - Key caps

/// The hotkey as individual key caps. One accessibility element reading the
/// spoken form ("Option Command V"); the glyph subviews are hidden from AT.
private struct KeyCapsView: View {
  let hotkey: WelcomeHotkey

  var body: some View {
    HStack(spacing: 4) {
      ForEach(Array(hotkey.keyCaps.enumerated()), id: \.offset) { _, cap in
        Text(cap.label)
          .font(.system(.body, design: .rounded).weight(.medium))
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(
            RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor))
          )
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary))
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(hotkey.spokenText ?? "")
    // Hide the glyph text ("⌥⌘V") that .ignore would otherwise surface as the value.
    .accessibilityValue("")
  }
}
