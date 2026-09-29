import { useEffect, useMemo, useRef, useState } from "react";
import {
  ArrowDown,
  ArrowUpRight,
  Crosshair,
  DownloadSimple,
  GithubLogo,
  Pause,
  Play,
} from "@phosphor-icons/react";
import { content } from "./content.js";
import { localeClass, localeHref } from "./locales/registry.js";
import { useLocale, setPageMetadata } from "./useLocale.js";
import { LanguagePicker } from "./LanguagePicker.jsx";
import { useFitHeadline } from "./useFitHeadline.js";
import { ParticleField } from "./ParticleField.jsx";
import { DURATIONS, StarTrail, formatTime } from "./StarTrail.jsx";
import { SubtitleDemo } from "./SubtitleDemo.jsx";
import { QuickLookDemo } from "./QuickLookDemo.jsx";
import { BoostDemos } from "./BoostDemos.jsx";
import { ReleaseBadge } from "./Releases.jsx";
import { repositoryUrl, repositoryIssuesUrl } from "./repository.js";

const REPOSITORY_URL = repositoryUrl;
const DOWNLOAD_URL = import.meta.env.VITE_DOWNLOAD_URL || "/download";
const PRIVACY_URL = "/privacy.txt";
const LICENSE_URL = "/license.txt";

function ExternalLink({ href, className = "", children, label }) {
  return (
    <a aria-label={label} className={className} href={href} rel="noreferrer" target="_blank">
      {children}
    </a>
  );
}

function Eyebrow({ index, children }) {
  return (
    <p className="eyebrow">
      <span aria-hidden="true">{index}</span>
      {children}
    </p>
  );
}

// The accent slot can cycle through words. All words are stacked in one grid cell,
// so the box is measured at its natural width first, then animated to the active
// word's width; that keeps the trailing period tight against the word.
function RotatingWord({ words, paused }) {
  const [index, setIndex] = useState(0);
  const [widths, setWidths] = useState(null);
  const [visible, setVisible] = useState(true);
  const ref = useRef(null);

  useEffect(() => {
    let frame = 0;
    let cancelled = false;
    const measure = () => {
      const node = ref.current;
      if (!node || cancelled) return;
      setWidths(Array.from(node.children).map((el) => Math.ceil(el.getBoundingClientRect().width)));
    };
    // Two passes: drop the width constraint, let the grid size to max-content, then read.
    const remeasure = () => {
      if (cancelled) return;
      setWidths(null);
      if (frame) window.cancelAnimationFrame(frame);
      frame = window.requestAnimationFrame(() => {
        frame = window.requestAnimationFrame(measure);
      });
    };

    remeasure();
    document.fonts?.ready?.then(remeasure).catch(() => {});
    window.addEventListener("resize", remeasure);
    const observer = new ResizeObserver(measure);
    Array.from(ref.current?.children ?? []).forEach(word => observer.observe(word));
    return () => {
      cancelled = true;
      if (frame) window.cancelAnimationFrame(frame);
      window.removeEventListener("resize", remeasure);
      observer.disconnect();
    };
  }, [words]);

  useEffect(() => {
    const node = ref.current;
    if (!node) return undefined;
    const observer = new IntersectionObserver((entries) => setVisible(entries[0].isIntersecting), {
      threshold: 0,
    });
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
  const rotating = !paused && !reduced && visible && words.length > 1;

  useEffect(() => {
    if (!rotating) return undefined;
    const id = window.setInterval(() => setIndex((current) => (current + 1) % words.length), 2900);
    return () => window.clearInterval(id);
  }, [rotating, words.length]);

  useEffect(() => {
    if (paused || reduced) setIndex(0);
  }, [paused, reduced]);

  const previous = (index - 1 + words.length) % words.length;

  return (
    <span
      aria-hidden="true"
      className={`rotating-word ${widths ? "is-measured" : ""}`}
      ref={ref}
      style={widths ? { width: `${widths[index]}px` } : undefined}
    >
      {words.map((word, wordIndex) => (
        <em
          className="accent"
          data-state={
            wordIndex === index ? "current" : wordIndex === previous ? "previous" : "next"
          }
          key={word}
        >
          {word}
        </em>
      ))}
    </span>
  );
}

// Renders "\n" as a hard line break and *word* as the serif accent.
// An accent of "{}" is the rotating slot and consumes the `rotating` word list.
function Headline({ text, rotating, paused }) {
  const lines = text.split("\n");
  return lines.map((line, lineIndex) => {
    const parts = line.split("*");
    return (
      <span className="headline-line" key={lineIndex}>
        {parts.map((part, partIndex) => {
          if (partIndex % 2 === 0) {
            // On narrow screens the run before the rotating slot becomes its own line, so a
            // long word can never add a line and change the headline's height mid-rotation.
            const leadsRotator = rotating?.length > 0 && parts[partIndex + 1] === "{}";
            return (
              <span className={leadsRotator ? "before-rotator" : undefined} key={partIndex}>
                {part}
              </span>
            );
          }
          if (part === "{}" && rotating?.length) {
            return <RotatingWord key={partIndex} paused={paused} words={rotating} />;
          }
          return (
            <em className="accent" key={partIndex}>
              {part}
            </em>
          );
        })}
      </span>
    );
  });
}

// Isometric box: `top` is the y of the top-face centre, `w` the half-width of the
// 2:1 rhombus, `h` the slab height.
function IsoBox({ cx, top, w, h, palette, dashed = false, glow = false }) {
  const d = w / 2;
  const topFace = `${cx},${top - d} ${cx + w},${top} ${cx},${top + d} ${cx - w},${top}`;
  const leftFace = `${cx - w},${top} ${cx},${top + d} ${cx},${top + d + h} ${cx - w},${top + h}`;
  const rightFace = `${cx},${top + d} ${cx + w},${top} ${cx + w},${top + h} ${cx},${top + d + h}`;
  const stroke = dashed ? { strokeDasharray: "5 5" } : null;
  return (
    <g className={`iso-box ${glow ? "iso-glow" : ""}`} style={stroke}>
      <polygon fill={palette[1]} points={leftFace} />
      <polygon fill={palette[2]} points={rightFace} />
      <polygon fill={palette[0]} points={topFace} />
    </g>
  );
}

const FILE_PALETTE = ["#8a9cff", "#4a60e6", "#3446c6"];
const KHUA_PALETTE = ["#7df4ff", "#21c7dd", "#1495a8"];
const BRIDGE_PALETTE = ["#d9dbe3", "#9a9dab", "#6f7280"];
const ZERO_COPY_PALETTE = ["#f2feff", "#9ff6ff", "#4fd9ea"];
const CHIP_PALETTE = ["#2b2b31", "#18181c", "#0f0f12"];

function StackLabel({ x, y, from, text, strong = false, mono = false, accent = false }) {
  return (
    <g className={`stack-label ${strong ? "is-strong" : ""} ${mono ? "is-mono" : ""} ${accent ? "is-accent" : ""}`}>
      <line x1={from} x2={x - 10} y1={y} y2={y} />
      <text x={x} y={y + 6}>
        {text}
      </text>
    </g>
  );
}

// The path a frame takes, top to bottom: the file (a flat card, not a software layer), Khua
// Player, Apple's Metal and VideoToolbox, then the chip. The glowing band marks the zero-copy
// hand-off: decoded frames stay in IOSurface memory the media engine and GPU share.
function LayerStack({ labels }) {
  const cx = 190;
  const w = 150;
  const labelX = cx + w + 44;
  // Leader lines start at the right edge of the slab they describe.
  const edge = cx + w + 6;
  const gap = 30;
  const chipTop = 430;
  const chipH = 34;
  const zeroH = 4;
  const zeroTop = chipTop - gap - zeroH;
  const bridgeH = 10;
  const bridgeTop = zeroTop - gap - bridgeH;
  const layerH = 12;
  const layerTop = bridgeTop - gap - layerH;
  const fileH = 8;
  const fileTop = layerTop - 48 - fileH;
  return (
    <svg
      aria-label={`${labels.file}, ${labels.layer}, ${labels.bridge}, ${labels.zeroCopy}, ${labels.chip}`}
      className="layer-stack"
      role="img"
      viewBox="0 170 700 380"
    >
      <IsoBox cx={cx} h={chipH} palette={CHIP_PALETTE} top={chipTop} w={w} />
      <IsoBox cx={cx} glow h={zeroH} palette={ZERO_COPY_PALETTE} top={zeroTop} w={w} />
      <IsoBox cx={cx} h={bridgeH} palette={BRIDGE_PALETTE} top={bridgeTop} w={w} />
      <IsoBox cx={cx} glow h={layerH} palette={KHUA_PALETTE} top={layerTop} w={w} />
      <IsoBox cx={cx} h={fileH} palette={FILE_PALETTE} top={fileTop} w={w} />
      <StackLabel from={edge} text={labels.file} x={labelX} y={fileTop + fileH / 2} />
      <StackLabel from={edge} strong text={labels.layer} x={labelX} y={layerTop + layerH / 2} />
      <StackLabel from={edge} mono text={labels.bridge} x={labelX} y={bridgeTop + bridgeH / 2} />
      <StackLabel accent from={edge} text={labels.zeroCopy} x={labelX} y={zeroTop + zeroH / 2} />
      <StackLabel from={edge} text={labels.chip} x={labelX} y={chipTop + chipH / 2} />
    </svg>
  );
}

function PipelineDiagram({ diagram }) {
  return (
    <div className="pipeline" data-reveal>
      <p className="pipeline-heading">{diagram.heading}</p>
      <div className="stack-row">
        <figure className="stack-figure" data-parallax="0.05">
          <LayerStack labels={diagram.khua} />
        </figure>
        <p className="pipeline-caption">{diagram.caption}</p>
      </div>
    </div>
  );
}

function RegistrationMark({ className = "", ...rest }) {
  return <Crosshair aria-hidden="true" className={`registration-mark ${className}`} weight="thin" {...rest} />;
}

function BrandIcon({ className = "", eager = false }) {
  return (
    <picture className={`brand-icon ${className}`}>
      <source
        srcSet="/assets/khua-icon-256.webp 256w, /assets/khua-icon-512.webp 512w"
        type="image/webp"
      />
      <img
        alt=""
        decoding="async"
        fetchPriority={eager ? "high" : "auto"}
        loading={eager ? "eager" : "lazy"}
        src="/assets/khua-icon.png"
      />
    </picture>
  );
}

export function App() {
  const [locale, setLocale, language] = useLocale();
  const [motionPaused, setMotionPaused] = useState(() =>
    window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false,
  );
  const [scrollProgress, setScrollProgress] = useState(0);
  const [headerDark, setHeaderDark] = useState(false);
  const [timelineStyle, setTimelineStyle] = useState("starTrail");
  const repairCardRef = useRef(null);
  const repairTimeRef = useRef(null);
  const repairDownloadRef = useRef(null);
  const trailStageRef = useRef(null);
  const trailTimeRef = useRef(null);
  const trailPreviewRef = useRef(null);
  const heroTitleRef = useRef(null);
  useFitHeadline(heroTitleRef, locale);
  const t = useMemo(() => content[locale], [locale]);
  const isChinese = locale.startsWith("zh-");

  useEffect(() => {
    setPageMetadata(t.meta.documentTitle, t.meta.description);
  }, [t.meta.description, t.meta.documentTitle]);

  useEffect(() => {
    const revealItems = document.querySelectorAll("[data-reveal]");
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        });
      },
      { rootMargin: "0px 0px -12%", threshold: 0.08 },
    );

    revealItems.forEach((item) => observer.observe(item));
    return () => observer.disconnect();
  }, [locale]);

  useEffect(() => {
    let frame = 0;
    const updateProgress = () => {
      const scrollRange = document.documentElement.scrollHeight - window.innerHeight;
      setScrollProgress(scrollRange > 0 ? window.scrollY / scrollRange : 0);
      // Match the glass header to the section under its lower edge, which is what the eye
      // reads through it (at the page bottom a sliver of the previous section can sit at the top).
      const probeY = (document.querySelector(".site-header")?.getBoundingClientRect().bottom ?? 76) - 2;
      let dark = false;
      document.querySelectorAll("main > section, footer").forEach((block) => {
        const rect = block.getBoundingClientRect();
        if (rect.top <= probeY && rect.bottom > probeY) {
          dark = block.classList.contains("section-dark")
            || block.classList.contains("section-blue")
            || block.tagName === "FOOTER";
        }
      });
      setHeaderDark(dark);
      frame = 0;
    };
    const onScroll = () => {
      if (!frame) frame = window.requestAnimationFrame(updateProgress);
    };

    updateProgress();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
      if (frame) window.cancelAnimationFrame(frame);
    };
  }, []);

  // Scroll parallax: elements with data-parallax drift at a fraction of scroll speed
  // through the --py custom property. Disabled when motion is paused or reduced.
  useEffect(() => {
    const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    const items = Array.from(document.querySelectorAll("[data-parallax]"));
    const heroCopy = document.querySelector(".hero-copy");
    const clearHero = () => {
      heroCopy?.style.removeProperty("--hero-shift");
      heroCopy?.style.removeProperty("--hero-fade");
    };
    if (motionPaused || reduced || items.length === 0) {
      items.forEach((item) => item.style.removeProperty("--py"));
      clearHero();
      return undefined;
    }

    let frame = 0;
    const update = () => {
      const viewportCenter = window.innerHeight / 2;
      // Hero copy drifts up a little faster than the page and fades over the first
      // 60% of the viewport height of scrolling.
      if (heroCopy) {
        const progress = Math.min(1, Math.max(0, window.scrollY / (window.innerHeight * 0.6)));
        heroCopy.style.setProperty("--hero-shift", `${(-window.scrollY * 0.1).toFixed(1)}px`);
        heroCopy.style.setProperty("--hero-fade", (1 - progress * progress).toFixed(3));
      }
      items.forEach((item) => {
        const speed = Number(item.dataset.parallax) || 0;
        const anchor = item.closest("section") || item;
        const rect = anchor.getBoundingClientRect();
        const anchorCenter = rect.top + rect.height / 2;
        const offset = (viewportCenter - anchorCenter) * speed;
        item.style.setProperty("--py", `${offset.toFixed(1)}px`);
      });
      frame = 0;
    };
    const onScroll = () => {
      if (!frame) frame = window.requestAnimationFrame(update);
    };

    update();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
      if (frame) window.cancelAnimationFrame(frame);
      items.forEach((item) => item.style.removeProperty("--py"));
      clearHero();
    };
  }, [motionPaused, locale]);

  // Pointer tilt on the hero icon, mouse-driven devices only.
  useEffect(() => {
    const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    const finePointer = window.matchMedia?.("(pointer: fine)").matches ?? false;
    const hero = document.getElementById("top");
    const art = hero?.querySelector(".hero-art");
    if (!hero || !art || motionPaused || reduced || !finePointer) return undefined;

    let frame = 0;
    let targetX = 0;
    let targetY = 0;
    const apply = () => {
      art.style.setProperty("--rx", `${targetX.toFixed(2)}deg`);
      art.style.setProperty("--ry", `${targetY.toFixed(2)}deg`);
      frame = 0;
    };
    const onMove = (event) => {
      const rect = hero.getBoundingClientRect();
      const nx = (event.clientX - rect.left) / rect.width - 0.5;
      const ny = (event.clientY - rect.top) / rect.height - 0.5;
      targetX = -ny * 10;
      targetY = nx * 12;
      if (!frame) frame = window.requestAnimationFrame(apply);
    };
    const onLeave = () => {
      targetX = 0;
      targetY = 0;
      if (!frame) frame = window.requestAnimationFrame(apply);
    };

    hero.addEventListener("pointermove", onMove);
    hero.addEventListener("pointerleave", onLeave);
    return () => {
      hero.removeEventListener("pointermove", onMove);
      hero.removeEventListener("pointerleave", onLeave);
      if (frame) window.cancelAnimationFrame(frame);
      art.style.removeProperty("--rx");
      art.style.removeProperty("--ry");
    };
  }, [motionPaused, locale]);

  const motionLabel = motionPaused ? t.ui.playMotion : t.ui.pauseMotion;
  const heroLabel = useMemo(
    () =>
      t.hero.title
        .replace(/\*/g, "")
        .replace("{}", t.hero.rotating?.[0] ?? "")
        .replace(/\n/g, isChinese ? "" : " "),
    [isChinese, t.hero.rotating, t.hero.title],
  );
  const downloadLabel = t.ui.download;

  return (
    <div className={`site-shell ${localeClass(locale)} ${motionPaused ? "motion-paused" : ""}`}>
      <a className="skip-link" href="#main-content">
        {t.ui.skip}
      </a>
      <div aria-hidden="true" className="grain" />
      <div aria-hidden="true" className="scroll-progress">
        <span style={{ transform: `scaleX(${scrollProgress})` }} />
      </div>

      <header className={`site-header ${headerDark ? "is-dark" : ""}`}>
        <a aria-label={t.ui.home} className="wordmark" href="#top">
          <BrandIcon eager />
          <span>{t.nav.brand}</span>
        </a>

        <nav aria-label={t.ui.navigation} className="main-nav">
          {t.nav.links.map((link) => (
            <a href={`#${link.target}`} key={link.target}>
              {link.label}
            </a>
          ))}
        </nav>

        <div className="header-actions">
          <button
            aria-label={motionLabel}
            aria-pressed={motionPaused}
            className="icon-control motion-control"
            onClick={() => setMotionPaused((paused) => !paused)}
            title={motionLabel}
            type="button"
          >
            {motionPaused ? <Play aria-hidden="true" /> : <Pause aria-hidden="true" />}
          </button>
          <LanguagePicker locale={locale} onChange={setLocale} label={t.ui.language} />
          <ExternalLink className="header-download" href={DOWNLOAD_URL} label={downloadLabel}>
            <span>{t.nav.primaryAction}</span>
            <ArrowUpRight aria-hidden="true" />
          </ExternalLink>
        </div>
      </header>

      <main id="main-content">
        <section className="hero-section section-light" id="top">
          <ParticleField dark={false} mode="hero" paused={motionPaused} />
          <RegistrationMark className="hero-registration" data-parallax="0.12" />
          <div className="hero-copy">
            <div className="hero-copy-motion">
              <Eyebrow index="00">{t.hero.eyebrow}</Eyebrow>
              <h1 ref={heroTitleRef} aria-label={heroLabel} data-reveal>
                <Headline key={locale} paused={motionPaused} rotating={t.hero.rotating} text={t.hero.title} />
              </h1>
              <div className="hero-bottom" data-reveal>
                <p>{t.hero.description}</p>
                <div className="button-row">
                  <ExternalLink className="button button-primary" href={DOWNLOAD_URL} label={downloadLabel}>
                    <DownloadSimple aria-hidden="true" />
                    <span>{t.hero.primaryAction}</span>
                  </ExternalLink>
                  <ExternalLink className="text-link" href={REPOSITORY_URL}>
                    <GithubLogo aria-hidden="true" />
                    <span>{t.hero.secondaryAction}</span>
                    <ArrowUpRight aria-hidden="true" />
                  </ExternalLink>
                </div>
                <span className="compatibility">{t.hero.compatibility}</span>
                <ReleaseBadge locale={locale} linkLocale={language.linkLocale} />
              </div>
              </div>

            <div aria-hidden="true" className="hero-art" data-parallax="0.22">
              <BrandIcon eager />
            </div>
          </div>

          <a aria-label={t.ui.discover} className="scroll-cue" href="#performance">
            <span>{t.ui.scroll}</span>
            <ArrowDown aria-hidden="true" />
          </a>
        </section>

        <section className="feature-section performance-section section-dark" id="performance">
          <ParticleField dark mode="silicon" paused={motionPaused} />
          <RegistrationMark className="section-registration" data-parallax="0.1" />
          <div className="feature-grid">
            <div className="feature-heading" data-reveal>
              <Eyebrow index="01">{t.performance.eyebrow}</Eyebrow>
              <h2>
                <Headline text={t.performance.title} />
              </h2>
            </div>
            <div className="feature-copy" data-reveal>
              <p>{t.performance.description}</p>
              <ul className="fact-list">
                {t.performance.facts.map((fact) => (
                  <li key={fact}>{fact}</li>
                ))}
              </ul>
              <span className="fact-note">{t.performance.note}</span>
            </div>
          </div>
          <PipelineDiagram diagram={t.performance.diagram} />
        </section>

        <section className="feature-section resilience-section section-light" id="resilience">
          <ParticleField dark={false} mode="ambient" paused={motionPaused} />
          <div className="feature-grid">
            <div className="feature-heading" data-reveal>
              <Eyebrow index="02">{t.resilience.eyebrow}</Eyebrow>
              <h2>
                <Headline text={t.resilience.title} />
              </h2>
            </div>
            <div className="feature-copy" data-reveal>
              <p>{t.resilience.description}</p>
              <span className="feature-note">{t.resilience.note}</span>
            </div>
          </div>
          <figure className="player-card repair-card" data-reveal data-state="playing" ref={repairCardRef}>
            <div className="player-card-bar">
              <span className="player-file">{t.resilience.demo.fileName}</span>
              <span className="player-download" ref={repairDownloadRef} />
            </div>
            <div className="player-track">
              <span aria-hidden="true" className="player-status">
                <span className="status-chip is-playing">
                  <i />
                  {t.resilience.demo.status.playing}
                </span>
                <span className="status-chip is-waiting">
                  <i />
                  {t.resilience.demo.status.waiting}
                </span>
              </span>
              <StarTrail
                downloadRef={repairDownloadRef}
                downloadText={t.resilience.demo.download}
                label={t.resilience.demo.label}
                paused={motionPaused}
                statusRef={repairCardRef}
                timeRef={repairTimeRef}
                variant="repair"
              />
              <span aria-hidden="true" className="player-time">
                <span ref={repairTimeRef} />
                <span>{formatTime(DURATIONS.repair)}</span>
              </span>
            </div>
            <ul aria-hidden="true" className="timeline-legend">
              {t.resilience.demo.legend.map((item) => (
                <li data-kind={item.key} key={item.key}>
                  <i />
                  {item.label}
                </li>
              ))}
            </ul>
          </figure>
        </section>

        <section className="feature-section boosts-section section-dark" id="boosts">
          <ParticleField dark mode="ambient" paused={motionPaused} />
          <div className="feature-grid">
            <div className="feature-heading" data-reveal>
              <Eyebrow index="03">{t.boosts.eyebrow}</Eyebrow>
              <h2>
                <Headline text={t.boosts.title} />
              </h2>
            </div>
            <div className="feature-copy" data-reveal>
              <p>{t.boosts.description}</p>
            </div>
          </div>
          <BoostDemos boosts={t.boosts} paused={motionPaused} />
        </section>

        <section className="feature-section formats-section section-light" id="formats">
          <ParticleField dark={false} mode="strands" paused={motionPaused} />
          <div className="feature-grid formats-grid">
            <div className="feature-heading" data-reveal>
              <Eyebrow index="04">{t.formats.eyebrow}</Eyebrow>
              <h2>
                <Headline text={t.formats.title} />
              </h2>
            </div>
            <div className="feature-copy" data-reveal>
              <p>{t.formats.description}</p>
            </div>
          </div>
          <ul aria-label={t.ui.formats} className="format-tokens" data-reveal>
            {t.formats.tokens.map((token, index) => (
              <li key={token} style={{ "--i": index }}>
                {token}
              </li>
            ))}
          </ul>
          <RegistrationMark className="formats-registration" data-parallax="-0.08" />
        </section>

        <section className="feature-section subtitles-section section-dark" id="subtitles">
          <ParticleField dark mode="ambient" paused={motionPaused} />
          <RegistrationMark className="section-registration" data-parallax="0.1" />
          <div className="feature-grid">
            <div className="feature-heading" data-reveal>
              <Eyebrow index="05">{t.subtitles.eyebrow}</Eyebrow>
              <h2>
                <Headline text={t.subtitles.title} />
              </h2>
            </div>
            <div className="feature-copy" data-reveal>
              <p>{t.subtitles.description}</p>
              <span className="feature-footnote">{t.subtitles.note}</span>
            </div>
          </div>
          <SubtitleDemo demo={t.subtitles.demo} paused={motionPaused} />
        </section>

        <section className="feature-section quicklook-section section-bright" id="quick-look">
          <ParticleField dark={false} mode="ambient" paused={motionPaused} />
          <div className="feature-grid quicklook-grid">
            <div className="feature-heading" data-reveal>
              <Eyebrow index="06">{t.quickLook.eyebrow}</Eyebrow>
              <h2>
                <Headline text={t.quickLook.title} />
              </h2>
            </div>
            <div className="feature-copy" data-reveal>
              <p>{t.quickLook.description}</p>
            </div>
          </div>
          <QuickLookDemo demo={t.quickLook.demo} />
        </section>

        <section className="feature-section timeline-section section-dark" id="timeline">
          <ParticleField dark mode="ambient" paused={motionPaused} />
          <div className="feature-grid">
            <div className="feature-heading" data-reveal>
              <Eyebrow index="07">{t.timeline.eyebrow}</Eyebrow>
              <h2>
                <Headline text={t.timeline.title} />
              </h2>
            </div>
            <div className="feature-copy" data-reveal>
              <p>{t.timeline.description}</p>
              <span className="fact-note">{t.timeline.note}</span>
            </div>
          </div>
          <div className="trail-stage" data-reveal ref={trailStageRef}>
            <div aria-hidden="true" className="trail-wash" />
            <div className="trail-controls">
              <div aria-label={t.timeline.switchLabel} className="style-switch" role="group">
                {t.timeline.styles.map((item) => (
                  <button
                    aria-pressed={timelineStyle === item.key}
                    key={item.key}
                    onClick={() => setTimelineStyle(item.key)}
                    type="button"
                  >
                    {item.label}
                  </button>
                ))}
              </div>
              <span className="trail-hint">{t.timeline.hint}</span>
            </div>
            <div className="trail-bar">
              <span aria-hidden="true" className="trail-play">
                <Pause weight="fill" />
              </span>
              <span aria-hidden="true" className="trail-time" ref={trailTimeRef} />
              <div className="trail-track">
                <span aria-hidden="true" className="trail-preview" ref={trailPreviewRef}>
                  <span className="trail-preview-frame" />
                  <span className="trail-preview-time" />
                </span>
                <StarTrail
                  label={t.timeline.label}
                  paused={motionPaused}
                  previewRef={trailPreviewRef}
                  timeRef={trailTimeRef}
                  timelineStyle={timelineStyle}
                  variant="film"
                  washRef={trailStageRef}
                />
              </div>
              <span aria-hidden="true" className="trail-time">
                {formatTime(DURATIONS.film)}
              </span>
            </div>
          </div>
        </section>

        <section className="feature-section size-section section-light" id="size">
          <ParticleField dark={false} mode="compact" paused={motionPaused} />
          <div className="feature-grid">
            <div className="feature-heading" data-reveal>
              <Eyebrow index="08">{t.size.eyebrow}</Eyebrow>
              <h2>
                <Headline text={t.size.title} />
              </h2>
            </div>
            <div className="feature-copy" data-reveal>
              <p>{t.size.description}</p>
              <span className="size-note">{t.size.note}</span>
            </div>
          </div>
          <RegistrationMark className="size-registration" data-parallax="0.1" />
        </section>

        <section className="feature-section privacy-section section-blue" id="privacy">
          <ParticleField dark mode="privacy" paused={motionPaused} />
          <div className="feature-grid privacy-grid">
            <div className="feature-heading" data-reveal>
              <Eyebrow index="09">{t.privacy.eyebrow}</Eyebrow>
              <h2>
                <Headline text={t.privacy.title} />
              </h2>
            </div>
            <div className="feature-copy" data-reveal>
              <p>{t.privacy.description}</p>
              <ExternalLink className="text-link text-link-light feature-link" href={PRIVACY_URL}>
                <span>{t.privacy.action} <small lang="en">(English)</small></span>
                <ArrowUpRight aria-hidden="true" />
              </ExternalLink>
            </div>
          </div>
          <RegistrationMark className="section-registration" />
        </section>

        <section className="feature-section open-section section-light" id="open-source">
          <ParticleField dark={false} mode="open" paused={motionPaused} />
          <div className="feature-grid open-grid">
            <div className="feature-heading" data-reveal>
              <Eyebrow index="10">{t.openSource.eyebrow}</Eyebrow>
              <h2>
                <Headline text={t.openSource.title} />
              </h2>
            </div>
            <div className="feature-copy" data-reveal>
              <p>{t.openSource.description}</p>
              <div className="button-row">
                <ExternalLink className="button button-outline" href={REPOSITORY_URL}>
                  <GithubLogo aria-hidden="true" />
                  <span>{t.openSource.action}</span>
                  <ArrowUpRight aria-hidden="true" />
                </ExternalLink>
                <ExternalLink className="text-link" href={repositoryIssuesUrl}>
                  <span>{t.openSource.feedbackAction}</span>
                  <ArrowUpRight aria-hidden="true" />
                </ExternalLink>
              </div>
            </div>
          </div>
          <RegistrationMark className="open-registration" data-parallax="-0.1" />
        </section>

        <section className="details-section section-bright" id="details">
          <ParticleField dark={false} mode="ambient" paused={motionPaused} />
          <div className="details-heading" data-reveal>
            <Eyebrow index="11">{t.details.eyebrow}</Eyebrow>
            <h2>
              <Headline text={t.details.title} />
            </h2>
          </div>
          <ul className="details-grid">
            {t.details.items.map((item, index) => (
              <li data-reveal key={item.title}>
                <span aria-hidden="true" className="detail-index">
                  {String(index + 1).padStart(2, "0")}
                </span>
                <h3>{item.title}</h3>
                <p>{item.description}</p>
              </li>
            ))}
          </ul>
        </section>

        <section className="closing-section section-blue" id="download">
          <ParticleField dark mode="vortex" paused={motionPaused} />
          <div className="closing-art" aria-hidden="true" data-parallax="0.16">
            <BrandIcon />
          </div>
          <div className="closing-content">
            <Eyebrow index="12">{t.closing.eyebrow}</Eyebrow>
            <h2 data-reveal>
              <Headline text={t.closing.title} />
            </h2>
            <p data-reveal>{t.closing.description}</p>
            <div className="button-row closing-buttons" data-reveal>
              <ExternalLink className="button button-light" href={DOWNLOAD_URL} label={downloadLabel}>
                <DownloadSimple aria-hidden="true" />
                <span>{t.closing.primaryAction}</span>
              </ExternalLink>
              <ExternalLink className="text-link text-link-light" href={REPOSITORY_URL}>
                <span>{t.closing.secondaryAction}</span>
                <ArrowUpRight aria-hidden="true" />
              </ExternalLink>
            </div>
          </div>
          <RegistrationMark className="closing-registration" data-parallax="0.12" />
        </section>
      </main>

      <footer className="site-footer">
        <div className="footer-brand">
          <BrandIcon />
          <div>
            <strong>{t.nav.brand}</strong>
            <p>{t.footer.tagline}</p>
          </div>
        </div>
        <div className="footer-meta">
          <span>{t.footer.compatibility}</span>
          <div className="footer-links">
            <a href={localeHref("/releases", language.linkLocale)}>{t.releases.title}</a>
            <ExternalLink href={REPOSITORY_URL}>{t.footer.links.source}</ExternalLink>
            <ExternalLink href={repositoryIssuesUrl}>{t.footer.links.issues}</ExternalLink>
            <ExternalLink href={LICENSE_URL}>{t.footer.links.license} <small lang="en">(English)</small></ExternalLink>
            <ExternalLink href={PRIVACY_URL}>{t.footer.links.privacy} <small lang="en">(English)</small></ExternalLink>
          </div>
        </div>
      </footer>
    </div>
  );
}
