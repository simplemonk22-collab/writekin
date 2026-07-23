# Releasing Writekin

How a release works, from a bare Mac to a downloadable, self-updating app.
Everything except the final upload is scripted; **the script never touches
git** — tagging, pushing, and publishing the GitHub Release are manual,
deliberately.

## The moving parts

A Writekin release is three pieces that reference each other:

1. **The DMG** — the signed, notarized app in a disk image. Hosted as a
   GitHub Release asset.
2. **The appcast** (`appcast.xml`) — Sparkle's update feed: a list of
   versions with download URLs and cryptographic signatures. Hosted on
   GitHub Pages at `https://scouttyg.github.io/writekin/appcast.xml`,
   which is the `SUFeedURL` baked into the app.
3. **The Sparkle key pair** — the private key (in your login keychain,
   **never** in the repo) signs each release; the public key
   (`SUPublicEDKey` in `project.yml`) ships inside the app so it can
   verify updates.

An installed copy of Writekin periodically fetches the appcast, sees a
newer version, verifies its signature with the public key, downloads the
DMG from the GitHub Release, and offers the update.

## Order of operations

What must happen before what — and, as important, what *doesn't* block:

1. **Apple Developer Program enrollment (Part 0)** blocks everything
   Apple-side and takes days, not minutes — start it first. The
   certificate (Part 1) requires it; notarization (Part 2) requires the
   certificate (you can only notarize a properly signed app).
2. **Sparkle keys (Part 3) must exist before the first real build.**
   The public key is baked into the app at build time; a version shipped
   without it can never self-update, and the updater deliberately won't
   start. Generate keys → paste `SUPublicEDKey` → `xcodegen generate` →
   commit → *then* run `release.sh`.
3. **The repo must be on GitHub before `publish.sh`** (it pushes to
   `origin`), but not before `release.sh` — you can build and notarize
   entirely offline from git hosting.
4. **GitHub Pages does NOT block the first release.** The appcast only
   matters once an *installed* copy looks for a *newer* version — i.e.
   from your second release onward. For release one, `publish.sh`
   creates the `gh-pages` branch and pushes the appcast; you then flip
   the Pages toggle (Settings › Pages › `gh-pages` / root, only possible
   once the branch exists, and the repo must be public). Until then,
   installed copies just see an unreachable feed and no update offers —
   nothing breaks. Have it serving before you cut release two.
5. Parts 1–3 are independent of each other once enrollment clears —
   any order works. Everything is one-time except the release cycle
   itself (`release.sh` → edit notes → `publish.sh`).

So the critical path for a first release is: enroll (wait) → cert +
notary profile + Sparkle keys (any order) → key into project.yml →
repo pushed → `release.sh` → `publish.sh` → enable Pages.

## Part 0 — Apple Developer Program (one-time, ~2 days)

Distributing a Mac app outside the App Store requires **Developer ID**
signing plus **notarization**, and both require a **paid** Apple
Developer Program membership ($99/year).

**"My Apple account shows no teams"** means one of:

- You have an Apple ID but never enrolled in the paid program. A free
  account gets only a "Personal Team," which cannot create Developer ID
  certificates or notarize. Enroll at
  <https://developer.apple.com/programs/enroll/> (as an individual —
  no D-U-N-S number needed). Approval usually takes a day or two.
- Your membership lapsed — check status at
  <https://developer.apple.com/account> under **Membership details**.

After enrollment, that same Membership details page shows your **Team
ID** (a 10-character code like `A1B2C3D4E5`) — you'll need it below.
Verify Xcode sees it: Xcode › Settings › Accounts › your Apple ID should
list the team *without* "(Personal Team)" after it.

## Part 1 — Developer ID certificate (one-time)

1. Xcode › Settings › Accounts › select your team › **Manage
   Certificates…** › **+** › **Developer ID Application**.
   (Only the Account Holder role can create this certificate type.)
2. Verify:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID"
   ```

   Expect one line like `Developer ID Application: Your Name (TEAMID)`.
   If it's missing, the certificate didn't land in your login keychain.

## Part 2 — Notarization credentials (one-time)

Notarization is Apple scanning your app server-side; Gatekeeper refuses
un-notarized downloads on modern macOS. The script authenticates via a
stored keychain profile:

1. Create an **app-specific password** at <https://account.apple.com> ›
   Sign-In and Security › App-Specific Passwords (your normal password
   won't work here).
2. Store the profile:

   ```sh
   xcrun notarytool store-credentials writekin-notary \
     --apple-id <your Apple ID email> \
     --team-id <TEAMID> \
     --password <app-specific password>
   ```

3. Verify:

   ```sh
   xcrun notarytool history --keychain-profile writekin-notary
   ```

   An empty history is fine — an auth error is not.

## Part 3 — Sparkle keys (one-time)

1. Download the Sparkle distribution from
   <https://github.com/sparkle-project/Sparkle/releases> (the
   `Sparkle-<version>.tar.xz`). Extracting it drops a folder like
   `Sparkle-2.9.4/` wherever you unzip it — **`~/Downloads` is not a
   good permanent home** for this (Downloads gets cleared by cleanup
   tools, and `release.sh` needs these binaries indefinitely, not just
   once). Move the extracted folder somewhere stable instead:

   ```sh
   mkdir -p ~/Sparkle
   mv ~/Downloads/Sparkle-2.9.4 ~/Sparkle/
   ```

   Everything below assumes that final location; adjust the version
   number to whatever you downloaded.

2. Run `~/Sparkle/Sparkle-2.9.4/bin/generate_keys`. The **private key
   goes into your login keychain** ("Private key for signing Sparkle
   updates") — it is never written to disk unless you explicitly export
   it, and it must NEVER enter the repo. `.gitignore` blocks common
   key-file patterns as a safety net, but the real rule is: don't export
   it into the repo tree.
3. Paste the printed **public** key into `project.yml` under
   `SUPublicEDKey`, run `xcodegen generate`, and commit. The updater
   refuses to start until a plausible key is present — by design
   (`UpdaterModel` checks it).
4. Back up the private key somewhere safe:

   ```sh
   ~/Sparkle/Sparkle-2.9.4/bin/generate_keys -x ~/Sparkle/backup.key
   ```

   to a location **outside the repo** — ideally straight into a
   password manager rather than left as a loose file, even in
   `~/Sparkle`. If you lose it, existing installs can never verify
   another update.
5. **Put `bin/` on `PATH` (or set `SPARKLE_BIN`) so `release.sh` can
   find `generate_appcast`.** Two ways, pick one:

   - **Per-shell, every time:**
     ```sh
     SPARKLE_BIN=~/Sparkle/Sparkle-2.9.4/bin scripts/release.sh 0.9.0
     ```
   - **Once, permanently** — add to `~/.zshrc` (or `~/.bash_profile`):
     ```sh
     export PATH="$HOME/Sparkle/Sparkle-2.9.4/bin:$PATH"
     ```
     then `source ~/.zshrc` (or open a new terminal). Verify with:
     ```sh
     which generate_appcast generate_keys
     ```
     Both should resolve into `~/Sparkle/Sparkle-2.9.4/bin/`. Without
     one of these, `release.sh` silently skips appcast generation
     (prints a warning, doesn't fail) — it won't error, it'll just
     leave you without an `appcast.xml` to publish.

## Cutting a release

```sh
scripts/release.sh 0.9.0            # full: archive → notarize → staple → DMG → appcast
DRY_RUN=1 scripts/release.sh 0.9.0  # stops before notarization; ad-hoc signs
```

The script, in order:

1. **Cleans `build/release/`** — a stale product once reappeared in the
   bundle, hence the paranoia.
2. **Regenerates the project** from `project.yml` and archives with the
   version you passed (`MARKETING_VERSION`) and a timestamp build number.
3. **GPL guard**: fails hard if `imessage-exporter` is anywhere inside
   the app bundle (it's GPL-3.0 and must stay download-on-demand).
4. **Notarizes and staples** via the `writekin-notary` profile
   (skipped under `DRY_RUN=1`).
5. **Builds `build/release/Writekin-<version>.dmg`** (drag-to-
   Applications layout).
6. **Generates the appcast** into `build/release/updates/` with download
   URLs pointing at
   `https://github.com/scouttyg/writekin/releases/download/v<version>/`
   — `generate_appcast` must be on PATH, or set `SPARKLE_BIN` to
   Sparkle's `bin/`. This step also signs the release with the private
   key from your keychain.
7. Prints the DMG's SHA-256 and a drafted release-notes block.

## Publishing

The normal path is one script (run by you — it is the only script that
touches git, and `release.sh` deliberately never does):

```sh
# 1. sanity-run the DMG's app on a clean user account or second machine
# 2. edit build/release/RELEASE_NOTES.md — fill in the highlights
scripts/publish.sh 0.9.0            # tag → push → GitHub Release + DMG → appcast to Pages
DRY_RUN=1 scripts/publish.sh 0.9.0  # print every mutating command instead of running it
```

`publish.sh` refuses to start unless the DMG and appcast exist for this
exact version, the working tree is clean, the tag is unused, the notes
file has real highlights, and `gh` is authenticated — so it can't strand
a release half-shipped. It creates the `gh-pages` branch on first run,
then waits for Pages to actually serve the new appcast before declaring
success. **First publish only:** enable Pages afterward (Settings ›
Pages › deploy from branch › `gh-pages`, root).

### What the script does, if you ever need it by hand

1. Tag and push:

   ```sh
   git tag -a v0.9.0 -m "Writekin 0.9.0" && git push origin HEAD v0.9.0
   ```

2. On GitHub: create a Release for the tag, upload the DMG, paste the
   drafted notes. **The asset filename must stay exactly
   `Writekin-<version>.dmg`** — the appcast URL points at it.
3. Publish the appcast to GitHub Pages.

   **One-time setup** (after the repo exists on GitHub and is public):

   ```sh
   cd $(mktemp -d)                       # work outside your checkout
   git clone git@github.com:scouttyg/writekin.git pages && cd pages
   git checkout --orphan gh-pages        # branch with no history
   git rm -rf . && rm -f .gitignore      # empty it completely
   touch .nojekyll                       # serve files verbatim, no Jekyll
   git add .nojekyll
   git commit -m "Pages branch for the Sparkle appcast"
   git push -u origin gh-pages
   ```

   Then on GitHub: Settings › Pages › Build and deployment › **Deploy
   from a branch** › `gh-pages` / `/ (root)`. Within a minute or two,
   `https://scouttyg.github.io/writekin/` goes live (a 404 there is
   normal until the appcast lands).

   **Each release**, from that same `pages` checkout (or re-clone with
   `git clone -b gh-pages …`):

   ```sh
   cp <repo>/build/release/updates/appcast.xml .
   git add appcast.xml
   git commit -m "Appcast for v<version>"
   git push
   ```

   Confirm `https://scouttyg.github.io/writekin/appcast.xml` serves the
   new XML in a browser before announcing the release.
4. **The landing page** (`site/index.html`, `site/style.css`,
   `site/icon.png`, `site/screenshots/`) lives on `main` and is copied
   into `gh-pages` automatically by `publish.sh`, in the same commit as
   the appcast — no separate step needed for a normal release. If you
   want to tweak page copy **without** cutting a release, sync it by
   hand from that same `pages` checkout:

   ```sh
   cp <repo>/site/index.html <repo>/site/style.css <repo>/site/icon.png .
   git add index.html style.css icon.png
   git commit -m "Update landing page"
   git push
   ```
5. Verify the loop end-to-end: install the *previous* version, open it,
   and confirm Sparkle offers the new one (or run the current one and
   check Console for a clean feed fetch under subsystem
   `com.scottgoci.writekin`).

## Troubleshooting

- **"No signing certificate" / archive fails** — Part 1 didn't complete,
  or Xcode is signed into the wrong Apple ID.
- **notarytool `401`/auth errors** — the app-specific password was
  revoked, or the Team ID is wrong. Re-run `store-credentials`.
- **Notarization "Invalid" verdict** — run
  `xcrun notarytool log <submission-id> --keychain-profile
  writekin-notary` for the itemized reasons (usually an unsigned nested
  binary).
- **Sparkle never offers updates** — check the feed URL in the installed
  app's Info.plist, that the appcast is reachable in a browser, and that
  `SUPublicEDKey` matches the key that signed the appcast.
- **Update check says "invalid signature"** — the appcast was generated
  on a machine without the original private key. There is no recovery
  except shipping a new version signed correctly from a restored key.
