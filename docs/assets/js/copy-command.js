// Copy-to-clipboard buttons for the terminal command cards (.install-card).
//
// Progressive enhancement, deliberately: the buttons are created here in JS and
// never exist in the markup, so a visitor without JS (or without a secure
// context, where navigator.clipboard is undefined) sees the plain, selectable
// command exactly as before rather than a button that silently does nothing.
//
// This is the site's only script. Everything else — the mobile nav, the FAQ
// accordions — is deliberately zero-JS, so keep it that way unless there's a
// reason as good as "a clipboard manager's site should let you copy things".
(function () {
  "use strict";

  // navigator.clipboard is only defined in a secure context (https, or
  // localhost during development). If it's missing there is nothing useful to
  // offer, so add nothing at all.
  if (!navigator.clipboard || !window.matchMedia) return;

  var RESET_MS = 2000;

  function makeButton() {
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "copy-btn";
    btn.setAttribute("aria-label", "Copy command to clipboard");
    btn.innerHTML =
      '<svg class="copy-btn-icon" viewBox="0 0 24 24" fill="none" ' +
      'stroke="currentColor" stroke-width="1.75" stroke-linecap="round" ' +
      'stroke-linejoin="round" aria-hidden="true">' +
      '<rect x="9" y="9" width="11" height="11" rx="2"></rect>' +
      '<path d="M5 15V5a2 2 0 0 1 2-2h8"></path>' +
      "</svg>" +
      '<span class="copy-btn-label">Copy</span>';
    return btn;
  }

  function setState(btn, label, done) {
    btn.querySelector(".copy-btn-label").textContent = label;
    btn.classList.toggle("is-done", !!done);
    // Announce the result to assistive tech. The visible label alone is not
    // announced on click, and aria-label would be read as the button's *name*
    // rather than as a status change.
    btn.setAttribute(
      "aria-label",
      done ? "Command copied to clipboard" : "Copy command to clipboard"
    );
  }

  document.querySelectorAll(".install-card").forEach(function (card) {
    var code = card.querySelector("pre code");
    if (!code) return;

    // textContent, not innerText/innerHTML: Rouge wraps the command in syntax
    // <span>s, and we want the raw command a user would actually paste.
    var command = code.textContent.replace(/\s+$/, "");
    if (!command) return;

    var btn = makeButton();
    var timer = null;

    btn.addEventListener("click", function () {
      navigator.clipboard.writeText(command).then(
        function () {
          setState(btn, "Copied", true);
          window.clearTimeout(timer);
          timer = window.setTimeout(function () {
            setState(btn, "Copy", false);
          }, RESET_MS);
        },
        function () {
          // Permission denied or a transient failure — say so rather than
          // showing "Copied" for something that never reached the clipboard.
          setState(btn, "Press ⌘C", false);
          window.clearTimeout(timer);
          timer = window.setTimeout(function () {
            setState(btn, "Copy", false);
          }, RESET_MS);
        }
      );
    });

    // Appended to the CARD, not the .terminal-bar: the bar is display:flex and
    // kept squeezing the button below its own content width, so the nowrap
    // label spilled outside the button border. Absolutely positioned against
    // the card, no flex sizing can touch it.
    card.classList.add("has-copy");
    card.appendChild(btn);
  });
})();
