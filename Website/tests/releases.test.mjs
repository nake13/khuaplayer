import assert from "node:assert/strict";
import test from "node:test";
import { artifactKey, parseCatalog, parseRelease, renderAppcast } from "../cloudflare/catalog.ts";
import worker from "../cloudflare/index.ts";
import { localeFromCountry } from "../cloudflare/locale.ts";

const release = {
  version: "0.6.0", build: 10, releasedAt: "2026-09-28T00:00:00Z",
  minimumSystemVersion: "14.0", architecture: "arm64", sizeBytes: 123,
  sha256: "a".repeat(64), signature: "A".repeat(86) + "==", automaticUpdates: true,
  notes: { en: ["Signed <updates> & downloads"], zh: ["签名更新"] },
};
release.url = `https://downloads.khua.app/${artifactKey(release)}`;
const catalog = {
  schemaVersion: 1, channel: "stable", latestBuild: 10,
  appcastKey: `feeds/stable/${"b".repeat(64)}.xml`, releases: [release],
};
const feed = "signed XML bytes\n";
const env = {
  RELEASES: {
    get: async (key) => key === "channels/stable.json"
      ? { size: 2000, json: async () => structuredClone(catalog) }
      : key === catalog.appcastKey ? { body: feed, httpEtag: '"etag"' } : null,
    head: async () => ({ httpEtag: '"etag"' }),
  },
  ASSETS: { fetch: async () => new Response("site") },
};

test("locale hints use only trusted country metadata and never require storage bindings", async () => {
  for (const [country, locale] of Object.entries({ CN: "zh-Hans", TW: "zh-Hant", HK: "zh-Hant", JP: "ja", BR: "pt", SG: null, CA: null, CH: null, BE: null, T1: null, XX: null })) {
    const request = new Request("https://khua.app/api/locale?country=DE", { headers: { "CF-IPCountry": "FR", "X-Forwarded-For": "192.0.2.1" } });
    Object.defineProperty(request, "cf", { value: { country } });
    const response = await worker.fetch(request, {});
    assert.deepEqual(await response.json(), { locale });
    assert.match(response.headers.get("cache-control"), /private.*no-store/);
    assert.equal(response.headers.get("cdn-cache-control"), "no-store");
    assert.equal(response.headers.get("cross-origin-resource-policy"), "same-origin");
    assert.equal(response.headers.get("access-control-allow-origin"), null);
  }
  for (const country of [undefined, null, "", "__proto__", "constructor", {}, "JP,FR"]) assert.equal(localeFromCountry(country), null);
  assert.deepEqual(await (await worker.fetch(new Request("https://khua.app/api/locale"), {})).json(), { locale: null });
  assert.equal(await (await worker.fetch(new Request("https://khua.app/api/locale", { method: "HEAD" }), {})).text(), "");
  assert.equal((await worker.fetch(new Request("https://khua.app/api/locale", { method: "POST" }), {})).status, 405);
});

test("catalog validates its latest identity and strips private metadata", () => {
  const result = parseCatalog({ ...catalog, privatePath: "/private/not-public" });
  assert.equal(result.latestBuild, 10);
  assert.equal(result.privatePath, undefined);
  for (const changed of [
    { latestBuild: 9 }, { releases: [release, release] }, { channel: "beta" },
    { appcastKey: "../private.xml" }, { releases: [] },
  ]) assert.throws(() => parseCatalog({ ...catalog, ...changed }));
});

test("rejects untrusted downloads, invalid hashes and incomplete metadata", () => {
  for (const changed of [
    { url: "https://evil.test/payload.dmg" }, { sha256: "invalid" },
    { build: -1 }, { signature: "" }, { architecture: "unknown" },
    { releasedAt: "not-a-date" }, { notes: { en: [], zh: [] } },
  ]) assert.throws(() => parseRelease({ ...release, ...changed }));
});

test("appcast escapes text, declares arm64, and excludes inactive legacy builds", () => {
  const xml = renderAppcast([release, { ...release, build: 9, automaticUpdates: false }]);
  assert.equal((xml.match(/<item>/g) || []).length, 1);
  assert.match(xml, /Signed &lt;updates&gt; &amp; downloads/);
  assert.match(xml, /<sparkle:hardwareRequirements>arm64/);
  assert.match(xml, /<sparkle:version>10/);
});

test("website and download redirect use the same current release without caching", async () => {
  const metadata = await worker.fetch(new Request("https://khua.app/api/releases.json"), env);
  assert.equal((await metadata.json()).latestBuild, 10);
  const response = await worker.fetch(new Request("https://khua.app/download"), env);
  assert.equal(response.status, 302);
  assert.equal(response.headers.get("location"), release.url);
  assert.match(response.headers.get("cache-control"), /no-store/);
});

test("serves the original signed feed bytes and bodyless HEAD requests", async () => {
  const response = await worker.fetch(new Request("https://khua.app/updates/appcast.xml"), env);
  assert.equal(await response.text(), feed);
  assert.match(response.headers.get("content-type"), /application\/rss\+xml/);
  for (const path of ["/updates/appcast.xml", "/api/releases.json", "/download"]) {
    const head = await worker.fetch(new Request(`https://khua.app${path}`, { method: "HEAD" }), env);
    assert.equal(await head.text(), "");
  }
});

test("missing releases fail closed and API/write paths never serve the SPA", async () => {
  const missing = { ...env, RELEASES: { get: async () => null } };
  assert.equal((await worker.fetch(new Request("https://khua.app/download"), missing)).status, 404);
  assert.equal((await worker.fetch(new Request("https://khua.app/api/unknown", { headers: { accept: "text/html" } }), env)).status, 404);
  assert.equal((await worker.fetch(new Request("https://khua.app/download", { method: "POST" }), env)).status, 405);
  assert.equal(await (await worker.fetch(new Request("https://khua.app/"), env)).text(), "site");
});

test("malformed catalogs, oversized catalogs and missing feeds fail closed", async () => {
  for (const broken of [
    { get: async () => ({ size: 600000, json: async () => catalog }) },
    { get: async () => ({ size: 10, json: async () => ({}) }) },
    { get: async (key) => key === "channels/stable.json" ? { size: 2000, json: async () => catalog } : null },
  ]) {
    const response = await worker.fetch(new Request("https://khua.app/updates/appcast.xml"), { ...env, RELEASES: broken });
    assert.equal(response.status, 503);
    assert.match(response.headers.get("cache-control"), /no-store/);
  }
});
