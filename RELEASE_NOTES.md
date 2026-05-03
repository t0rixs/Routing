# Release Notes — Routepia

## v(latest) — Internationalization & Country Flag Stats

### What's New
- **Full English localization.** The app now follows the system language. Japanese and English are supported; switching is automatic — no in-app toggle.
- **Country/region progress for non-Japanese users.** When the app runs in English, Japan-specific entries (prefectures) are replaced with **world countries, US states, world cities, micro-states, and famous landmarks**, all ranked by area (km²).
- **Country flag icons in the stats screen.** Country rows now show the actual flag (via ISO-3166 alpha-2 codes) instead of a generic icon. Iconography for landmarks, cities, and states uses themed Material icons.
- **In-App Update prompts** restored after Activity launch (Android, release builds only).

### Improvements
- Stats screen uses locale-aware area data with bilingual names.
- Map UI tooltips, FAB labels, dialogs, and overlays are fully localized.
- Drawer menu, map style settings, date filter chip, location-permission prompts, and cell-info popups all respect system locale.

### Fixed
- US state ISO code corrected (was `CA`, now `US`).
- Foreground notification config retained (Android-only, will be localized in a follow-up release).

### Known Issues
- The Android foreground-service notification text is still Japanese (`移動履歴を記録中...`). Localization of this string requires runtime context and will land next.

---

## How to install (Closed Testing)
1. Join the closed test on Google Play.
2. Open the Play Store listing — it will let you download the test build.
3. Set your phone language to English to see the new locale-aware experience, or keep Japanese for the original prefecture rankings.

