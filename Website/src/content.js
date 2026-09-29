import locale0 from "./locales/en.json" with { type: "json" };
import locale1 from "./locales/zh-Hans.json" with { type: "json" };
import locale2 from "./locales/zh-Hant.json" with { type: "json" };
import locale3 from "./locales/ja.json" with { type: "json" };
import locale4 from "./locales/ko.json" with { type: "json" };
import locale5 from "./locales/de.json" with { type: "json" };
import locale6 from "./locales/fr.json" with { type: "json" };
import locale7 from "./locales/es.json" with { type: "json" };
import locale8 from "./locales/it.json" with { type: "json" };
import locale9 from "./locales/pt.json" with { type: "json" };
import locale10 from "./locales/nl.json" with { type: "json" };
import locale11 from "./locales/pl.json" with { type: "json" };
import locale12 from "./locales/ru.json" with { type: "json" };
import locale13 from "./locales/tr.json" with { type: "json" };
import locale14 from "./locales/id.json" with { type: "json" };
import locale15 from "./locales/vi.json" with { type: "json" };
import locale16 from "./locales/th.json" with { type: "json" };
import { locales } from "./locales/registry.js";
import { expandMessages } from "./locales/schema.js";
export { defaultLocale } from "./locales/registry.js";

export const messages = {
  "en": locale0,
  "zh-Hans": locale1,
  "zh-Hant": locale2,
  "ja": locale3,
  "ko": locale4,
  "de": locale5,
  "fr": locale6,
  "es": locale7,
  "it": locale8,
  "pt": locale9,
  "nl": locale10,
  "pl": locale11,
  "ru": locale12,
  "tr": locale13,
  "id": locale14,
  "vi": locale15,
  "th": locale16,
};
export const content = Object.fromEntries(locales.map(locale => [locale.code, expandMessages(messages[locale.code], locale)]));
export default content;
