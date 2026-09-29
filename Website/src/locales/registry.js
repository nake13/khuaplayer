// Keep this set aligned with the app's Localizable.xcstrings catalog.
export const defaultLocale = "en";
export const locales = [
  { code: "en", name: "English", short: "EN" },
  { code: "zh-Hans", name: "简体中文", short: "简中" },
  { code: "zh-Hant", name: "繁體中文", short: "繁中" },
  { code: "ja", name: "日本語", short: "日本語" },
  { code: "ko", name: "한국어", short: "한국어" },
  { code: "de", name: "Deutsch", short: "DE" },
  { code: "fr", name: "Français", short: "FR" },
  { code: "es", name: "Español", short: "ES" },
  { code: "it", name: "Italiano", short: "IT" },
  { code: "pt", name: "Português", short: "PT" },
  { code: "nl", name: "Nederlands", short: "NL" },
  { code: "pl", name: "Polski", short: "PL" },
  { code: "ru", name: "Русский", short: "RU" },
  { code: "tr", name: "Türkçe", short: "TR" },
  { code: "id", name: "Bahasa Indonesia", short: "ID" },
  { code: "vi", name: "Tiếng Việt", short: "VI" },
  { code: "th", name: "ไทย", short: "ไทย" },
];

export function matchLocale(value) {
  if (typeof value !== "string" || value.length > 80) return null;
  let tag;
  try { tag = new Intl.Locale(value.replaceAll("_", "-")); } catch { return null; }
  if (tag.language === "zh") {
    if (tag.script === "Hant") return "zh-Hant";
    if (tag.script === "Hans") return "zh-Hans";
    if (tag.script) return null;
    return ["TW", "HK", "MO"].includes(tag.region) ? "zh-Hant" : "zh-Hans";
  }
  return locales.some(locale => locale.code === tag.language) ? tag.language : null;
}

export function resolveLocaleState({ search = "", saved = null, languages = [], regionLocale = null } = {}) {
  const explicit = matchLocale(new URLSearchParams(search).get("lang"));
  const manual = matchLocale(saved);
  const browser = languages.map(matchLocale).find(Boolean);
  const region = locales.some(item => item.code === regionLocale) ? regionLocale : null;
  const locale = explicit || manual || browser || region || defaultLocale;
  const source = explicit ? "url" : manual ? "manual" : browser ? "browser" : region ? "region" : "default";
  return { locale, source, choice: explicit || manual || "auto", linkLocale: explicit || manual || null };
}

export function resolveLocale(options) {
  return resolveLocaleState(options).locale;
}

export function localeHref(pathname, locale) {
  const url = new URL(pathname, "https://khua.app");
  if (locale === null || locale === "auto") url.searchParams.delete("lang");
  else url.searchParams.set("lang", matchLocale(locale) || defaultLocale);
  return `${url.pathname}${url.search}${url.hash}`;
}

export function localeClass(locale) {
  return `locale-${locale}${locale.startsWith("zh-") ? " locale-zh" : ""}${["zh-Hans", "zh-Hant", "ja", "ko", "th"].includes(locale) ? " locale-native-script" : ""}`;
}
