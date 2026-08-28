# Changelog

<details open>
<summary><b>2026</b> </summary>


</details>

### 08.12

<details>
<summary><b>v0.1.0-alpha.1</b></summary>

- Feature: Implemented multi-level lyrics fallback.
- Improved the Chinese translations in the EeveeSpotify menu.

</details>

### 08.13

<details>
<summary><b>v0.1.0-beta.1</b></summary>

- Improved the display of Japanese romanized lyrics.
- Improved the lyrics fallback logic.
- Improved terminology handling when removing annotations from Genius lyrics.
- Fixed a possible crash when opening Spotify's sidebar.
- Removed the "Romanized" and "Fallback/Fallback Reason" labels from the lyrics frame.

</details>

<details>
<summary><b>v0.1.0-beta.2</b></summary>

- Improved capitalization of the first letter of each line in Japanese romanized lyrics.
- Improved the lyrics fallback logic.

</details>

<details>
<summary><b>v0.1.0-beta.3</b></summary>

- Changed the GitHub link to point to this repository, except for the Common Issues link.
- Improved the Chinese translations in the EeveeSpotify menu.

</details>

<details>
<summary><b>v0.1.0-beta.4</b></summary>

- Improved the update-checking method.
- Improved terminology handling when removing annotations from Genius lyrics.

</details>

### 08.14

<details>
<summary><b>v0.1.0-beta.5</b></summary>

- Improved terminology handling when removing annotations from Genius lyrics.
- Fixed an issue where checking for updates could remain stuck on "Checking for Update".

</details>

<details>
<summary><b>v0.1.0-beta.6</b></summary>

- Fixed an issue where the first letter after `「` could not be capitalized when a romanized line started with it. ❌

</details>

<details>
<summary><b>v0.1.0-beta.7</b></summary>

- Fixed an issue where the first letter after `「` could not be capitalized when a romanized line started with it. ❌
- Tried everything and still could not fix it, so it was left as-is. 😡

</details>

<details>
<summary><b>v0.1.0</b></summary>

- Feature: Implemented multi-level lyrics fallback.
- Improved the display of Japanese romanized lyrics.
- Improved capitalization of the first letter of each line in Japanese romanized lyrics.
- Improved the lyrics fallback logic.
- Improved the Chinese translations in the EeveeSpotify menu.
- Improved the update-checking method.
- Improved terminology handling when removing annotations from Genius lyrics.
- Changed the GitHub link in the EeveeSpotify menu to point to this repository, except for the Common Issues link.
- Fixed a possible crash when opening Spotify's sidebar.
- Fixed an issue where checking for updates could remain stuck on "Checking for Update".
- Removed the "Romanized" and "Fallback/Fallback Reason" labels from the lyrics frame.

Additional notes:

1. Chinese and Korean romanized content was returned as-is.
2. Lyrics fallback used a mandatory multi-level fallback process.

</details>

<details>
<summary><b>v1.0.0-alpha.1</b></summary>

- Added a clickable settings entry dedicated to this repository's features.

</details>

<details>
<summary><b>v1.0.0-alpha.2</b></summary>

- Added dedicated clickable UI for this repository's features, including lyrics and language romanization.

</details>

### 08.15

<details>
<summary><b>v1.0.0-alpha.3</b></summary>

- Added dedicated clickable UI for this repository's features, including lyrics and language romanization.

</details>

<details>
<summary><b>v1.0.0-beta.1</b></summary>

- Experimental feature: Added selectable lyrics fallback modes.

</details>

<details>
<summary><b>v1.0.0-beta.2</b></summary>

- Experimental feature: Added independent romanization switches for Japanese, Chinese, and Korean lyrics.
- Improved the Chinese translations in the EeveeSpotify menu.
- Fixed an issue where Mxm could fail to translate Japanese lyrics into romanized lyrics.

</details>

<details>
<summary><b>v1.0.0-beta.3</b></summary>

- Fixed an issue where the tweak ignored Japanese romanized lyrics already provided by Mxm and passed the original Japanese lyrics to local processing instead.
- Improved the Chinese translations in the EeveeSpotify menu.

</details>

<details>
<summary><b>v1.0.0-beta.4</b></summary>

- Improved the Chinese translations in the EeveeSpotify menu.

</details>

<details>
<summary><b>v1.0.0</b></summary>

- Feature: Added an independent settings entry for managing lyrics and language romanization switches.
- Feature: Added selectable lyrics fallback modes with manual switching.
- Feature: Added independent experimental romanization switches for Japanese, Chinese, and Korean lyrics.
- Fixed an issue where Mxm could fail to translate Japanese lyrics into romanized lyrics.
- Fixed an issue where the tweak ignored Japanese romanized lyrics already provided by Mxm and forcibly passed the original Japanese lyrics to local processing instead.
- Improved the Chinese translations in the EeveeSpotify menu.

</details>

<details>
<summary><b>v2.0.0-beta.1</b></summary>

- Feature: Added an option to remove Mxm's interlude symbol.
- Fixed an issue where Spotify's official lyrics could reappear when custom lyrics failed to load.
- Fixed an issue where Japanese lyrics were incorrectly identified as Chinese during local romanization.
- Fixed a false update notification when the current version matched the latest GitHub version.
- Improved the Chinese and English translations in the EeveeSpotify menu.
- Improved the multi-level lyrics fallback logic.
- Improved lyrics request handling to reduce premature failures.
- Improved the English and Simplified Chinese descriptions in the ngzhwm settings screen.
- Removed the "Show Fallback Reasons" UI and functionality from the EeveeSpotify menu.
- Reverted the behavior of fabricating empty lyrics when lyrics loading fails.

</details>

<details>
<summary><b>v2.0.0-beta.2</b></summary>

- Fixed an issue where romanized lyrics could still be returned even when "Romanize Japanese Lyrics" was disabled in the menu.

</details>

<details>
<summary><b>v2.0.0-beta.3</b></summary>

- Feature: Added the "Disable Lyrics Function" option.

</details>

<details>
<summary><b>v2.0.0-beta.4</b></summary>

- Improved the English translations in the EeveeSpotify menu

</details>

### 08.16

<details>
<summary><b>v2.0.0</b></summary>

- Added an option to remove Mxm's interlude symbol.
- Added the "Disable Lyrics Function" option.

- Fixed an issue where Spotify's official lyrics could reappear when custom lyrics failed to load.
- Fixed an issue where Japanese lyrics were incorrectly identified as Chinese during local romanization.
- Fixed a false update notification when the current version matched the latest GitHub version.

- Improved the Chinese and English translations in the EeveeSpotify menu.
- Improved the multi-level lyrics fallback logic.
- Improved lyrics request handling to reduce premature failures.
- Improved the English and Simplified Chinese descriptions in the ngzhwm settings screen.

- Removed the "Show Fallback Reasons" UI and functionality from the EeveeSpotify menu.

</details>

<details>
<summary><b>v2.1.0-beta.1</b></summary>

- Improved Genius fallback logic
- Improved Genius lyrics search accuracy
- Improved Genius lyrics parsing
- Fixed an issue where Genius could return an empty lyrics result, causing the "instrumental" placeholder to appear incorrectly
- Fixed an issue where Genius Romanizations did not respect the per-language romanization switches in ngzhwm settings

</details>

<details>
<summary><b>v2.1.0-beta.2</b></summary>

- Improved translations in the EeveeSpotify menu
- Reverted Genius behavior to throw `LyricsError.noSuchSong` when no song is found

</details>

<details>
<summary><b>v2.1.0-beta.3</b></summary>

- Improved Mxm romanization detection logic
- Improved terminology handling when removing annotations from Genius lyrics

</details>

### 08.19

<details>
<summary><b>v2.1.0-beta.4</b></summary>

- Improved terminology handling when removing annotations from Genius lyrics
- Improved Genius lyrics search accuracy

</details>

<details>
<summary><b>v2.1.0</b></summary>

- Improved Genius lyrics search accuracy
- Improved Genius fallback logic
- Improved Genius lyrics parsing
- Improved Mxm romanization detection logic
- Improved terminology handling when removing annotations from Genius lyrics
- Improved translations in the EeveeSpotify menu
- Fixed an issue where Genius could return an empty lyrics result, causing the "instrumental" placeholder to appear incorrectly
- Fixed an issue where Genius Romanizations did not respect the per-language romanization switches in ngzhwm settings

</details>

### 08.22

<details>
<summary><b>v3.0.0-beta.1</b></summary>

- Feature: Added enhanced Genius lyrics matching logic.

</details>

<details>
<summary><b>v3.0.0-beta.2</b></summary>

- Fixed an issue where the ngzhwm settings page did not scroll correctly.

</details>

<details>
<summary><b>v3.0.0-beta.3</b></summary>

- Fixed an issue where lyrics translations were not returned when Mxm was selected as the lyrics source.

</details>

<details>
<summary><b>v3.0.0-beta.4</b></summary>

- Feature: Added stricter detection for Japanese lyrics romanization.
- Fixed an issue where the first letter after 「 could not be capitalized when a romanized line started with it❌

</details>

### 08.23

<details>
<summary><b>v3.0.0-beta.5</b></summary>

- Fixed an issue where the first letter after 「 could not be capitalized when a romanized line started with it
- Fixed an issue where the first letter of Mxm’s romanized lyrics was not capitalized.

</details>

### 08.24

<details>
<summary><b>v3.0.0-beta.6</b></summary>

- Remove the “stricter Japanese lyrics romanization” feature introduced in v3.0.0-beta.4.

</details>

<details>
<summary><b>v3.0.0</b></summary>

- Feature: Added enhanced Genius lyrics matching logic.
- Improved Genius lyrics search and matching accuracy.
- Fixed an issue where the ngzhwm settings page did not scroll correctly.
- Fixed an issue where lyrics translations were not returned when Mxm was selected as the lyrics source.
- Fixed an issue where the first letter after 「 could not be capitalized when a romanized line started with it.
- Fixed an issue where the first letter of Mxm’s romanized lyrics was not capitalized.

</details>

### 08.25

<details>
<summary><b>v4.0.0-alpha.1</b></summary>

- Experimental: Implemented an experimental UI for the SpicyLyrics lyrics provider.

</details>

<details>
<summary><b>v4.0.0-beta.1</b></summary>

- Experimental: Added the SpicyLyrics lyrics provider (code from SideloadLabs/EeveeSpotifyReincarnated).

</details>

<details>
<summary><b>v4.0.0-beta.2</b></summary>

- Fixed an issue where SpicyLyrics could not remove lyric annotation terminology.
- Experimental: Implemented a UI prototype for the NetEase lyrics provider.

</details>

<details>
<summary><b>v4.0.0-beta.3</b></summary>

- Experimental: Tested the NetEase lyrics provider.❌

</details>

<details>
<summary><b>v4.0.0-beta.4</b></summary>

- Experimental: Added logging (code from SideloadLabs/EeveeSpotifyReincarnated).

</details>

<details>
<summary><b>v4.0.0-beta.5</b></summary>

- Experimental: Tested the NetEase lyrics provider.

</details>

<details>
<summary><b>v4.0.0-beta.6</b></summary>

- Fixed an issue where some features were missing from the EeveeSpotify menu.❌
- Fixed an issue where NetEase lyrics incorrectly displayed timestamps in the lyric text.
- Improved the NetEase lyrics search logic.
- Improved the translations in the EeveeSpotify menu.

</details>

<details>
<summary><b>v4.0.0-beta.7</b></summary>

- Adjusted: When NetEase is selected as the lyrics provider, Japanese romanized lyrics will use the official romanization instead of local processing.
- Improved the translations in the EeveeSpotify menu.
- Fixed an issue where the EeveeSpotify menu could not be scrolled to the bottom.

</details>

### 08.26

<details>
<summary><b>v4.0.0-beta.8</b></summary>

- Removed the “Romanize Lyrics” toggle from the EeveeSpotify menu.
- Improved NetEase lyrics search logic.
- Reverted Genius lyrics search logic.
- Moved the “Romanize Lyrics” toggle from the ngzhwm menu to the EeveeSpotify menu.

</details>

### 08.27

<details>
<summary><b>v4.0.0-beta.9</b></summary>

- Experimental: Attempted to fetch the track duration from Spotify.
- Fixed: Fixed an issue where the NetEase lyrics provider could assign a line’s translation to the previous line’s ♪.
- Fixed: Fixed an issue where some Japanese lyric lines from the NetEase lyrics provider could fail to be romanized.
- Removed: Removed localization files other than English and Simplified Chinese.

</details>

<details>
<summary><b>v4.0.0-beta.10</b></summary>

- Fixed: Fixed an issue where the NetEase lyrics provider could incorrectly filter out valid lyrics and return “Lyrics Not Found”.

</details>

<details>
<summary><b>v4.0.0-beta.11</b></summary>

- Feature: Modified the display method of NetEase Japanese romanized lyrics.

</details>

### 08.28

<details>
<summary><b>v4.0.0-beta.12</b></summary>

- Improved NetEase lyrics search logic.
- Improved translations in the EeveeSpotify menu.
- Fixed an issue where the NetEase lyrics provider would ignore lyrics without timestamps.
- Changed the default lyrics provider from LRCLIB to SpicyLyrics. The default lyrics provider remains PetitLyrics in Japan/Japanese-language regions.

</details>

<details>
<summary><b>v4.0.0-beta.13</b></summary>

- Fixed an issue where NetEase incorrectly handled instrumental tracks or songs without lyrics.

</details>

<details>
<summary><b>v4.0.0-beta.14</b></summary>

- Optimized NetEase lyrics search logic.

</details>