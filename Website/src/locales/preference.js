import { locales, localeHref, matchLocale, resolveLocaleState } from "./registry.js";

// The old khua-site-locale key mixed guesses and manual choices. Do not migrate
// it: an inferred language must never become a permanent preference.
export const manualLocaleKey = "khua-site-manual-locale-v1";
export const regionHintTimeout = 1000;

export async function fetchRegionLocale(fetcher, signal) {
  const response = await fetcher("/api/locale", {
    signal, cache: "no-store", credentials: "omit", referrerPolicy: "no-referrer",
    headers: { Accept: "application/json" },
  });
  if (!response.ok || !response.headers.get("content-type")?.includes("application/json")) return null;
  const body = await response.json();
  return locales.some(item => item.code === body?.locale) ? body.locale : null;
}

// One controller per mounted page. No inferred language or location is saved.
// The injected host also lets tests exercise navigation and async races without
// depending on a particular browser, country, or network connection.
export function createLocalePreference(host, lookup = signal => fetchRegionLocale(host.fetch.bind(host), signal)) {
  const readManual = () => {
    try { return matchLocale(host.localStorage.getItem(manualLocaleKey)); }
    catch { return null; }
  };
  let manual = readManual();
  let regionLocale = null;
  let attempted = false;
  let pending = null;
  let notify = null;
  const resolve = () => resolveLocaleState({
    search: host.location.search, saved: manual, regionLocale,
    languages: host.navigator.languages?.length ? host.navigator.languages : [host.navigator.language],
  });
  let state = resolve();

  function cancelPending() {
    if (!pending) return;
    const request = pending;
    pending = null;
    host.clearTimeout(request.timer);
    request.abort.abort();
    attempted = false;
  }

  function refresh() {
    const next = resolve();
    if (next.locale !== state.locale || next.source !== state.source || next.choice !== state.choice) {
      state = next;
      notify?.(state);
    }
    if (state.source !== "default") cancelPending();
    if (!notify || state.source !== "default" || attempted) return;
    attempted = true;
    const request = { abort: new AbortController(), timer: null };
    pending = request;
    request.timer = host.setTimeout(() => {
      if (pending !== request) return;
      pending = null;
      request.abort.abort();
      // Keep English on timeout. Do not retry or switch languages much later.
    }, regionHintTimeout);
    Promise.resolve().then(() => {
      if (pending !== request) return null;
      return lookup(request.abort.signal);
    }).then(locale => {
      if (pending !== request || !notify) return;
      pending = null;
      host.clearTimeout(request.timer);
      regionLocale = locales.some(item => item.code === locale) ? locale : null;
      refresh();
    }).catch(() => {
      if (pending !== request) return;
      pending = null;
      host.clearTimeout(request.timer);
      // A blocked request or offline connection must not affect the page.
    });
  }

  function onStorage(event) {
    if (event.key !== null && event.key !== manualLocaleKey) return;
    manual = readManual();
    refresh();
  }
  function onPageShow(event) {
    if (event.persisted) { manual = readManual(); refresh(); }
  }

  return {
    getSnapshot: () => state,
    subscribe(listener) {
      notify = listener;
      host.addEventListener("languagechange", refresh);
      host.addEventListener("popstate", refresh);
      host.addEventListener("storage", onStorage);
      host.addEventListener("pageshow", onPageShow);
      refresh();
      return () => {
        notify = null;
        cancelPending();
        host.removeEventListener("languagechange", refresh);
        host.removeEventListener("popstate", refresh);
        host.removeEventListener("storage", onStorage);
        host.removeEventListener("pageshow", onPageShow);
      };
    },
    choose(value) {
      const locale = matchLocale(value);
      if (!locale) return;
      manual = locale;
      try {
        host.localStorage.setItem(manualLocaleKey, manual);
      } catch { /* Manual choices still work for this page when storage is blocked. */ }
      const path = host.location.pathname + host.location.search + host.location.hash;
      const next = localeHref(path, manual);
      if (next !== path) host.history.replaceState(host.history.state, "", next);
      refresh();
    },
  };
}
