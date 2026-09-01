🧪 Experimental / Development

This section records experimental, testing, and development-stage work for internal reference only.

· Added dedicated tappable UI for this repository's features.
  (v1.0.0-alpha.2, v1.0.0-alpha.3)
· Implemented UI for the SpicyLyrics lyrics provider.
  (v4.0.0-alpha.1)
· Implemented UI prototype for the NetEase lyrics provider.
  (v4.0.0-beta.2)
· Attempted to fetch track duration from Spotify via probe.
  (v4.0.0-beta.9)
· Implemented UI for the "Enable Word‑by‑Word Lyrics" option.
  (v5.0.0-alpha.1)
· Wrote code logic for word‑by‑word lyrics.
  (v5.0.0-alpha.2)
· Attempted to fetch word‑by‑word lyrics from NetEase.
  (v5.0.0-alpha.3, v5.0.0-alpha.4)
· Attempted to probe Spotify's lyrics endpoint.
  (v5.0.0-alpha.5)
· Tested availability of word‑by‑word lyrics.
  (v5.0.0-beta.1, beta.2, beta.3, beta.5, beta.6, beta.9, beta.10, beta.12, beta.13, beta.14)
· Attempted to implement logic for fetching word‑by‑word lyrics from PetitLyrics.
  (v5.0.0-beta.4)
· Implemented word‑by‑word lyrics UI.
  (v5.0.0-beta.15)
· Improved display of the word‑by‑word lyrics UI.
  (v5.0.0-beta.16, v5.0.0-beta.17)

---

✨ New Features

Officially released new functionality.

· Tappable settings entry pointing to this repository.
  (v1.0.0-alpha.1)
· Manually selectable lyrics fallback modes.
  (v1.0.0)
· Independent romanization switches for Japanese, Chinese, and Korean lyrics.
  (v1.0.0)
· Option to remove Mxm's interlude symbol.
  (v2.0.0-beta.1)
· "Disable Lyrics Function" option.
  (v2.0.0-beta.3)
· SpicyLyrics lyrics provider.
  (v4.0.0)
· NetEase lyrics provider.
  (v4.0.0)
· Logging / log export.
  (v4.0.0-beta.4)
· Modified display method for NetEase Japanese romanized lyrics.
  (v4.0.0-beta.11)
· Option to hide NetEase lyrics translations.
  (v4.0.0-beta.16)
· Support for the latest SpicyLyrics (6.3.12).
  (v5.0.0-beta.11)
· Word‑by‑word lyrics now display translations and corresponding romanized lyrics.
  (v5.1.0-beta.2)

---

🔧 Improvements

Ongoing optimizations to existing functionality and user experience.

· Translations in the EeveeSpotify menu.
  (v0.1.0-alpha.1, v0.1.0-beta.3, v1.0.0-beta.2, v1.0.0-beta.3, v1.0.0-beta.4, v2.0.0-beta.1, v2.0.0-beta.4, v2.1.0-beta.2, v4.0.0-beta.6, v4.0.0-beta.7, v4.0.0-beta.12, v4.1.0-beta.1, v5.0.0-beta.18, v5.0.0-beta.19)
· Processing logic for Japanese romanized lyrics.
  (v0.1.0-beta.1)
· Multi‑level lyrics fallback logic.
  (v0.1.0-beta.1, v0.1.0-beta.2, v2.0.0-beta.1)
· Ongoing refinement of terminology removal from Genius lyrics annotations.
  (v0.1.0-beta.1, v0.1.0-beta.4, v0.1.0-beta.5, v2.1.0-beta.3, v2.1.0-beta.4)
· Capitalization handling for the first letter of each line in Japanese romanized lyrics.
  (v0.1.0-beta.2)
· Update checking method.
  (v0.1.0-beta.4)
· Request handling for multi‑level fallback to reduce premature failures.
  (v2.0.0-beta.1)
· Mxm romanization detection logic.
  (v2.1.0-beta.3)
· Display of the word‑by‑word lyrics UI.
  (v5.0.0-beta.18)
· Additional logging.
  (v5.1.0-beta.1)

---

🐛 Bug Fixes

Issues that have been resolved.

· Possible crash when opening Spotify's sidebar.
  (v0.1.0-beta.1)
· Update check getting stuck on "Checking for Update".
  (v0.1.0-beta.5)
· First letter after 「 not being capitalized when a romanized line started with it.
  (v0.1.0-beta.6, v0.1.0-beta.7, v3.0.0-beta.4, v3.0.0-beta.5)
· Mxm failing to translate Japanese lyrics into romanized lyrics.
  (v1.0.0-beta.2)
· Tweak ignoring Mxm‑provided Japanese romanized lyrics and passing original Japanese to local processing instead.
  (v1.0.0-beta.3)
· Spotify official lyrics reappearing when custom lyrics failed to load.
  (v2.0.0-beta.1)
· Japanese lyrics being misidentified as Chinese during local romanization.
  (v2.0.0-beta.1)
· False update notification when current version matched the latest GitHub version.
  (v2.0.0-beta.1)
· Genius returning empty lyrics results, incorrectly showing the "instrumental" placeholder.
  (v2.1.0-beta.1)
· Genius romanizations not respecting per‑language romanization switches.
  (v2.1.0-beta.1)
· No lyrics translation returned when Mxm was selected as the lyrics source.
  (v3.0.0-beta.3)
· First letter of Mxm's romanized lyrics not capitalized.
  (v3.0.0-beta.5)
· NetEase lyrics incorrectly displaying timestamps in the lyric text.
  (v4.0.0-beta.6)
· NetEase assigning a line's translation to the previous line's ♪.
  (v4.0.0-beta.9)
· Some Japanese lyric lines from NetEase failing to be romanized.
  (v4.0.0-beta.9)
· NetEase incorrectly filtering out valid lyrics and returning "Lyrics Not Found".
  (v4.0.0-beta.10)
· NetEase ignoring lyrics without timestamps.
  (v4.0.0-beta.12)
· NetEase mishandling instrumental tracks or songs without lyrics.
  (v4.0.0-beta.13)
· Manual scrolling during word‑by‑word playback being forcibly snapped back to the current line.
  (v5.0.0-beta.7)
· Scrollable white text remnants appearing above the lyrics module when word‑by‑word lyrics were unavailable.
  (v5.0.0-beta.8)
· NetEase failing to display lyrics translations correctly when word‑by‑word lyrics were enabled.
  (v5.1.0-beta.3)

---

🗑️ Removals

Features that have been removed or deprecated.

· "Romanized" and "Fallback/Fallback Reason" labels from the lyrics frame.
  (v0.1.0-beta.1)
· "Show Fallback Reasons" UI and functionality from the EeveeSpotify menu.
  (v2.0.0-beta.1)
· "Romanize Lyrics" toggle from the EeveeSpotify menu.
  (v4.0.0-beta.8)
· Localization files other than English and Simplified Chinese.
  (v4.0.0-beta.9)

---

🔄 Other Changes

Miscellaneous adjustments not covered above.

· Changed GitHub link to point to this repository (except for the Common Issues link).
  (v0.1.0-beta.3)
· Changed default lyrics provider from LRCLIB to SpicyLyrics (PetitLyrics remains default in Japan/Japanese‑language regions).
  (v4.0.0-beta.12)
· Moved the "Romanize Lyrics" toggle from the ngzhwm menu to the EeveeSpotify menu.
  (v4.0.0-beta.8)
· Changed UI display of "Clear Debug Logs".
  (v5.1.0-beta.1)