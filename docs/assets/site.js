(function () {
  "use strict";
  var root = document.documentElement;
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  var dark = window.matchMedia("(prefers-color-scheme: dark)");

  // Nav background on scroll, hero parallax
  var nav = document.getElementById("nav");
  var par = document.getElementById("parallax");
  var ticking = false;
  function onScroll() {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(function () {
      var y = window.scrollY || 0;
      nav.classList.toggle("scrolled", y > 8);
      if (par && !reduce.matches && y < 1200) par.style.transform = "translate3d(0," + (y * -0.04).toFixed(1) + "px,0)";
      ticking = false;
    });
  }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // Scroll reveal
  var items = document.querySelectorAll(".reveal");
  if (reduce.matches || !("IntersectionObserver" in window)) {
    items.forEach(function (el) { el.classList.add("in"); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
      });
    }, { threshold: 0.12, rootMargin: "0px 0px -6% 0px" });
    items.forEach(function (el) { io.observe(el); });
  }

  // Gallery tabs
  var tabs = Array.prototype.slice.call(document.querySelectorAll('[role="tab"]'));
  function show(tab, focus) {
    tabs.forEach(function (t) {
      var on = t === tab;
      t.setAttribute("aria-selected", on ? "true" : "false");
      t.tabIndex = on ? 0 : -1;
      var p = document.getElementById(t.getAttribute("aria-controls"));
      if (on) { p.hidden = false; p.classList.remove("in"); void p.offsetWidth; p.classList.add("in"); }
      else { p.hidden = true; p.classList.remove("in"); }
    });
    if (focus) tab.focus();
  }
  if (tabs.length) {
    show(tabs[0]);
    tabs.forEach(function (t, i) {
      t.addEventListener("click", function () { show(t); });
      t.addEventListener("keydown", function (e) {
        var n = null;
        if (e.key === "ArrowRight") n = tabs[(i + 1) % tabs.length];
        else if (e.key === "ArrowLeft") n = tabs[(i - 1 + tabs.length) % tabs.length];
        else if (e.key === "Home") n = tabs[0];
        else if (e.key === "End") n = tabs[tabs.length - 1];
        if (n) { e.preventDefault(); show(n, true); }
      });
    });
  }

  // Screenshot appearance toggle (defaults to the system appearance)
  var seg = Array.prototype.slice.call(document.querySelectorAll("[data-shots]"));
  function setShots(v) {
    root.setAttribute("data-shots", v);
    seg.forEach(function (b) { b.setAttribute("aria-pressed", b.getAttribute("data-shots") === v ? "true" : "false"); });
  }
  if (seg.length) {
    setShots(dark.matches ? "dark" : "light");
    seg.forEach(function (b) { b.addEventListener("click", function () { setShots(b.getAttribute("data-shots")); }); });
  }

  // Copy button
  var btn = document.getElementById("copy");
  if (btn) {
    var status = document.getElementById("copy-status");
    btn.addEventListener("click", function () {
      var text = document.getElementById(btn.getAttribute("data-target")).textContent.trim();
      function done(ok) {
        btn.textContent = ok ? "Copied" : "Press Cmd+C";
        status.textContent = ok ? "Command copied to the clipboard." : "Select the command and copy it.";
        setTimeout(function () { btn.textContent = "Copy"; status.textContent = ""; }, 2000);
      }
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(false); });
      } else {
        var r = document.createRange();
        r.selectNodeContents(document.getElementById(btn.getAttribute("data-target")));
        var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
        var ok = false; try { ok = document.execCommand("copy"); } catch (e) {}
        done(ok);
      }
    });
  }
})();
