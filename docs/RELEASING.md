# macOS public release procedure

Public artifacts use the existing bundle ID `com.felix.hushtype` and the pinned identity **Developer ID Application: Kuang Cheng Fu (8Z5RQYC6M5)**. The signing Mac needs that certificate's private key and an authorized, existing `notarytool` keychain profile. Apple Development signing does not satisfy the designated requirements of public v0.5.13/v0.5.14 builds.

Do not reset permissions or change bundle identity to bypass a failed upgrade. Do not put signing keys, credentials, local audio, transcripts or machine-specific QA evidence in Git.

## Prepare the exact source

1. Use the reviewed local commit and check `git status --short`. Keep version/build in `Resources/Info.plist`; v0.5.15 uses build 52. If runtime source changes, increment the build and rerun the affected checks.
2. Run the regression and source checks below. Optional model/audio/permission tests require their documented opt-in environment and separate evidence; skips do not certify those paths.

```sh
swift test --disable-sandbox
make l10n-verify
python3 scripts/check_rename_closure.py
git diff --check
```

## Sign and notarize on the release Mac

Set `NOTARY_PROFILE` to the name of the authorized keychain profile; its value is a profile name, never a password. These commands prepare artifacts locally and do not publish a release.

```sh
make check-release-signing SIGN_IDENTITY='Developer ID Application: Kuang Cheng Fu (8Z5RQYC6M5)'
make bundle-release SIGN_IDENTITY='Developer ID Application: Kuang Cheng Fu (8Z5RQYC6M5)'
codesign --verify --deep --strict --verbose=2 Lamitype.app
codesign -dv --verbose=4 Lamitype.app
codesign -d -r- Lamitype.app

mkdir -p .build/release-artifacts
ditto -c -k --keepParent Lamitype.app .build/release-artifacts/Lamitype-notarization.zip
xcrun notarytool submit .build/release-artifacts/Lamitype-notarization.zip --keychain-profile "${NOTARY_PROFILE:?Set the authorized notarytool profile name}" --wait
xcrun stapler staple Lamitype.app
xcrun stapler validate Lamitype.app
spctl --assess --type execute --verbose=4 Lamitype.app

make create-dmg
xcrun notarytool submit Lamitype-v0.5.15.dmg --keychain-profile "${NOTARY_PROFILE:?Set the authorized notarytool profile name}" --wait
xcrun stapler staple Lamitype-v0.5.15.dmg
xcrun stapler validate Lamitype-v0.5.15.dmg
hdiutil verify Lamitype-v0.5.15.dmg
shasum -a 256 Lamitype-v0.5.15.dmg
```

Stop if any command fails or either notarization is not Accepted. Read that submission's notarization log rather than continuing. Confirm the app reports the pinned Developer ID authority, Team ID `8Z5RQYC6M5`, hardened runtime and a secure timestamp. Verify the app extracted from the final DMG again with deep-strict codesign, staple validation, Gatekeeper assessment and bundled localization checks. Nothing may mutate signed executable/resources after signing; stapling tickets is expected.

The Makefile intentionally leaves development targets available, but only `bundle-release` / `dmg-release` enforce the public identity. Never distribute the development DMG as the public installer. Packaging does not replace the running application.

## Actual upgrade and first-use check

Use a disposable macOS account with the official v0.5.13 release installed, then repeat for v0.5.14. Grant permissions normally to the old public app, configure representative settings and confirm a recording works. Upgrade through the final DMG in the usual way, without a TCC reset, retaining the same bundle location.

- Verify permission continuity and successful hotkey/microphone use. The new app must satisfy each baseline's actual designated requirement; the same Team ID alone is insufficient evidence.
- Confirm engine, language, conversion, dictionary, prompts, Auto Polish, indicator preference, credentials and cached model remain intact. Local recognition must work offline with the existing cache.
- With no saved Live/Standard choice, confirm Live is on and the first unconfirmed hold shows the cap reminder before capture. Exercise Cancel and Don't show again across relaunch. Explicit Standard/Live choices must survive.
- Check menu/Settings synchronization, one short Live recording, a full cap, Standard recording, original-field paste and changed-field Copy-only recovery. Exercise failed-final Save/Retry/Discard in a separately identified debug build when fault injection is required; debug hooks are excluded from release builds.
- Cloud startup must keep its selected provider, load no local model on cold launch and retain its existing consent flow. A real provider test requires a test key and authorized spend; cold-start checks do not certify provider transcription.
- On a clean account, confirm normal first-run permissions, model setup and reminder. Check the final DMG's Gatekeeper behavior through an actual download/quarantine path.

Record the commit, version/build, final DMG digest, signing/notarization receipts and outcomes before declaring release readiness. Publication/tagging/pushing is a separate step requiring user instruction. The bilingual [v0.5.15 notes](releases/v0.5.15.md) remain marked candidate until those gates pass.
