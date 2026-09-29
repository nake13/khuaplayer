import { GlobeSimple } from "@phosphor-icons/react";
import { locales } from "./locales/registry.js";

export function LanguagePicker({ locale, onChange, label }) {
  const current = locales.find(item => item.code === locale);
  return (
    <label className="language-control language-picker" title={label}>
      <GlobeSimple aria-hidden="true" />
      <span aria-hidden="true" lang={locale}>{current.short}</span>
      <select aria-label={label} value={locale} onChange={event => onChange(event.target.value)}>
        {locales.map(item => <option key={item.code} value={item.code} lang={item.code}>{item.name}</option>)}
      </select>
    </label>
  );
}
