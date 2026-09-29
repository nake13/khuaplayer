// A deliberately small fallback map, not a claim about a visitor's language.
// Multilingual or unlisted regions (including SG, CA, BE and CH), unknown
// locations and anonymizing networks return no suggestion.
const countryLocales: Readonly<Record<string, string>> = Object.freeze({
  CN: "zh-Hans", TW: "zh-Hant", HK: "zh-Hant", MO: "zh-Hant",
  JP: "ja", KR: "ko", DE: "de", AT: "de", FR: "fr", ES: "es",
  IT: "it", PT: "pt", BR: "pt", NL: "nl", PL: "pl", RU: "ru",
  TR: "tr", ID: "id", VN: "vi", TH: "th",
  US: "en", GB: "en", IE: "en", AU: "en", NZ: "en",
});

export function localeFromCountry(country: unknown): string | null {
  return typeof country === "string" && Object.hasOwn(countryLocales, country) ? countryLocales[country] : null;
}
