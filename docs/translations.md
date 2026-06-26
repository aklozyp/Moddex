# Translation contribution guide

Thank you for helping translate Moddex! This guide lets you prepare a new
language or improve an existing one and open a pull request with clear quality
criteria — no back-and-forth required.

German (`de`) and English (`en`) are production-complete. `es`, `fr`, `zh`, `ja`
and `ar` ship as **structural placeholders** that currently fall back to English;
completing them is a **v0.3** goal
([#27](https://github.com/aklozyp/Moddex/issues/27)).

## Where the files live

Translations live in the **frontend** repository
([`aklozyp/Moddex-Frontend`](https://github.com/aklozyp/Moddex-Frontend)), not in
this packaging repo. Translation PRs target the frontend repo's `tests` branch.

| What | Path |
|------|------|
| Translation files | `src/assets/i18n/<code>.json` (e.g. `fr.json`) |
| Language registry | `src/app/services/language-service.ts` (`LANGUAGES`) |
| Parity test | `src/app/i18n-parity.spec.ts` |

`<code>` is the BCP-47 language code (`en`, `de`, `es`, `fr`, `zh`, `ja`, `ar`, …)
and is also the JSON file name. English is always the fallback for any missing
key (ngx-translate `fallbackLang`), so a partial translation never shows a blank
string — it shows English.

## Key conventions

- Each file is a **nested JSON object** grouped by feature, e.g.:
  ```json
  {
    "CONSOLE": {
      "START": "Start",
      "STATUS": { "RUNNING": "Running" }
    }
  }
  ```
- **Only translate the values.** Never rename, add, remove or re-nest keys — the
  key structure must stay identical to `en.json`. A key that exists in one
  language but not another would surface to users as a raw key like
  `CONSOLE.STATUS.RUNNING`.
- Keep the JSON valid: UTF-8, double quotes, no trailing commas. Save as UTF-8
  **without BOM**.
- Preserve meaningful symbols (`…`, `↑`/`↓`, arrows, units) unless your language
  has an established equivalent.

## Placeholder rules

Strings may contain **interpolation placeholders** in double curly braces, e.g.:

```json
"TOO_LARGE": "File is too large (max {{ max }} MB).",
"UPDATES_AVAILABLE": "{{count}} updates available"
```

- **Never translate or rename the token inside `{{ … }}`** — `{{ max }}`,
  `{{count}}`, `{{name}}`, `{{path}}` etc. must appear **verbatim** in your
  translation (the app substitutes real values at runtime).
- You may move a placeholder to wherever it reads naturally in your language, and
  you do **not** need to keep the surrounding word order — only the token text
  must match exactly (including spacing style as found, e.g. `{{ max }}` vs
  `{{count}}`).
- Do not add new placeholders that the source string does not have.

## Right-to-left (RTL) languages

For RTL scripts (Arabic, Hebrew, Farsi, …):

- Set `dir: 'rtl'` on the language's registry entry (see below). `LanguageService`
  mirrors this onto `<html lang dir>`, which flips the whole document layout.
- Translate naturally; do not insert manual direction marks unless required for a
  mixed-direction string. Latin tokens and `{{ placeholders }}` stay as-is.
- Sanity-check the UI in the browser with your language selected — long strings
  and RTL flipping can reveal layout issues worth noting in the PR.

## Adding a new language

1. Copy the English source as your starting point:
   ```bash
   cp src/assets/i18n/en.json src/assets/i18n/<code>.json
   ```
2. Translate every **value** in `<code>.json`, keeping keys and `{{ placeholders }}`
   unchanged.
3. Register the language in `src/app/services/language-service.ts` by adding one
   entry to the `LANGUAGES` array:
   ```ts
   { code: 'fr', nativeLabel: 'Français', englishLabel: 'French', dir: 'ltr', complete: false },
   ```
   - `nativeLabel`: the language's name in itself (shown in the switcher).
   - `englishLabel`: the English name (secondary label).
   - `dir`: `'ltr'` or `'rtl'`.
   - `complete`: leave `false` until the file is fully translated and reviewed;
     set `true` only when there are no English leftovers.
4. Verify (see below) and open the PR.

This single registry entry is the only code change required — the language
switcher, persistence and `<html lang dir>` handling pick it up automatically.

## Updating an existing language

- Keep the file in **key parity** with `en.json` (same keys, nothing extra).
- When new English keys are added upstream, add the corresponding translated keys.
- Once a placeholder language has no remaining English values, flip its `complete`
  flag to `true` in `LANGUAGES`.

## Verifying completeness

- **Run the frontend tests** before submitting:
  ```bash
  npm test -- --watch=false --browsers=ChromeHeadless
  ```
  The parity spec (`i18n-parity.spec.ts`) currently guards the `de`/`en` pair and
  fails the build if a key is present in one but missing in the other. If you also
  changed `de`/`en`, this must stay green.
- **For other languages**, parity against English is not yet gated automatically,
  so check it manually — every key in `en.json` must exist in your file. A quick
  way to list missing keys with [`jq`](https://jqlang.github.io/jq/):
  ```bash
  comm -23 \
    <(jq -r 'paths(scalars) | join(".")' src/assets/i18n/en.json | sort) \
    <(jq -r 'paths(scalars) | join(".")' src/assets/i18n/<code>.json | sort)
  ```
  An empty result means your file covers every English key. (Extending the parity
  spec to your language is a welcome bonus.)
- Confirm the app still builds:
  ```bash
  npm run build -- --configuration production
  ```

## PR checklist

Copy this into your pull request description and tick each item:

- [ ] Added/updated `src/assets/i18n/<code>.json`; only **values** changed.
- [ ] Key structure is **identical** to `en.json` (no added/removed/renamed keys).
- [ ] All `{{ placeholders }}` are preserved verbatim; none added or removed.
- [ ] For a new language: a single `LANGUAGES` entry added with correct
      `nativeLabel` / `englishLabel` / `dir`.
- [ ] `complete` flag reflects reality (`true` only if fully translated).
- [ ] RTL: `dir: 'rtl'` set if applicable and layout sanity-checked.
- [ ] `npm test` passes (de/en parity stays green) and production build succeeds.
- [ ] JSON is valid UTF-8 without BOM.

## Roadmap

Full coverage of **Spanish, Chinese, Japanese, French and Arabic** (including RTL
polish) is a **v0.3** goal, tracked in
[#27](https://github.com/aklozyp/Moddex/issues/27). Contributions toward any of
these are very welcome before then — they will simply ship as they reach
completeness.
