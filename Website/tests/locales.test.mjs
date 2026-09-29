import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { content, messages } from "../src/content.js";
import { locales, matchLocale, resolveLocale, localeHref, localeClass } from "../src/locales/registry.js";
import { releaseNotesFor } from "../src/locales/release-notes.js";

function leaves(value, path = "") {
  return Object.fromEntries(Object.entries(value).flatMap(([key, child]) => {
    const next = path ? `${path}.${key}` : key;
    return typeof child === "string" ? [[next, child]] : Object.entries(leaves(child, next));
  }));
}
const source = leaves(messages.en);
const placeholders = text => [...text.matchAll(/\{[^{}]*\}/g)].map(match => match[0]).sort();

test("website languages exactly match the app catalog", async () => {
  const app = JSON.parse(await readFile(new URL("../../Apps/Mac/Resources/Localizable.xcstrings", import.meta.url), "utf8"));
  const supported = [...new Set([app.sourceLanguage, ...Object.values(app.strings).flatMap(entry => Object.keys(entry.localizations ?? {}))])].sort();
  assert.deepEqual(locales.map(locale => locale.code).sort(), supported);
  assert.deepEqual(Object.keys(messages).sort(), supported);
  assert.equal(new Set(locales.map(locale => locale.code)).size, locales.length);
});

for (const locale of locales) {
  test(`${locale.code}: complete, translated copy and valid placeholders`, () => {
    const m = messages[locale.code];
    const strings = leaves(m);
    assert.deepEqual(Object.keys(strings).sort(), Object.keys(source).sort());
    for (const [key, value] of Object.entries(strings)) {
      assert.ok(value.trim().length, `${key} must not be blank`);
      assert.deepEqual(placeholders(value), placeholders(source[key]), `Placeholders in ${key}`);
      assert.doesNotMatch(value, /\bTODO\b/, key);
      if (key.endsWith(".title") && source[key].includes("*")) {
        assert.equal((value.match(/\*/g) ?? []).length, 2, `One headline accent in ${key}`);
      }
      if (locale.code !== "en" && key.endsWith(".description")) assert.notEqual(value, source[key], `Untranslated paragraph: ${key}`);
    }
    assert.equal(m.hero.rotating.length, 5);
    assert.match(m.hero.title, /\*\{\}\*/);
    assert.equal(new Set(m.hero.rotating).size, 5);
    assert.match(m.boosts.motion.note, /macOS 26/);
    assert.match(m.boosts.motion.note, /4K/);
    assert.match(m.boosts.motion.note, /1×|1倍速|1배속/);
    assert.match(m.subtitles.note, /macOS 26/);
    assert.match(m.compatibility, /macOS 14/);
    assert.equal(content[locale.code].nav.brand, "Khua Player");
    assert.deepEqual(content[locale.code].nav.links.map(link => link.target), content.en.nav.links.map(link => link.target));
    assert.deepEqual(content[locale.code].formats.tokens, content.en.formats.tokens);
    assert.doesNotThrow(() => new Intl.DateTimeFormat(locale.code).format(new Date("2026-09-28T00:00:00Z")));
    assert.doesNotThrow(() => new Intl.NumberFormat(locale.code).format(12.4));
  });
}

test("locale matching handles saved preferences, regions and Chinese scripts", () => {
  for (const [input, expected] of Object.entries({ zh:"zh-Hans", "zh-CN":"zh-Hans", "zh-SG":"zh-Hans", "zh-TW":"zh-Hant", "zh-HK":"zh-Hant", "zh-MO":"zh-Hant", "zh-Hans-HK":"zh-Hans", "zh-Hant-CN":"zh-Hant", "pt-BR":"pt", "pt-PT":"pt", "fr_CA":"fr", "en-GB":"en" })) assert.equal(matchLocale(input), expected);
  for (const bad of [null, "", "xx", "<script>", "../../en", "en " , "a".repeat(200)]) assert.equal(matchLocale(bad), null);
  assert.equal(resolveLocale({ search:"?lang=ja", saved:"de", languages:["fr-FR"] }), "ja");
  assert.equal(resolveLocale({ search:"?lang=unknown", saved:"zh", languages:["ja"] }), "zh-Hans");
  assert.equal(resolveLocale({ languages:["ar", "zh-TW", "en"] }), "zh-Hant");
  assert.equal(resolveLocale({ languages:["ar", "he"] }), "en");
  assert.equal(resolveLocale(), "en");
});

test("localized internal links retain path, query and anchor", () => {
  assert.equal(localeHref("/releases?ref=home#v0.6.1", "ja"), "/releases?ref=home&lang=ja#v0.6.1");
  assert.equal(localeHref("/?lang=en#subtitles", "zh-HK"), "/?lang=zh-Hant#subtitles");
  assert.equal(localeHref("/", "not-supported"), "/?lang=en");
  assert.match(localeClass("zh-Hant"), /locale-zh /);
  assert.match(localeClass("th"), /locale-native-script/);
});

test("all published release notes have matching, complete local translations", async () => {
  for (const [version, lines] of Object.entries(messages.en.releaseNotes)) {
    const official = JSON.parse(await readFile(new URL(`../../Distribution/notes/${version}.json`, import.meta.url), "utf8"));
    assert.deepEqual(lines, official.en);
    assert.deepEqual(messages["zh-Hans"].releaseNotes[version], official.zh);
    for (const locale of locales) {
      const result = releaseNotesFor({ version, notes: official }, locale.code);
      assert.equal(result.fallback, false, `${locale.code} ${version}`);
      assert.equal(result.language, locale.code);
      assert.equal(result.lines.length, official.en.length);
    }
  }
});

test("new or changed release notes fall back visibly without stale translations", () => {
  const notes = { en: ["A newly published change"], zh: ["新发布的变更"] };
  for (const version of ["0.7.0", "0.6.1"]) {
    const release = { version, notes };
    assert.deepEqual(releaseNotesFor(release, "ja"), { lines: notes.en, language:"en", fallback:true });
    assert.deepEqual(releaseNotesFor(release, "en"), { lines: notes.en, language:"en", fallback:false });
    assert.deepEqual(releaseNotesFor(release, "zh-Hans"), { lines: notes.zh, language:"zh-Hans", fallback:false });
  }
});
