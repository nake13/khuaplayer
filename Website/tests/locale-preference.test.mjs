import assert from "node:assert/strict";
import test from "node:test";
import { createLocalePreference, fetchRegionLocale, manualLocaleKey, regionHintTimeout } from "../src/locales/preference.js";
import { locales, localeHref, resolveLocaleState } from "../src/locales/registry.js";

const flush = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function host({ url = "https://khua.app/", languages = ["en-US"], saved, legacy, blocked = false } = {}) {
  const target = new EventTarget();
  const storage = new Map();
  if (saved) storage.set(manualLocaleKey, saved);
  if (legacy) storage.set("khua-site-locale", legacy);
  const timers = new Map();
  let timerId = 0;
  target.location = new URL(url);
  target.navigator = { languages, language: languages[0] };
  target.history = { state: { kept: true }, replaceState: (state, title, path) => { target.location = new URL(path, target.location); } };
  target.localStorage = {
    getItem: key => { if (blocked) throw new Error("Storage blocked"); return storage.get(key) ?? null; },
    setItem: (key, value) => { if (blocked) throw new Error("Storage blocked"); storage.set(key, value); },
    removeItem: key => { if (blocked) throw new Error("Storage blocked"); storage.delete(key); },
  };
  target.setTimeout = (callback, delay) => { const id = ++timerId; timers.set(id, { callback, delay }); return id; };
  target.clearTimeout = id => timers.delete(id);
  target.emit = (type, props = {}) => target.dispatchEvent(Object.assign(new Event(type), props));
  target.storage = storage;
  target.timers = timers;
  return target;
}
const noLookup = () => { throw new Error("Unexpected region lookup"); };

test("browser preferences match all 17 languages without persisting or querying location", async () => {
  for (const locale of locales) {
    const browser = host({ languages: ["ar", locale.code, "en"] });
    let queries = 0;
    const preference = createLocalePreference(browser, () => { queries++; return null; });
    const stop = preference.subscribe(() => {});
    await flush();
    assert.equal(preference.getSnapshot().locale, locale.code);
    assert.equal(preference.getSnapshot().choice, "auto");
    assert.equal(preference.getSnapshot().linkLocale, null);
    assert.equal(queries, 0);
    assert.equal(browser.storage.size, 0);
    assert.equal(browser.location.search, "");
    stop();
  }
});

test("legacy guesses never become manual preferences, and auto follows languagechange", () => {
  const browser = host({ legacy: "en", languages: ["ja-JP"] });
  const preference = createLocalePreference(browser, noLookup);
  const stop = preference.subscribe(() => {});
  assert.equal(preference.getSnapshot().locale, "ja");
  browser.navigator.languages = ["zh-HK", "en"];
  browser.emit("languagechange");
  assert.equal(preference.getSnapshot().locale, "zh-Hant");
  assert.equal(browser.storage.get(manualLocaleKey), undefined);
  assert.equal(browser.storage.get("khua-site-locale"), "en");
  stop();
});

test("shared URLs override this visit only, preserving the saved manual preference", () => {
  const browser = host({ saved: "de", url: "https://khua.app/?lang=ja&ref=friend#formats" });
  const preference = createLocalePreference(browser, noLookup);
  const stop = preference.subscribe(() => {});
  assert.equal(preference.getSnapshot().locale, "ja");
  assert.equal(preference.getSnapshot().source, "url");
  assert.equal(browser.storage.get(manualLocaleKey), "de");
  assert.equal(localeHref("/releases", preference.getSnapshot().linkLocale), "/releases?lang=ja");
  browser.location = new URL("https://khua.app/");
  browser.emit("popstate");
  assert.equal(preference.getSnapshot().locale, "de");
  stop();
});

test("manual selection persists without losing query or hash and accepts only languages", () => {
  const browser = host({ url: "https://khua.app/?ref=friend#formats", languages: ["fr-CA"] });
  const preference = createLocalePreference(browser, noLookup);
  const stop = preference.subscribe(() => {});
  preference.choose("ja");
  assert.equal(browser.storage.get(manualLocaleKey), "ja");
  assert.equal(browser.location.search, "?ref=friend&lang=ja");
  browser.navigator.languages = ["ko-KR"];
  browser.emit("languagechange");
  assert.equal(preference.getSnapshot().locale, "ja");
  preference.choose("auto");
  assert.equal(preference.getSnapshot().locale, "ja");
  assert.equal(preference.getSnapshot().choice, "ja");
  assert.equal(browser.storage.get(manualLocaleKey), "ja");
  assert.equal(browser.location.search, "?ref=friend&lang=ja");
  assert.equal(browser.location.hash, "#formats");
  assert.deepEqual(browser.history.state, { kept: true });
  assert.equal(localeHref("/releases?ref=home&lang=ja#latest", null), "/releases?ref=home#latest");
  preference.choose("not-a-language");
  assert.equal(preference.getSnapshot().locale, "ja");
  stop();
});

test("region is a weak fallback below every matched browser preference", () => {
  assert.equal(resolveLocaleState({ languages: ["zh-CN"], regionLocale: "ja" }).locale, "zh-Hans");
  assert.equal(resolveLocaleState({ languages: ["en-US"], regionLocale: "zh-Hans" }).locale, "en");
  assert.equal(resolveLocaleState({ languages: ["ar", "en"], regionLocale: "ja" }).locale, "en");
  assert.equal(resolveLocaleState({ saved: "de", languages: ["ar"], regionLocale: "ja" }).locale, "de");
  assert.equal(resolveLocaleState({ languages: ["ar"], regionLocale: "ja" }).locale, "ja");
  assert.equal(resolveLocaleState({ languages: ["ar"], regionLocale: "xx" }).locale, "en");
  assert.equal(resolveLocaleState({ languages: ["zh-Latn", "en"] }).locale, "en");
});

test("region lookup runs only once, is bounded, and never persists the result", async () => {
  const browser = host({ languages: ["ar"] });
  let queries = 0;
  const preference = createLocalePreference(browser, async () => { queries++; return "ja"; });
  const stop = preference.subscribe(() => {});
  assert.equal(preference.getSnapshot().locale, "en");
  await flush();
  assert.equal(preference.getSnapshot().locale, "ja");
  assert.equal(preference.getSnapshot().source, "region");
  assert.equal(preference.getSnapshot().choice, "auto");
  browser.emit("languagechange");
  assert.equal(queries, 1);
  assert.equal(browser.storage.size, 0);
  assert.equal(browser.timers.size, 0);
  assert.equal(browser.location.search, "");
  stop();
});

test("late region responses cannot override a manual choice or newer browser language", async () => {
  for (const action of ["manual", "browser", "url"]) {
    const browser = host({ languages: ["ar"] });
    const answer = deferred();
    let signal;
    const preference = createLocalePreference(browser, value => { signal = value; return answer.promise; });
    const stop = preference.subscribe(() => {});
    await flush();
    if (action === "manual") preference.choose("fr");
    if (action === "browser") { browser.navigator.languages = ["fr-CA"]; browser.emit("languagechange"); }
    if (action === "url") { browser.location = new URL("https://khua.app/?lang=fr"); browser.emit("popstate"); }
    assert.equal(signal.aborted, true);
    answer.resolve("ja");
    await flush();
    assert.equal(preference.getSnapshot().locale, "fr");
    stop();
  }
});

test("timeout, failure and unknown countries retain English without retries or late jumps", async () => {
  for (const result of ["timeout", "failure", "unknown"]) {
    const browser = host({ languages: ["ar"] });
    const answer = deferred();
    let queries = 0, signal;
    const preference = createLocalePreference(browser, value => { queries++; signal = value; return answer.promise; });
    const stop = preference.subscribe(() => {});
    await flush();
    if (result === "timeout") {
      const timer = [...browser.timers.values()][0];
      assert.equal(timer.delay, regionHintTimeout);
      timer.callback();
      assert.equal(signal.aborted, true);
      answer.resolve("ja");
    } else if (result === "failure") answer.reject(new Error("Offline"));
    else answer.resolve(null);
    await flush();
    browser.emit("languagechange");
    assert.equal(preference.getSnapshot().locale, "en");
    assert.equal(queries, 1);
    stop();
  }
});

test("blocked storage, navigator.language fallback and cross-tab manual changes work", () => {
  const browser = host({ blocked: true, languages: [] });
  browser.navigator.language = "pt-BR";
  const preference = createLocalePreference(browser, noLookup);
  const stop = preference.subscribe(() => {});
  assert.equal(preference.getSnapshot().locale, "pt");
  preference.choose("nl");
  assert.equal(preference.getSnapshot().locale, "nl");
  stop();
  assert.equal(createLocalePreference(browser, noLookup).getSnapshot().locale, "nl");
  browser.location = new URL("https://khua.app/");
  assert.equal(createLocalePreference(browser, noLookup).getSnapshot().locale, "pt");
  const second = host();
  const synced = createLocalePreference(second, noLookup);
  const unsync = synced.subscribe(() => {});
  second.storage.set(manualLocaleKey, "it");
  second.emit("storage", { key: manualLocaleKey });
  assert.equal(synced.getSnapshot().locale, "it");
  second.storage.clear();
  second.emit("storage", { key: null });
  assert.equal(synced.getSnapshot().locale, "en");
  unsync();
});

test("effect cleanup and remount abort old work and detach event listeners", async () => {
  const browser = host({ languages: ["ar"] });
  const first = deferred(), second = deferred();
  const signals = [];
  const preference = createLocalePreference(browser, signal => { signals.push(signal); return signals.length === 1 ? first.promise : second.promise; });
  let updates = 0;
  const stop = preference.subscribe(() => updates++);
  await flush();
  stop();
  assert.equal(signals[0].aborted, true);
  assert.equal(browser.timers.size, 0);
  const stopAgain = preference.subscribe(() => updates++);
  await flush();
  first.resolve("ja");
  await flush();
  assert.equal(preference.getSnapshot().locale, "en");
  second.resolve("de");
  await flush();
  assert.equal(preference.getSnapshot().locale, "de");
  stopAgain();
  const before = updates;
  browser.navigator.languages = ["ja"];
  browser.emit("languagechange");
  assert.equal(updates, before);
});

test("locale client sends no credentials or referrer and validates tiny JSON responses", async () => {
  const abort = new AbortController();
  const fetcher = async (url, options) => {
    assert.equal(url, "/api/locale");
    assert.equal(options.credentials, "omit");
    assert.equal(options.referrerPolicy, "no-referrer");
    assert.equal(options.cache, "no-store");
    assert.equal(options.signal, abort.signal);
    return Response.json({ locale: "ja" });
  };
  assert.equal(await fetchRegionLocale(fetcher, abort.signal), "ja");
  for (const response of [new Response("<html>fallback</html>"), new Response(null, { status: 503 }), Response.json({ locale: "xx" }), Response.json(null)]) {
    assert.equal(await fetchRegionLocale(async () => response, abort.signal), null);
  }
});
