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
(currently 0.1). If the version's tag already exists, assets are replaced
in place (`--clobber`).

`.github/workflows/release.yml` can do the same from a macOS runner on a
`v*` tag push once the signing secrets are configured — see the comments at
the top of that file. Actions minutes are free on public repos.

## Editing the website

The site is plain static files on the `gh-pages` branch (`index.html`,
icon assets). Commit and push to that branch; Pages redeploys in about a
minute. Keep the download button pointing at the stable
`/releases/latest/download/Bluefold.dmg` URL.

## Automated releases from GitHub (optional)

`.github/workflows/release.yml` runs the exact same `scripts/release.sh` on a
macOS runner whenever you push a `v*` tag (or dispatch it from the Actions
tab), and publishes the release on the public site repo. Once set up, a
release is just:

```sh
git tag v0.2 && git push origin v0.2
```

Prerequisites, in order:

1. **CI billing must be fixed first** — Actions on this repo is currently
   dead (GitHub Settings → Billing & plans; see docs/PROGRESS.md ⚠️ CI).
   Note macOS runners bill at **10×** minutes on private repos; a release
   build is ~10–15 runner-minutes, so ~100–150 billed minutes per release.
   Releasing locally costs nothing — CI is a convenience, not a requirement.
2. **Store the signing secrets** (Settings → Secrets and variables → Actions
   on `cable729/bluefold`). Yes — the certificate's private key currently
   exists *only* in your Mac's login keychain (Apple never has it; that's
   why there's no "re-download" for a lost key — export a backup regardless).
   To let GitHub sign, you hand it a copy as a secret:
   - Keychain Access → My Certificates → right-click *Developer ID
     Application: … (A448YLFLYC)* → Export… → `.p12` with a password, then:

     ```sh
     gh secret set DEVELOPER_ID_P12 --repo cable729/bluefold \
       --body "$(base64 -i DeveloperID.p12)"
     gh secret set DEVELOPER_ID_P12_PASSWORD --repo cable729/bluefold
     gh secret set NOTARY_APPLE_ID --repo cable729/bluefold --body cable729@gmail.com
     gh secret set NOTARY_TEAM_ID  --repo cable729/bluefold --body A448YLFLYC
     gh secret set NOTARY_PASSWORD --repo cable729/bluefold   # app-specific password
     ```
3. **`SITE_RELEASE_TOKEN`** — the workflow's built-in token can't touch
   other repos, so publishing to `bluefold-site` needs a fine-grained PAT:
   github.com → Settings → Developer settings → Fine-grained tokens →
   generate one scoped to **only `cable729/bluefold-site`** with
   **Contents: Read and write**, then
   `gh secret set SITE_RELEASE_TOKEN --repo cable729/bluefold`.
   Without this secret the workflow degrades to a draft release on the
   private repo (artifact preserved, but not publicly downloadable).

Security notes: repo secrets are write-only through the UI/API and encrypted
at rest, but anyone who can push a workflow to this repo can exfiltrate
them — fine while the repo is yours alone; revisit before adding
collaborators or making the repo public (move release signing to an
`environment` with required reviewers at that point). The workflow refuses
to publish unnotarized DMGs publicly, same as `scripts/publish-release.sh`.

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
