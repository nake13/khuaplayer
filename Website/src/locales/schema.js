// Locale files contain only translated copy. Product names, routes, format
// identifiers and illustration filenames remain shared across all languages.
const targets = ["performance", "resilience", "boosts", "formats", "subtitles", "quick-look", "timeline", "privacy", "open-source"];
const formats = ["MKV", "MP4", "MOV", "WebM", "AVI", "MPEG-TS", "FLV", "WMV", "MXF", "HEVC", "H.264", "VVC", "AV1", "ProRes", "DNxHD", "HDR", "4K", "SRT", "ASS", "FLAC", "MP3"];
const originals = ["日が昇る前に出発しよう。", "北の道なら、まだ通れるはずだ。", "じゃあ、急がないと。"];

export function expandMessages(m, locale) {
  const motion = m.boosts.motion;
  const brightness = m.boosts.brightness;
  const turbo = m.boosts.turbo;
  return {
    meta: { languageName: locale.name, documentTitle: m.meta.title, description: m.meta.description },
    nav: { brand: "Khua Player", links: m.nav.map((label, index) => ({ label, target: targets[index] })), primaryAction: m.download },
    hero: { ...m.hero, primaryAction: m.hero.download, secondaryAction: m.github, compatibility: m.compatibility },
    performance: { ...m.performance, eyebrow: m.nav[0], diagram: { heading: m.performance.diagram.heading, caption: m.performance.diagram.caption, khua: { file: m.performance.diagram.file, layer: "Khua Player", bridge: "Metal · VideoToolbox", zeroCopy: m.performance.diagram.zeroCopy, chip: "Apple silicon" } } },
    boosts: { ...m.boosts, eyebrow: m.nav[2],
      motion: { title: "Motion+", description: motion.description, note: motion.note, demo: motion },
      brightness: { title: "Brightness+", description: brightness.description, note: brightness.note, demo: { ...brightness, after: "Brightness+" } },
      turbo: { title: "Turbo", description: turbo.description, demo: turbo },
    },
    resilience: { ...m.resilience, eyebrow: m.nav[1], demo: { label: m.resilience.label, fileName: "kyoto-by-night.mkv", download: { progress: m.resilience.progress, done: m.resilience.done }, status: { playing: m.resilience.playing, waiting: m.resilience.waiting }, legend: m.resilience.legend.map((label, i) => ({ key: ["partial", "unavailable", "pending"][i], label })) } },
    subtitles: { ...m.subtitles, demo: { label: m.subtitles.label, status: m.subtitles.status, cues: m.subtitles.cues.map((translation, i) => ({ translation, original: locale.code === "ja" ? ["Let's head out before sunrise.", "The road north should still be open.", "Then we'd better hurry."][i] : originals[i] })) } },
    formats: { ...m.formats, eyebrow: m.nav[3], tokens: formats },
    timeline: { ...m.timeline, eyebrow: m.nav[6], styles: m.timeline.styles.map((label, i) => ({ key: ["starTrail", "liquid", "classic"][i], label })) },
    quickLook: { ...m.quickLook, eyebrow: m.nav[5], demo: { ...m.quickLook, sidebarTitle: m.quickLook.favorites, files: ["kyoto-by-night.mkv", "summer-trip.mp4", "concert-2025.mkv", "lecture-07.webm", "first-snow.mov", "old-tapes.avi"] } },
    size: m.size,
    privacy: { ...m.privacy, eyebrow: m.nav[7] },
    openSource: { ...m.openSource, eyebrow: m.nav[8], feedbackAction: m.footer.issues },
    details: { ...m.details, items: m.details.items.map(([title, description]) => ({ title, description })) },
    closing: { ...m.closing, primaryAction: m.closing.download, secondaryAction: m.github },
    footer: { tagline: m.footer.tagline, compatibility: m.compatibility, links: { source: "GitHub", issues: m.footer.issues, license: m.footer.license, privacy: m.footer.privacy } },
    ui: m.ui, releases: m.releases, releaseNotes: m.releaseNotes,
  };
}
