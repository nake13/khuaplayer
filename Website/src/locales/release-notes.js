import { messages } from "../content.js";

export function releaseNotesFor(release, locale) {
  if (locale === "en") return { lines: release.notes.en, language: "en", fallback: false };
  if (locale === "zh-Hans") return { lines: release.notes.zh, language: locale, fallback: false };
  const translated = messages[locale]?.releaseNotes[release.version];
  const source = messages.en.releaseNotes[release.version];
  // Never attach a stale translation to new or changed, remotely published notes.
  if (translated && JSON.stringify(source) === JSON.stringify(release.notes.en)) {
    return { lines: translated, language: locale, fallback: false };
  }
  return { lines: release.notes.en, language: "en", fallback: true };
}
