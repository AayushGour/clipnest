// Home page demo carousel (.demo-carousel in pages/index.md).
//
// Progressive enhancement: without JS every demo is shown stacked, each with
// its own caption, and the first one plays on its own (autoplay/muted/loop are
// plain HTML attributes). With JS it becomes a tab carousel: one demo at a
// time, the active clip plays through once and then the next tab takes over.
//
// Videos other than the active one are never downloaded until their tab is
// opened (preload="none" in the markup), so the page stays light.
(function () {
  "use strict";

  var carousel = document.querySelector(".demo-carousel");
  if (!carousel) return;

  var tabs = Array.prototype.slice.call(carousel.querySelectorAll(".demo-tab"));
  var slides = Array.prototype.slice.call(carousel.querySelectorAll(".demo-slide"));
  if (!tabs.length || tabs.length !== slides.length) return;

  // Respect reduced motion: no autoplay or auto-advance, show native controls.
  var reduceMotion =
    window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  // Once the visitor picks a tab themselves, stop advancing on their behalf.
  var autoAdvance = !reduceMotion;
  var current = 0;

  carousel.classList.add("is-enhanced");

  function videoOf(i) {
    return slides[i].querySelector("video");
  }

  function show(i, focusTab) {
    current = i;
    tabs.forEach(function (tab, j) {
      var active = j === i;
      tab.setAttribute("aria-selected", active ? "true" : "false");
      tab.tabIndex = active ? 0 : -1;
      slides[j].hidden = !active;
      var v = videoOf(j);
      if (!v) return;
      if (active) {
        v.currentTime = 0;
        if (reduceMotion) {
          v.controls = true;
        } else {
          var p = v.play();
          if (p && p.catch) p.catch(function () { v.controls = true; });
        }
      } else {
        v.pause();
      }
    });
    if (focusTab) tabs[i].focus();
  }

  slides.forEach(function (slide, i) {
    var v = videoOf(i);
    if (!v) return;
    // Play each clip once, then hand over to the next demo.
    v.loop = false;
    v.removeAttribute("autoplay");
    v.addEventListener("ended", function () {
      if (i !== current) return;
      if (autoAdvance) {
        show((i + 1) % slides.length, false);
      } else {
        v.currentTime = 0;
        v.play();
      }
    });
  });

  tabs.forEach(function (tab, i) {
    tab.addEventListener("click", function () {
      autoAdvance = false;
      show(i, false);
    });
    tab.addEventListener("keydown", function (e) {
      var next = null;
      if (e.key === "ArrowRight") next = (i + 1) % tabs.length;
      else if (e.key === "ArrowLeft") next = (i - 1 + tabs.length) % tabs.length;
      else if (e.key === "Home") next = 0;
      else if (e.key === "End") next = tabs.length - 1;
      if (next === null) return;
      e.preventDefault();
      autoAdvance = false;
      show(next, true);
    });
  });

  // Don't burn CPU or data on a clip nobody can see.
  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      var v = videoOf(current);
      if (!v || reduceMotion) return;
      if (entries[0].isIntersecting) v.play().catch(function () {});
      else v.pause();
    }, { threshold: 0.25 }).observe(carousel);
  }

  show(0, false);
})();
