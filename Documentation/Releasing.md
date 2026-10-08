# Release QuestBridge

A release needs Xcode, a valid **Developer ID Application** certificate with its private key in the keychain, and notarization credentials stored with Apple's `notarytool`. Credentials and signing exports must never be committed.

1. Install the official Platform Tools package into `Vendor/platform-tools` using `Scripts/bundle-adb.sh`.
2. Set the release version/build in the Xcode target and run `swift test`.
3. Build and sign the universal application (the script intentionally refuses to overwrite an existing `dist/QuestBridge.app`):

   ```sh
   SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' Scripts/prepare-release.sh
   ```

4. Submit the resulting ZIP. Replace the example profile with your saved keychain profile:

   ```sh
   xcrun notarytool submit dist/QuestBridge-1.0.0-macOS.zip --keychain-profile YOUR_PROFILE --wait
   ```

5. Only after Apple reports **Accepted**, staple and validate the app, then recreate the ZIP so it includes the ticket:

   ```sh
   xcrun stapler staple dist/QuestBridge.app
   xcrun stapler validate dist/QuestBridge.app
   codesign --verify --deep --strict --verbose=2 dist/QuestBridge.app
   spctl --assess --type execute --verbose=2 dist/QuestBridge.app
   ditto -c -k --sequesterRsrc --keepParent dist/QuestBridge.app dist/QuestBridge-1.0.0-macOS.zip
   (cd dist && shasum -a 256 QuestBridge-1.0.0-macOS.zip > SHA256SUMS.txt)
   ```

6. Commit source, screenshot, icon, and documentation. Tag the release and upload the ZIP plus `SHA256SUMS.txt` to GitHub Releases. Keep `dist`, build products, keychain credentials, and local Xcode user settings out of Git.

The stable release bundle identifier is `io.github.mingistech.QuestBridge`. The earlier development placeholder identifier used a different preferences domain, so upgrading from that development build starts with fresh preferences.

Apple's [notarization workflow documentation](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) describes submissions, logs, and stapling. An unsigned development build is not a notarized release.
