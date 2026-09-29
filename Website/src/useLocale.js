import { useEffect, useState } from "react";
import { createLocalePreference } from "./locales/preference.js";

export function useLocale() {
  const [preference] = useState(() => createLocalePreference(window));
  const [state, setState] = useState(() => preference.getSnapshot());
  useEffect(() => preference.subscribe(setState), [preference]);
  useEffect(() => { document.documentElement.lang = state.locale; }, [state.locale]);
  return [state.locale, preference.choose, state];
}

export function setPageMetadata(title, description) {
  document.title = title;
  document.querySelector('meta[name="description"]')?.setAttribute("content", description);
  document.querySelector('meta[property="og:title"]')?.setAttribute("content", title);
  document.querySelector('meta[property="og:description"]')?.setAttribute("content", description);
}
