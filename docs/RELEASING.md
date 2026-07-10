# Releasing Bluefold

How a build gets from this repo to a public "click download → drag to
Applications" experience.

## The moving parts

| Piece | Where | Status |
|---|---|---|
| Release pipeline | `scripts/release.sh` (build → sign → DMG → notarize → staple) | ✅ working (build+DMG verified 2026-07-09; sign/notarize pending credentials) |
| Publish script | `scripts/publish-release.sh` (pipeline + GitHub release) | ✅ written |
| Website | `bluefold-site` (separate repo hosting the site + downloads) | ⏳ **not yet pushed** |
| Download URL | `https://github.com/cable729/bluefold-site/releases/latest/download/Bluefold.dmg` (stable across versions; the site's button points here) | ⏳ after first publish |
| Site URL | `https://cable729.github.io/bluefold-site/` | ⏳ after Pages enabled |

## One-time setup (account holder, ~10 minutes)

These three steps must be done by the Apple-developer / GitHub account
holder.

### 1. Create the public site repo and enable Pages

From the `bluefold-site` checkout:

```sh
gh repo create cable729/bluefold-site --public \
  --description "Website and downloads for Bluefold, a macOS PDF reader for people who live in textbooks" \
  --source . --push
gh api -X POST repos/cable729/bluefold-site/pages \
  -f 'source[branch]=main' -f 'source[path]=/'
```

The site is live at <https://cable729.github.io/bluefold-site/> a minute or
two later.

### 2. Mint the Developer ID certificate

Xcode → **Settings → Accounts** → add Apple ID `cable729@gmail.com` (team
A448YLFLYC) if it isn't there → select the team → **Manage Certificates…** →
**+** → **Developer ID Application**. (Account holder only.)

Verify: `security find-identity -v -p codesigning` should list
`Developer ID Application: … (A448YLFLYC)`.

> Do NOT pick "Apple Development" — that certificate only works on your own
> machines. "Developer ID Application" is the one Gatekeeper trusts for
> direct-download apps.

### 3. Store notarization credentials

Create an **app-specific password** at <https://account.apple.com> →
Sign-In and Security → App-Specific Passwords, then:

```sh
xcrun notarytool store-credentials bluefold \
  --apple-id cable729@gmail.com --team-id A448YLFLYC \
  --password <the app-specific password>
```

## Every release after that

```sh
scripts/publish-release.sh              # build → sign → notarize → publish
scripts/publish-release.sh --draft      # …or inspect before it goes live
```

That's it. The script refuses to publish an unnotarized DMG, uploads both
`Bluefold-<version>.dmg` and the stable-named `Bluefold.dmg` (the site's
button URL), and prints the URLs. The site shows the new version number
automatically (it reads the GitHub releases API client-side).

Bump `MARKETING_VERSION` in `App/Bluefold.xcodeproj` when cutting a new
version (currently 0.1).

## Notes / future

- **Verify on another Mac (or account)** after the first publish: download
  from the site, open the DMG, drag to Applications, launch — Gatekeeper
  should show the normal "downloaded from the internet" prompt, not a block.
- The Release build is a universal binary (arm64 + x86_64), 8 MB DMG.
- Hardened runtime is applied at sign time (`codesign --options runtime` in
  release.sh); `ENABLE_HARDENED_RUNTIME` stays off in the project so Debug
  builds keep `get-task-allow` (the lldb-attach debugging workflow).
- CloudKit sync entitlements are intentionally NOT in the Developer ID build
  yet (docs/SYNC.md); the Settings toggle stays hidden via the SecTask gate.
- Custom domain: `bluefold.app` was unregistered as of 2026-07-09. If
  registered, point it at Pages (CNAME file + A/AAAA records) and update the
  `og:image` URL in the site repo's `index.html`.
- Sparkle (in-app updates) is the natural next step once there are real
  users; until then the site + releases/latest URL is the update channel.
