# Releasing Bluefold

How a build gets from this repo to a public "click download → drag to
Applications" experience.

## The moving parts

| Piece | Where |
|---|---|
| Release pipeline | `scripts/release.sh` (build → Developer ID sign → DMG → notarize → staple) |
| Publish script | `scripts/publish-release.sh` (pipeline + GitHub release on this repo) |
| Website | `gh-pages` branch of this repo → <https://cable729.github.io/bluefold/> |
| Download URL | `https://github.com/cable729/bluefold/releases/latest/download/Bluefold.dmg` — stable across versions; the site's button points here, and the site reads the releases API to show the current version |

First release (v0.1, signed + notarized, universal arm64+x86_64) shipped
2026-07-10.

## One-time setup (already done; for a new machine or account holder)

1. **Developer ID certificate** — Xcode → Settings → Accounts → add the
   developer Apple ID (team A448YLFLYC) → Manage Certificates… → **+** →
   **Developer ID Application** (account holder only; "Apple Development"
   certs won't pass Gatekeeper for direct downloads). Verify with
   `security find-identity -v -p codesigning`. Export a `.p12` backup —
   Apple keeps no copy of the private key.
2. **Notarization credentials** — mint an app-specific password at
   <https://account.apple.com> → Sign-In and Security, then:

   ```sh
   xcrun notarytool store-credentials bluefold \
     --apple-id <developer apple id> --team-id A448YLFLYC \
     --password <app-specific password>
   ```

## Cutting a release

```sh
scripts/publish-release.sh              # build → sign → notarize → publish
scripts/publish-release.sh --draft      # …or inspect before it goes live
```

The script refuses to publish an unnotarized DMG, uploads both
`Bluefold-<version>.dmg` and the stable-named `Bluefold.dmg` (the site's
button URL), and prints the URLs. The site shows the new version
automatically. Bump `MARKETING_VERSION` in `App/Bluefold.xcodeproj` first
(currently 0.2). If the version's tag already exists, assets are replaced
in place (`--clobber`).

`.github/workflows/release.yml` can do the same from a macOS runner on a
`v*` tag push — see "Automated releases from GitHub" below.

## Editing the website

The site is plain static files on the `gh-pages` branch (`index.html`,
icon assets). Commit and push to that branch; Pages redeploys in about a
minute. Keep the download button pointing at the stable
`/releases/latest/download/Bluefold.dmg` URL.

## Automated releases from GitHub (optional)

`.github/workflows/release.yml` runs the exact same `scripts/release.sh` on
a macOS runner whenever a `v*` tag is pushed (or it is dispatched from the
Actions tab) and publishes the release on this repo. Runner minutes are
free on public repos. Once the secrets are set up, a release is just:

```sh
git tag v0.2 && git push origin v0.2
```

**Signing secrets** (Settings → Secrets and variables → Actions). The
certificate's private key exists *only* in the login keychain of the Mac
where it was minted (Apple never has it; that's why there's no
"re-download" for a lost key — export a backup regardless). Letting GitHub
sign means handing it a copy as a secret:

- Keychain Access → My Certificates → right-click *Developer ID
  Application: … (A448YLFLYC)* → Export… → `.p12` with a password, then:

  ```sh
  gh secret set DEVELOPER_ID_P12 --repo cable729/bluefold \
    --body "$(base64 -i DeveloperID.p12)"
  gh secret set DEVELOPER_ID_P12_PASSWORD --repo cable729/bluefold
  gh secret set NOTARY_APPLE_ID --repo cable729/bluefold   # developer apple id
  gh secret set NOTARY_TEAM_ID  --repo cable729/bluefold --body A448YLFLYC
  gh secret set NOTARY_PASSWORD --repo cable729/bluefold   # app-specific password
  ```

Without the secrets, tag builds still run but produce only a DRAFT release
marked UNSIGNED — the workflow never publishes an unnotarized DMG, same as
`scripts/publish-release.sh`. If a release for the tag already exists
(published locally first), the workflow just replaces its assets, so the
local and CI paths don't conflict.

Security note: repo secrets are write-only through the UI/API and encrypted
at rest, and workflows from forks never receive them; but anyone with push
access can exfiltrate them via a workflow edit — fine for a
single-maintainer repo, move release signing to a protected `environment`
with required reviewers before adding collaborators.

## Notes / future

- **Verify on another Mac (or a different user account)** after publishing:
  download from the site, open the DMG, drag to Applications, launch —
  Gatekeeper should show the normal "downloaded from the internet" prompt,
  not a block.
- Hardened runtime is applied at sign time (`codesign --options runtime` in
  release.sh); `ENABLE_HARDENED_RUNTIME` stays off in the project so Debug
  builds keep `get-task-allow` (the lldb-attach debugging workflow).
- CloudKit sync entitlements are intentionally NOT in the Developer ID build
  yet (docs/SYNC.md); the Settings toggle stays hidden via the SecTask gate.
- Custom domain: `bluefold.app` was unregistered as of 2026-07-09. If
  registered, point it at Pages (CNAME file on gh-pages + A/AAAA records)
  and update the `og:image` URL in `index.html`.
- Sparkle (in-app updates) is the natural next step once there are real
  users; until then the site + releases/latest URL is the update channel.

## iOS / iPadOS release path (not yet started)

The Bluefold-iOS target (iPhone + iPad, one binary — `TARGETED_DEVICE_FAMILY
= "1,2"`) can only ship through Apple channels; there is no DMG equivalent.
In rough order of effort:

1. **Device install via Xcode** (works today): free with the existing
   developer account — connect a device, select the Bluefold-iOS scheme,
   run. Signing is automatic (team A448YLFLYC); apps signed this way expire
   after a year (7 days on a free account) and suit personal use only.
2. **TestFlight** (first real distribution step): App Store Connect →
   create the app record for `com.cable729.bluefold.ios` → `xcodebuild
   archive` + upload (Xcode Organizer or `xcrun altool`/Transporter).
   Internal testing (up to 100 testers on the team) needs no review;
   external TestFlight links go through a one-time beta review. Builds
   expire after 90 days.
3. **App Store**: same archive/upload pipeline plus listing metadata,
   screenshots (iPhone + 13-inch iPad sizes), privacy questionnaire
   ("data not collected" holds while sync is off/private-DB CloudKit),
   and app review. Review will exercise first-run with NO Calibre folder —
   the "Skip for Now" path must land somewhere useful.

Prerequisites to sort before step 2: wire the iOS entitlements file into
the pbxproj release config (it exists but is deliberately unwired — see
docs/SYNC.md), decide whether v1 ships with CloudKit sync enabled (if so,
deploy the CloudKit schema to Production first), and pick a marketing
version scheme shared with macOS (`MARKETING_VERSION` currently tracks the
macOS release number).
