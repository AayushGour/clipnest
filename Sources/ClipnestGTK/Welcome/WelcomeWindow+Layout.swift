// WelcomeWindow+Layout.swift
//
// T-WELCOME1-LX: widget construction and `render()` for `WelcomeWindow`. No
// hardcoded colors (default theme semantics); emphasis is structural (the
// current row is expanded, others collapse to heading + status).
import CGtk4
import ClipnestViewModels

struct StepRowWidgets {
  let frame: OpaquePointer
  let badge: OpaquePointer
  let summary: OpaquePointer
  let details: OpaquePointer
}

struct SubRowWidgets {
  let container: OpaquePointer
  let status: OpaquePointer
  let detail: OpaquePointer
  let button: OpaquePointer
}

/// Step 1: permission.
struct PermissionStepWidgets {
  let body: OpaquePointer
  let plainLine: OpaquePointer
  let keyboard: SubRowWidgets
  let keyboardSecurityNote: OpaquePointer
  let keyboardReloginNote: OpaquePointer
  let extensionRow: SubRowWidgets
  let extensionFallbackNote: OpaquePointer
  let combinedLine: OpaquePointer
  /// T-WELCOMEGRANT1: what will not work, shown while confirming "Set up later".
  let setUpLaterWarning: OpaquePointer
}

/// Step 2: open at login (body, switch, recommendation note, error).
struct OpenAtLoginStepWidgets {
  let body: OpaquePointer
  let toggle: OpaquePointer
  let note: OpaquePointer
  let error: OpaquePointer
}

/// Step 3: try your hotkey (body, key caps, status, hint, Change in Settings…).
struct TryItStepWidgets {
  let body: OpaquePointer
  let keyCaps: OpaquePointer
  let status: OpaquePointer
  let hint: OpaquePointer
  let changeButton: OpaquePointer
}

/// Linux last-step alternative: log out to finish setup (body only; the
/// buttons are the footer's).
struct LogOutStepWidgets {
  let body: OpaquePointer
}

extension WelcomeWindow {
  // MARK: - Small widget helpers

  func makeLabel(
    _ text: String = "", wrap: Bool = true, cssClasses: [String] = [], bold: Bool = false
  ) -> OpaquePointer {
    let label: OpaquePointer = gtk_label_new(nil)
    gtk_label_set_xalign(label, 0)
    if wrap {
      gtk_label_set_wrap(label, 1)
      gtk_label_set_max_width_chars(label, WelcomeWindow.wrapWidthChars)
    }
    if bold {
      gtk_label_set_markup(label, "<b>\(PangoMarkup.escape(text))</b>")
    } else {
      gtk_label_set_text(label, text)
    }
    for css in cssClasses { gtk_widget_add_css_class(label, css) }
    return label
  }

  func makeBox(_ orientation: GtkOrientation, spacing: Int32 = WelcomeWindow.rowSpacing)
    -> OpaquePointer
  {
    gtk_box_new(orientation, spacing)
  }

  func makeButton(_ title: String, onClicked: @escaping @MainActor () -> Void) -> OpaquePointer {
    let button: OpaquePointer = gtk_button_new_with_label(title)
    gtkConnect(
      button, signal: "clicked",
      context: ClosureContext<Void> { MainActor.assumeIsolated { onClicked() } },
      callback: unsafeBitCast(welcomeButtonClickedTrampoline, to: GCallback.self))
    return button
  }

  func setText(_ label: OpaquePointer, _ text: String?) {
    let visible = !(text ?? "").isEmpty
    if visible { gtk_label_set_text(label, text ?? "") }
    gtk_widget_set_visible(label, visible ? 1 : 0)
  }

  func setVisible(_ widget: OpaquePointer, _ visible: Bool) {
    gtk_widget_set_visible(widget, visible ? 1 : 0)
  }

  // MARK: - Build

  @MainActor
  func buildWindow() {
    gtk_window_set_title(window, WelcomeCopy.windowTitle)
    gtk_window_set_default_size(window, WelcomeWindow.windowWidth, WelcomeWindow.windowHeight)
    gtk_window_set_resizable(window, 0)
    // Not modal and not transient: the user may need other apps to press the
    // hotkey or finish a step.

    let root = makeBox(GTK_ORIENTATION_VERTICAL, spacing: WelcomeWindow.spacing)
    gtk_widget_set_margin_start(root, WelcomeWindow.margin)
    gtk_widget_set_margin_end(root, WelcomeWindow.margin)
    gtk_widget_set_margin_top(root, WelcomeWindow.margin)
    gtk_widget_set_margin_bottom(root, WelcomeWindow.margin)

    gtk_box_append(root, buildHeader())
    // The step list scrolls instead of growing the window: with step 1
    // expanded the content is taller than a 768 px screen allows. Natural
    // height is NOT propagated, so the window stays near the spec's ~420 px.
    let steps = makeBox(GTK_ORIENTATION_VERTICAL, spacing: WelcomeWindow.spacing)
    for step in WelcomeStep.allCases { gtk_box_append(steps, buildRow(for: step)) }
    let scroller: OpaquePointer = gtk_scrolled_window_new()
    gtk_scrolled_window_set_policy(scroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    gtk_scrolled_window_set_min_content_height(scroller, WelcomeWindow.stepListHeight)
    gtk_scrolled_window_set_propagate_natural_height(scroller, 0)
    gtk_scrolled_window_set_child(scroller, steps)
    gtk_widget_set_vexpand(scroller, 1)
    stepScroller = scroller
    gtk_box_append(root, scroller)
    gtk_box_append(root, buildFooter())
    gtk_window_set_child(window, root)

    // Return = primary. Initial focus is set in present() (step 1's action).
    gtk_window_set_default_widget(window, primaryButton)

    connectSignals()
  }

  private func buildHeader() -> OpaquePointer {
    let header = makeBox(GTK_ORIENTATION_HORIZONTAL, spacing: WelcomeWindow.spacing)
    let icon: OpaquePointer = gtk_image_new_from_icon_name(WelcomeWindow.iconName)
    gtk_image_set_pixel_size(icon, WelcomeWindow.iconPixelSize)
    // Decorative: the title next to it carries the meaning.
    GTKAccessibility.setHidden(icon, true)
    gtk_box_append(header, icon)

    let text = makeBox(GTK_ORIENTATION_VERTICAL, spacing: 2)
    gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
    gtk_box_append(text, makeLabel(WelcomeCopy.windowTitle, wrap: false, cssClasses: ["title-2"]))
    gtk_box_append(text, makeLabel(WelcomeCopy.subtitle, cssClasses: ["dim-label"]))
    gtk_box_append(header, text)
    return header
  }

  private func buildRow(for step: WelcomeStep) -> OpaquePointer {
    let frame = gtk_frame_new()
    let content = makeBox(GTK_ORIENTATION_VERTICAL)
    gtk_widget_set_margin_start(content, WelcomeWindow.rowMargin)
    gtk_widget_set_margin_end(content, WelcomeWindow.rowMargin)
    gtk_widget_set_margin_top(content, WelcomeWindow.rowMargin)
    gtk_widget_set_margin_bottom(content, WelcomeWindow.rowMargin)

    let titleLine = makeBox(GTK_ORIENTATION_HORIZONTAL, spacing: WelcomeWindow.spacing)
    let badge = makeLabel("", wrap: false, cssClasses: ["heading"])
    gtk_label_set_width_chars(badge, 2)
    gtk_box_append(titleLine, badge)
    gtk_box_append(titleLine, makeLabel(step.heading, wrap: false, bold: true))
    gtk_box_append(content, titleLine)

    let summary = makeLabel("", cssClasses: ["dim-label"])
    gtk_widget_set_margin_start(summary, 30)
    gtk_box_append(content, summary)

    let details = makeBox(GTK_ORIENTATION_VERTICAL)
    gtk_widget_set_margin_start(details, 30)
    switch step {
    case .permission: buildPermissionStep(into: details)
    case .openAtLogin: buildOpenAtLoginStep(into: details)
    case .tryIt: buildTryItStep(into: details)
    case .logOut: buildLogOutStep(into: details)
    }
    gtk_box_append(content, details)
    gtk_frame_set_child(frame, content)

    rows[step] = StepRowWidgets(frame: frame, badge: badge, summary: summary, details: details)
    return frame
  }

  private func buildSubRow(
    title: String, buttonAction: @escaping @MainActor () -> Void
  ) -> SubRowWidgets {
    let container = makeBox(GTK_ORIENTATION_VERTICAL, spacing: 4)
    gtk_widget_set_margin_top(container, 4)
    gtk_box_append(container, makeLabel(title, wrap: false, bold: true))
    let status = makeLabel()
    let detail = makeLabel(cssClasses: ["dim-label"])
    let button = makeButton("", onClicked: buttonAction)
    gtk_widget_set_halign(button, GTK_ALIGN_START)
    for widget in [status, detail, button] { gtk_box_append(container, widget) }
    return SubRowWidgets(container: container, status: status, detail: detail, button: button)
  }

  private func buildPermissionStep(into box: OpaquePointer) {
    let body = makeLabel()
    let plain = makeLabel(cssClasses: ["dim-label"])
    let keyboard = buildSubRow(title: WelcomeKeyboardAccess.sectionTitle) { [weak self] in
      self?.grantTapped()
    }
    let security = makeLabel(LinuxInputPermissionCopy.securityExplanationText)
    let relogin = makeLabel(LinuxInputPermissionCopy.reloginText)
    // Notes sit between the status line and the button, so the user reads the
    // security claim and the log-out requirement before the polkit dialog.
    gtk_box_insert_child_after(keyboard.container, security, keyboard.status)
    gtk_box_insert_child_after(keyboard.container, relogin, security)

    let extensionRow = buildSubRow(title: WelcomeGnomeExtensionPresentation.sectionTitle) {
      [weak self] in
      if let action = self?.currentExtensionAction { self?.extensionActionTapped(action) }
    }
    let fallback = makeLabel(cssClasses: ["dim-label"])
    gtk_box_append(extensionRow.container, fallback)
    let combined = makeLabel(WelcomeLinuxPermission.completionAnnouncement, bold: true)
    let warning = makeLabel(cssClasses: ["warning"])
    for widget in [body, warning, plain, keyboard.container, extensionRow.container, combined] {
      gtk_box_append(box, widget)
    }
    permissionStep = PermissionStepWidgets(
      body: body, plainLine: plain, keyboard: keyboard, keyboardSecurityNote: security,
      keyboardReloginNote: relogin, extensionRow: extensionRow, extensionFallbackNote: fallback,
      combinedLine: combined, setUpLaterWarning: warning)
  }

  private func buildOpenAtLoginStep(into box: OpaquePointer) {
    let body = makeLabel()
    let toggle: OpaquePointer = gtk_check_button_new_with_label(WelcomeCopy.openAtLoginToggleTitle)
    let onToggled: @MainActor (Bool) -> Void = { [weak self] isOn in
      self?.launchAtLoginToggled(isOn)
    }
    gtkConnect(
      toggle, signal: "toggled",
      context: ClosureContext<Bool> { isOn in MainActor.assumeIsolated { onToggled(isOn) } },
      callback: unsafeBitCast(welcomeToggleTrampoline, to: GCallback.self))
    let note = makeLabel(WelcomeCopy.openAtLoginRecommended, cssClasses: ["dim-label"])
    let error = makeLabel(cssClasses: ["error"])
    for widget in [body, toggle, note, error] { gtk_box_append(box, widget) }
    openAtLoginStep = OpenAtLoginStepWidgets(body: body, toggle: toggle, note: note, error: error)
  }

  private func buildTryItStep(into box: OpaquePointer) {
    let body = makeLabel()
    let caps = makeBox(GTK_ORIENTATION_HORIZONTAL, spacing: 4)
    let status = makeLabel(bold: true)
    let hint = makeLabel(cssClasses: ["dim-label"])
    let change = makeButton(WelcomeCopy.changeInSettingsTitle) { [weak self] in
      self?.changeInSettingsTapped()
    }
    gtk_widget_set_halign(change, GTK_ALIGN_START)
    for widget in [body, caps, status, hint, change] { gtk_box_append(box, widget) }
    tryItStep = TryItStepWidgets(
      body: body, keyCaps: caps, status: status, hint: hint, changeButton: change)
  }

  private func buildLogOutStep(into box: OpaquePointer) {
    let body = makeLabel()
    gtk_box_append(box, body)
    logOutStep = LogOutStepWidgets(body: body)
  }

  private func buildFooter() -> OpaquePointer {
    let footer = makeBox(GTK_ORIENTATION_HORIZONTAL, spacing: WelcomeWindow.spacing)
    skipButton = makeButton(WelcomeCopy.skipTitle) { [weak self] in self?.skipTapped() }
    // Low emphasis: flat, never the default widget or initial focus.
    gtk_widget_add_css_class(skipButton, "flat")
    primaryButton = makeButton(WelcomeCopy.continueTitle) { [weak self] in self?.primaryTapped() }
    gtk_widget_add_css_class(primaryButton, "suggested-action")
    gtk_widget_set_hexpand(skipButton, 0)
    let spacer = makeBox(GTK_ORIENTATION_HORIZONTAL)
    gtk_widget_set_hexpand(spacer, 1)
    gtk_box_append(footer, skipButton)
    gtk_box_append(footer, spacer)
    gtk_box_append(footer, primaryButton)
    return footer
  }

  private func connectSignals() {
    gtkConnect(
      window, signal: "close-request", context: self,
      callback: unsafeBitCast(welcomeCloseRequestTrampoline, to: GCallback.self))
    gtkConnect(
      window, signal: "notify::is-active", context: self,
      callback: unsafeBitCast(welcomeActiveChangedTrampoline, to: GCallback.self))
    let controller: OpaquePointer = gtk_event_controller_key_new()
    gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE)
    gtkConnect(
      controller, signal: "key-pressed", context: self,
      callback: unsafeBitCast(welcomeKeyPressedTrampoline, to: GCallback.self))
    gtk_widget_add_controller(window, controller)
  }

  // MARK: - Render

  var currentExtensionAction: WelcomeGnomeExtensionPresentation.Action? {
    permission.extensionContent.action
  }

  @MainActor
  func render() {
    guard !isDismissed else { return }
    viewModel.updatePermission(
      isComplete: permission.isComplete,
      announcement: WelcomeLinuxPermission.completionAnnouncement)
    viewModel.setHotkeyPendingSetup(permission.isHotkeyPendingSetup)
    // A grant that needs a new login swaps "Try your hotkey" for the log-out step.
    viewModel.setNeedsRelogin(
      permission.keyboard.needsRelogin || permission.extensionContent.needsRelogin)

    for step in WelcomeStep.allCases { renderRow(step) }
    if renderedActiveStep != viewModel.activeStep {
      // A newly active step starts at its top, not wherever the last one was scrolled.
      renderedActiveStep = viewModel.activeStep
      if let stepScroller {
        gtk_adjustment_set_value(gtk_scrolled_window_get_vadjustment(stepScroller), 0)
      }
    }
    renderPermissionStep()
    renderOpenAtLoginStep()
    renderTryItStep()
    gtk_label_set_text(logOutStep.body, viewModel.logOutBodyText)

    gtk_button_set_label(primaryButton, viewModel.primaryTitle)
    gtk_widget_set_sensitive(primaryButton, viewModel.isPrimaryEnabled ? 1 : 0)
    gtk_button_set_label(skipButton, viewModel.secondaryTitle)
    setVisible(skipButton, viewModel.showsSecondary)
    refocusIfNeeded()
    if let announcement = viewModel.announcement {
      announce(announcement)
      viewModel.clearAnnouncement()
    }
    startHintTimerIfNeeded()
  }

  /// Focus never lands on nothing: when the step changed or the focused action
  /// button vanished (granted, or its row hidden), move to the right target.
  @MainActor
  private func refocusIfNeeded() {
    guard hasPresented else { return }
    // Hiding a widget unmaps it (and GTK drops focus from it), so "not mapped"
    // is the reliable "that button went away" signal, unlike the visible flag
    // of a child inside a hidden row.
    let focusedActionHidden = focusedWidget.map { gtk_widget_get_mapped($0) == 0 } ?? false
    let stepChanged = lastFocusedStep != viewModel.activeStep
    let confirmChanged = lastFocusedConfirming != viewModel.isConfirmingSetUpLater
    guard stepChanged || confirmChanged || focusedActionHidden else { return }
    lastFocusedStep = viewModel.activeStep
    lastFocusedConfirming = viewModel.isConfirmingSetUpLater
    let target = focusWidget
    focusedWidget = target
    gtk_window_set_focus(window, target)
  }

  @MainActor
  private func renderRow(_ step: WelcomeStep) {
    guard let row = rows[step] else { return }
    // The two last-step rows share one slot: only the live one is on the list.
    setVisible(row.frame, viewModel.steps.contains(step))
    let state = viewModel.state(of: step)
    gtk_label_set_text(row.badge, WelcomeStepBadge.text(for: state, number: step.number))
    GTKAccessibility.setLabel(row.badge, WelcomeStepBadge.accessibleLabel(for: state) ?? "")
    GTKAccessibility.setLabel(row.frame, viewModel.accessibilityLabel(for: step))
    setVisible(row.details, state == .current)
    let summary = WelcomeRowSummary.text(
      step: step, state: state, hotkeyText: viewModel.hotkey.displayText,
      permissionSummary: permission.collapsedSummary(isSkipped: state == .skipped),
      tryItStatus: viewModel.tryItStatusText,
      openAtLoginStatus: viewModel.collapsedStatusText(for: .openAtLogin),
      logOutStatus: viewModel.collapsedStatusText(for: .logOut))
    setText(row.summary, summary)
  }

  @MainActor
  private func renderOpenAtLoginStep() {
    gtk_label_set_text(openAtLoginStep.body, viewModel.openAtLoginBodyText)
    // Syncing the widget fires "toggled" -> launchAtLoginToggled, which is a
    // no-op when the model already agrees (no render loop).
    let active = gtk_check_button_get_active(openAtLoginStep.toggle) != 0
    if active != viewModel.wantsLaunchAtLogin {
      gtk_check_button_set_active(openAtLoginStep.toggle, viewModel.wantsLaunchAtLogin ? 1 : 0)
    }
    setText(openAtLoginStep.error, viewModel.launchAtLoginError)
  }

  @MainActor
  private func renderPermissionStep() {
    gtk_label_set_text(permissionStep.body, viewModel.permissionBodyText)
    setText(permissionStep.setUpLaterWarning, viewModel.setUpLaterConfirmationText)
    let keyboard = permission.keyboard
    let content = permission.extensionContent

    // Sub-row A
    setText(permissionStep.keyboard.status, keyboard.statusText)
    setText(permissionStep.keyboard.detail, nil)
    setVisible(permissionStep.keyboardSecurityNote, keyboard.showsUpFrontNotes)
    setVisible(permissionStep.keyboardReloginNote, keyboard.showsUpFrontNotes)
    if let title = keyboard.buttonTitle {
      gtk_button_set_label(permissionStep.keyboard.button, title)
      gtk_widget_set_sensitive(permissionStep.keyboard.button, keyboard.isButtonEnabled ? 1 : 0)
    }
    setVisible(permissionStep.keyboard.button, keyboard.buttonTitle != nil)

    // Sub-row B (hidden on non-GNOME; a plain line replaces it)
    setVisible(permissionStep.extensionRow.container, !content.isRowHidden)
    setText(permissionStep.plainLine, content.plainLine)
    setText(
      permissionStep.extensionRow.status,
      content.showsCheck
        ? WelcomeStepBadge.doneGlyph + " " + content.statusText : content.statusText)
    setText(permissionStep.extensionRow.detail, content.detail)
    setText(permissionStep.extensionFallbackNote, content.fallbackNote)
    if let action = content.action {
      gtk_button_set_label(permissionStep.extensionRow.button, action.title)
    }
    setVisible(permissionStep.extensionRow.button, content.action != nil)

    // One combined log-out line when both sub-rows end in a log-out state.
    setText(permissionStep.combinedLine, permission.combinedReloginLine)
  }

  @MainActor
  private func renderTryItStep() {
    gtk_label_set_text(tryItStep.body, viewModel.tryItBodyText)
    // An unbound hotkey has nothing to detect: no waiting status in that case.
    setText(tryItStep.status, viewModel.hotkey.isBound ? viewModel.tryItStatusText : nil)
    setText(
      tryItStep.hint,
      viewModel.showsTryItHint && !viewModel.hasDetectedHotkey ? viewModel.tryItHintText : nil)
    if renderedHotkey != viewModel.hotkey {
      renderedHotkey = viewModel.hotkey
      var child = gtk_widget_get_first_child(tryItStep.keyCaps)
      while let widget = child {
        child = gtk_widget_get_next_sibling(widget)
        gtk_box_remove(tryItStep.keyCaps, widget)
      }
      for cap in viewModel.hotkey.keyCaps {
        let frame = gtk_frame_new()
        let label = makeLabel(cap.label, wrap: false)
        gtk_widget_set_margin_start(label, WelcomeWindow.keyCapPadding)
        gtk_widget_set_margin_end(label, WelcomeWindow.keyCapPadding)
        gtk_frame_set_child(frame, label)
        // The body sentence already spells the hotkey out in words.
        GTKAccessibility.setHidden(frame, true)
        gtk_box_append(tryItStep.keyCaps, frame)
      }
    }
    setVisible(tryItStep.keyCaps, viewModel.hotkey.isBound)
  }
}

// MARK: - Trampolines

private let welcomeButtonClickedTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      guard let context = unretainedContext(data, as: ClosureContext<Void>.self) else { return }
      context.perform(())
    }

private let welcomeToggleTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { button, data in
      guard let button, let context = unretainedContext(data, as: ClosureContext<Bool>.self) else {
        return
      }
      context.perform(gtk_check_button_get_active(button) != 0)
    }

private let welcomeCloseRequestTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Int32 = { _, data in
      guard let window = unretainedContext(data, as: WelcomeWindow.self) else { return 0 }
      return MainActor.assumeIsolated { window.closeRequested() }
    }

private let welcomeActiveChangedTrampoline:
  @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, _, data in
      guard let window = unretainedContext(data, as: WelcomeWindow.self) else { return }
      MainActor.assumeIsolated { window.windowActiveChanged() }
    }

private let welcomeKeyPressedTrampoline:
  @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) ->
    Int32 = { _, keyval, _, state, data in
      guard let window = unretainedContext(data, as: WelcomeWindow.self) else { return 0 }
      return MainActor.assumeIsolated { window.keyPressed(keyval: keyval, state: state) }
    }
