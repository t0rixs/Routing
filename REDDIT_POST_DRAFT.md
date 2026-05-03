# r/AndroidClosedTesting — Post Draft

**Title options (pick one):**

1. `[CT] Routepia — A privacy-first travel-history mapper from a Japanese indie dev. 100% local, no account, now with English support`
2. `[CT] I built a "paint the world" travel tracker that runs entirely on-device — looking for testers (Android, EN/JA)`
3. `[CT] Routepia: track every road you've ever walked, locally. New English release, country flags, area stats`

---

## Body

Hi r/AndroidClosedTesting!

I'm a Japanese indie developer, and I'm a huge fan of **local-first location tracking apps** — the kind that stay on your phone, never phone home, and don't ask for an account just to remember where you went last weekend.

I loved that genre so much I decided to build my own, with the features I always wished existed. It's called **Routepia**, and I'd love your help testing it.

### What it does

Routepia paints the map with every place you've been. Each cell of the world is colored in once you walk, drive, or fly through it — like Ingress's "explored area" mechanic, but for your real life and entirely **offline**.

- 🗺️ **Records your travel history locally** — the database lives on your device. No servers, no accounts, no telemetry.
- 🎨 **Three map modes**: Standard, Satellite, and a Blank canvas mode where only your trail is visible (great for screenshots).
- 📊 **Progress stats by region**: See what % of each country, US state, world city, micro-state, or famous landmark you've covered, ranked by area.
- 🏳️ **Country flag icons** in the stats screen for instant recognition.
- 🇯🇵 **Bilingual**: Japanese and English, follows your system language.
- 🔋 **Foreground service** with a persistent notification so Android doesn't kill the recording on long trips.
- 📤 **Export / import** your history so you never lose it.

### Why you might like it

- If you've ever wished Strava just *kept the map painted forever* — this is that.
- If you want a self-contained "where have I been?" app that doesn't sell your data — this is that, too.
- If you travel internationally, the new English release shows ranked progress for **world countries, US states, world cities, and landmarks** instead of Japanese prefectures.

### What I need from testers

- Daily-driving on Android 9+ for a week or two.
- Verify the **foreground notification keeps recording alive** on your specific OEM (Xiaomi/Samsung battery managers can be brutal).
- Try import/export with a long trip's worth of data.
- Tell me if the new English locale feels natural or stilted.
- Crash reports, weird UI on tablets, anything.

### Join the test

- **Google Group** (required by Play Console): [link]
- **Closed Test opt-in URL**: [link]
- **Play Store listing** (after opting in): [link]

I'll respond to every report and ship fixes fast. Thank you for helping a solo dev get this out the door 🙏

— myash, Tokyo

---

### Screenshots to attach (suggested order)

1. **Hero shot** — world map painted with travel cells, with a noticeable trail across multiple countries. Use blank-canvas mode for maximum visual impact.
2. **Stats screen — English** — showing country rows with flag icons (USA, Japan, France...) ranked by % covered.
3. **Stats screen — Japanese** — showing prefecture rankings, to highlight the localization.
4. **Map style switcher** — three side-by-side panels: Standard / Satellite / Blank.
5. **Cell info dialog** — tap a cell, see "First update / Last update" timestamps.
6. **Section delete UI** — showing the "select start → select end → delete N cells" flow.
7. **Drawer + foreground notification** — proves the always-on recording is real and respectful.

---

### Comments / DMs welcome

If you want a direct invite or have feedback that doesn't fit a public thread, DM me here on Reddit.
