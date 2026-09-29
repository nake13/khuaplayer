import { useEffect } from "react";

// Keep every rotating word inside the hero at a stable font size. Measuring
// the widest translated line also covers scripts without space-separated words.
export function useFitHeadline(ref, locale) {
  useEffect(() => {
    const title = ref.current;
    if (!title) return;
    const container = title.parentElement;
    let lastWidth = -1;
    let cancelled = false;
    const fit = (force = false) => {
      if (cancelled) return;
      const available = container.clientWidth;
      if (!available || (!force && available === lastWidth)) return;
      lastWidth = available;
      title.style.removeProperty("font-size");
      const natural = Number.parseFloat(getComputedStyle(title).fontSize);
      const probe = title.cloneNode(true);
      probe.removeAttribute("id");
      probe.removeAttribute("data-reveal");
      probe.setAttribute("aria-hidden", "true");
      Object.assign(probe.style, { position: "absolute", visibility: "hidden", pointerEvents: "none", width: "max-content", maxWidth: "none", fontSize: `${natural}px` });
      probe.querySelectorAll(".headline-line").forEach(line => { line.style.whiteSpace = "nowrap"; });
      probe.querySelectorAll(".rotating-word").forEach(word => { word.style.removeProperty("width"); word.classList.remove("is-measured"); });
      container.append(probe);
      const widest = probe.getBoundingClientRect().width;
      probe.remove();
      if (widest > available - 12) title.style.fontSize = `${natural * (available - 12) / widest}px`;
    };
    fit(true);
    const observer = new ResizeObserver(() => fit());
    observer.observe(container);
    document.fonts?.ready.then(() => fit(true)).catch(() => {});
    return () => { cancelled = true; observer.disconnect(); };
  }, [locale, ref]);
}
