import { useEffect, useState } from "react";
import { parseCatalog } from "../cloudflare/catalog.ts";
import { repositoryUrl, repositoryIssuesUrl } from "./repository.js";
import { content } from "./content.js";
import { localeClass, localeHref } from "./locales/registry.js";
import { releaseNotesFor } from "./locales/release-notes.js";
import { useLocale, setPageMetadata } from "./useLocale.js";
import { LanguagePicker } from "./LanguagePicker.jsx";
import "./releases.css";

function useReleases() {
  const [state, setState] = useState({ catalog: null, error: false });
  useEffect(() => {
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 12000);
    fetch("/api/releases.json", { signal: controller.signal, cache: "no-store" })
      .then((response) => {
        if (!response.ok) throw new Error("Release information unavailable");
        return response.json();
      })
      .then((value) => setState({ catalog: parseCatalog(value), error: false }))
      .catch(() => setState({ catalog: null, error: true }))
      .finally(() => window.clearTimeout(timeout));
    return () => { controller.abort(); window.clearTimeout(timeout); };
  }, []);
  return state;
}

export function ReleaseBadge({ locale, linkLocale }) {
  const { catalog } = useReleases();
  const latest = catalog?.releases[0];
  return (
    <a className="release-badge" href={localeHref("/releases", linkLocale)}>
      {latest ? `v${latest.version} · ` : ""}{content[locale].releases.title}
    </a>
  );
}

export function Releases() {
  const [locale, setLocale, language] = useLocale();
  const { catalog, error } = useReleases();
  const t = content[locale];
  const r = t.releases;
  useEffect(() => {
    setPageMetadata(`${r.title} — Khua Player`, r.intro);
  }, [r.title, r.intro]);
  return (
    <div className={`releases-page ${localeClass(locale)}`}>
      <header className="releases-header">
        <a href={localeHref("/", language.linkLocale)} className="wordmark"><img src="/assets/khua-icon-32.png" alt="" width="32" height="32" />Khua Player</a>
        <LanguagePicker locale={locale} onChange={setLocale} label={t.ui.language} />
      </header>
      <main className="releases-main">
        <p className="eyebrow">Khua Player / macOS</p>
        <h1>{r.title}</h1>
        <p className="releases-intro">{r.intro}</p>
        <p className="releases-note">{r.note}</p>
        {!catalog && <p role="status">{error ? r.error : r.loading}</p>}
        {catalog?.releases.map((release, index) => {
          const notes = releaseNotesFor(release, locale);
          return (
          <article className="release-entry" key={release.build}>
            <div className="release-title"><h2>{release.version}</h2>{index === 0 && <span className="release-latest">{r.latest}</span>}</div>
            <p className="release-meta">
              {new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeZone: "UTC" }).format(new Date(release.releasedAt))}
              {` · ${r.build} ${release.build} · macOS ${release.minimumSystemVersion}+ · Apple silicon · ${new Intl.NumberFormat(locale, { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(release.sizeBytes / 1000000)} MB`}
            </p>
            {notes.fallback && <p className="releases-note">{r.englishNotes}</p>}
            <ul className="release-notes" lang={notes.language}>{notes.lines.map((note) => <li key={note}>{note}</li>)}</ul>
            <a className="button button-primary" href={release.url}>{t.closing.primaryAction} {release.version}</a>
            <details className="release-checksum"><summary>SHA-256</summary><code>{release.sha256}</code></details>
          </article>
        ); })}
      </main>
      <footer className="releases-bottom">
        <a href={localeHref("/", language.linkLocale)}>{r.back}</a>
        <a href={repositoryUrl} target="_blank" rel="noreferrer">{r.source}</a>
        <a href={repositoryIssuesUrl} target="_blank" rel="noreferrer">{t.footer.links.issues}</a>
      </footer>
    </div>
  );
}
