[Aseprite][] binary build for 64-bit Windows.

To purchase Aseprite license visit its [download page][].

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

The workflow checks Aseprite's latest stable GitHub Release approximately every
three days at 01:17 UTC (09:17 China Standard Time). Beta, release-candidate,
prerelease, and draft releases are ignored.

When the stable version is newer than `.github/last-built-version.txt`, the
workflow builds it, uploads the result as a GitHub Actions artifact, and records
the version only after a successful build. If the version has not changed, the
scheduled run finishes without rebuilding.

Manual runs continue to work as before:

- Specify a tag such as `v1.3.18.1` to build that exact version.
- Leave the version empty to build the latest stable release again.

Artifacts are intended for the person who compiled them. Do not publish the
compiled binaries as public GitHub Releases; Aseprite's license limits source
compilation to personal use and prohibits distributing software copies to third
parties.

[Aseprite]: https://github.com/aseprite/aseprite
[versions]: https://github.com/aseprite/aseprite/tags
[download page]: https://www.aseprite.org/download/
