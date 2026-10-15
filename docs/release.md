# Release

`scripts/release.sh` builds `build/release/Silkweb-<version>.dmg` (#249, #271). The script signs the app and
the DMG with a Developer ID Application identity, hardened runtime and a secure timestamp. Apple's notary
service then accepts both, and the script staples the tickets. A downloaded DMG opens with only the standard
"downloaded from the Internet" prompt.

The repo and CI hold no certificate, password or key. The script reads two names from the environment:

| Variable | Default |
|---|---|
| `SILKWEB_SIGN_IDENTITY` | `Developer ID Application: Mark Hinojosa (V8X3GYRTNK)` |
| `SILKWEB_NOTARY_PROFILE` | `silkweb-notary` |

## 1. Install the certificate

1. In Xcode, open **Settings ▸ Accounts** and select the Apple Developer team.
2. Click **Manage Certificates** and add a **Developer ID Application** certificate.
3. Make sure that the certificate and its private key are in the login keychain:

```sh
security find-identity -v -p codesigning
```

The output must show `"Developer ID Application: Mark Hinojosa (V8X3GYRTNK)"`.

## 2. Store a notarytool keychain profile

1. Make an app-specific password at <https://account.apple.com> (**Sign-In and Security ▸ App-Specific Passwords**).
2. Store the profile. The command asks for the password and keeps it in the keychain:

```sh
xcrun notarytool store-credentials silkweb-notary --apple-id <Apple ID email> --team-id V8X3GYRTNK
```

3. Check the profile:

```sh
xcrun notarytool history --keychain-profile silkweb-notary
```

## 3. GitHub secrets

Add none. `.github/workflows/release.yml` doesn't sign yet, so a tag push doesn't start it. A manual run stops
at the credential check and never publishes an unsigned DMG. Publish from your Mac (step 4).

## 4. Run the release script

1. Set `CFBundleShortVersionString` in `scripts/Info.plist` to the new version and merge it.
2. Tag the commit and push the tag: `git tag v0.1.0 && git push origin v0.1.0`.
3. Check out the tag in a clean checkout.
4. Build, sign, notarize and publish:

```sh
sh scripts/release.sh --publish v0.1.0
```

The script prints one line per stage: `signed`, `notarized`, `stapled` and `packed`. Notarization takes some
minutes for each of the two submissions (the app, then the DMG). If a credential is missing, the script stops
before the build and names the missing item. If Apple rejects a submission, the script prints the submission
ID and the `notarytool log`, and uploads nothing. If the Release for the tag exists, the script replaces its DMG
and notes.

Without `--publish`, the script makes the signed DMG and the notes in `build/release/` only.

## Local test DMG without credentials

```sh
sh scripts/release.sh --unsigned
```

The app stays ad hoc signed and the DMG isn't notarized. macOS blocks it on other Macs. The script refuses
`--unsigned` with `--publish`. The default `./scripts/build.sh` stays ad hoc signed.

## Check a DMG

```sh
codesign --verify --strict --verbose=2 build/release/Silkweb-0.1.0.dmg
spctl -a -t open --context context:primary-signature -v build/release/Silkweb-0.1.0.dmg
xcrun stapler validate build/release/Silkweb-0.1.0.dmg
hdiutil attach build/release/Silkweb-0.1.0.dmg
codesign --verify --strict --verbose=2 "/Volumes/Silkweb 0.1.0/Silkweb.app"
xcrun stapler validate "/Volumes/Silkweb 0.1.0/Silkweb.app"
```

The DMG holds only `Silkweb.app` and the `Applications` shortcut. The `silkweb` agent helper isn't in it.

## First launch after the change of signature

The Developer ID signature gives the app a new code identity. The first time Silkweb uses the
"Silkweb Agent Grants" keychain key, macOS can ask once for access. Click **Always Allow**.
