[Aseprite][] binary build for 64-bit Windows.

To purchase Aseprite license visit its [download page][].

Each build also includes:

- Cetaceaqua's Simplified Chinese extension, selected as the default language.
- Cetaceaqua's Boutique light and dark themes.
- BoutiqueBitmap 9x9 for normal UI text and BoutiqueBitmap 7x7 for mini text.
- The Boutique light theme selected by default.

Step by step guide to build binaries for latest version:

# 1. Create fork by clicking `Fork` button on the top right

![step1a](images/step1a.png)
![step1b](images/step1b.png)

# 2. Click `Actions` tab on the top, and enable actions

![step2](images/step2.png)

# 3. Open `aseprite` workflow, and click `Run workflow`

Optionally specify which version of Asprite to build (e.g. v1.3.10) in text field.
Leave it empty to build latest released version.
See list of available Aseprite versions [here][versions].

![step3](images/step3.png)

# 4. Wait ~13min for build to finish, then open latest run

![step4](images/step4.png)

# 5. Scroll to the bottom to download .zip archive

![step5](images/step5.png)

For building newer aseprite version repeat steps 3 to 5.

## Automatic stable builds

The workflow checks both Aseprite's latest stable GitHub Release and the
Simplified Chinese extension approximately every three days at 01:17 UTC
(09:17 China Standard Time). Beta, release-candidate, prerelease, and draft
releases are ignored.

The file `.github/last-built-version.txt` stores the last successful combined
build state: Aseprite version, selected Chinese release, and compatibility
status. If either Aseprite or the selected translation changes, the workflow
builds and uploads a new GitHub Actions artifact. It records the new combined
state only after a successful build. If neither has changed, the scheduled run
finishes without rebuilding.

Manual runs continue to work as before:

- Specify a tag such as `v1.3.18.1` to build that exact version.
- Leave the version empty to build the latest stable release again.

Artifacts are intended for the person who compiled them. Do not publish the
compiled binaries as public GitHub Releases; Aseprite's license limits source
compilation to personal use and prohibits distributing software copies to third
parties.

## Simplified Chinese compatibility

The build first checks `config/chinese-extension-compatibility.json`, then tries
to identify the Aseprite version mentioned by each stable release of
[Cetaceaqua's translation][chinese-extension]. An exact match is preferred.

If no exact match can be identified, the build continues with the latest stable
translation release. The fallback is visible in all of these places:

- the GitHub Actions artifact name;
- the language extension display name in Aseprite;
- `build-info.json` inside the portable build;
- the GitHub Actions run summary.

An artifact such as
`aseprite-v1.3.19-zh-0.1.15-boutique-fallback-from-1.3.18.1` means that Aseprite
v1.3.19 was packaged with a translation originally identified for v1.3.18.1.
`compat-unverified` means that the translation's intended Aseprite version
could not be determined.

Manual workflow runs can set `chinese_release` to force a specific translation
release. A manual override is still labeled as a fallback or unverified build
unless its target Aseprite version is present in the compatibility map.

The extensions are unpacked into `data/extensions`, so a fresh portable build
starts in `zh_Hans_ceta` with the `boutique` light theme. These are initial
defaults only: users can still change the language, theme, and font in
Preferences.

## Updating an existing portable folder

Do not copy a new artifact directly over an existing portable folder and
replace every file. Doing that replaces `aseprite.ini`, which contains the
portable user's preferences.

Instead:

1. Extract the new artifact into a separate temporary folder.
2. Drag the existing Aseprite folder onto `update-existing.cmd` from the new
   folder.
3. The updater copies the new program, data, translation, and theme files while
   excluding `aseprite.ini`. It does not delete extra files from the existing
   folder. After a successful update, it automatically deletes the extracted
   new source folder. If the surrounding artifact folder is then empty and its
   name matches the artifact, that folder is removed too.

If copying fails, the downloaded source is kept so the update can be retried.
Set `ASEPRITE_UPDATE_KEEP_SOURCE=1` before running the updater to keep the
downloaded source even after a successful update.

`aseprite.defaults.ini` records the defaults shipped by the current build for
reference. It is not loaded by Aseprite and does not replace the active
`aseprite.ini`.

[Aseprite]: https://github.com/aseprite/aseprite
[versions]: https://github.com/aseprite/aseprite/tags
[download page]: https://www.aseprite.org/download/
[chinese-extension]: https://github.com/Cetaceaqua/Aseprite-Simplified-Chinese-Extension/releases
