# macOS public release procedure

Public artifacts use the existing bundle ID `com.felix.hushtype` and the pinned identity **Developer ID Application: Kuang Cheng Fu (8Z5RQYC6M5)**. The signing Mac needs that certificate's private key and an authorized, existing `notarytool` keychain profile. Apple Development signing does not satisfy the designated requirements of public v0.5.13/v0.5.14 builds.

Do not reset permissions or change bundle identity to bypass a failed upgrade. Do not put signing keys, credentials, local audio, transcripts or machine-specific QA evidence in Git.

## Prepare the exact source

1. Use the reviewed local commit and check `git status --short`. Keep version/build in `Resources/Info.plist`; v0.5.15 uses build 54. If runtime source changes, increment the build and rerun the affected checks.
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
codesign --force --sign 'Developer ID Application: Kuang Cheng Fu (8Z5RQYC6M5)' --timestamp Lamitype-v0.5.15.dmg
codesign --verify --verbose=2 Lamitype-v0.5.15.dmg
xcrun notarytool submit Lamitype-v0.5.15.dmg --keychain-profile "${NOTARY_PROFILE:?Set the authorized notarytool profile name}" --wait
xcrun stapler staple Lamitype-v0.5.15.dmg
xcrun stapler validate Lamitype-v0.5.15.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 Lamitype-v0.5.15.dmg
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

Record the commit, version/build, final DMG digest, signing/notarization receipts and outcomes before declaring release readiness. Mark every check as passed, failed or not run, with its actual environment. Static designated-requirement compatibility does not certify TCC continuity; a command-line download/signature check does not certify clean-account first use through browser quarantine. Publication does not turn an unperformed check into a pass.

## Publish, verify and close

Publication/tagging/pushing requires user instruction. Once authorized:

1. Finalize both READMEs and the bilingual release body, Traditional Chinese first. Scan all three for U+2014/U+2013; each must contain zero. Review the staged diff so internal workstreams, credentials and QA recordings stay excluded from the public repo.
2. Squash-merge the reviewed scoped branch, then create and push an annotated version tag on that main commit. Confirm its version/build matches the signed artifact. Documentation-only corrections after release do not move the tag or require a new binary.
3. Publish the stable GitHub Release with that exact body and signed, notarized DMG. Verify its asset name and SHA-256.
4. Check website copy, FAQ/JSON-LD, llms.txt and localized media against the release. Use the site's GitHub-to-Cloudflare Workers Builds pipeline. Check both `/download?lang=zh` and `/download?lang=en` response headers for the new DMG. If a fallback occurs, record its reason and verify `releases/latest` reaches the new release; report fallback separately from direct-DMG success. Verify the legacy byfkc redirect without reviving the retired README sync.
5. Download the public DMG independently, compare its SHA-256 and attach it read-only. Verify the mounted app's deep-strict signature, staple, Gatekeeper acceptance and bundle version. Quit the installed app, retain its exact bundle in a temporary rollback location, install the mounted app with `ditto`, and require mounted/installed executable hashes and signatures to match. Launch the installed public app and record the rollback disposition.
6. Mark the local release draft SHIPPED; update Build Status, Product and GTM indexes, the architecture guide's Recently Shipped entry, and the site's canonical GTM/deployment records. Close the originating build-machine handoff so an older unsigned/development candidate cannot be mistaken for the public installer. Preserve dated evidence and explicitly carry forward incomplete manual coverage.

The bilingual [v0.5.15 notes](releases/v0.5.15.md) are published release documentation. Machine-specific execution evidence and coverage exceptions belong in the local release record.
