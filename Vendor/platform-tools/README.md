# Official Android Platform Tools

Place the official macOS Platform Tools archive contents in this directory. Xcode copies this entire folder into `QuestBridge.app/Contents/Resources/platform-tools`, preserving executable permissions, `NOTICE.txt`, `source.properties`, and `lib64`.

This working copy uses Google's 37.0.1 package, downloaded from https://dl.google.com/android/repository/platform-tools-latest-darwin.zip on October 7, 2026.

Archive SHA-256: `ee39ad5967e95c2a07f04dbcbde96b1a0c916ba376096db5d2f498b7727a5d1d`.

Binaries are excluded from Git. Run `Scripts/bundle-adb.sh /path/to/platform-tools` to populate another checkout using an official extracted package. The complete upstream notices and accompanying files must travel with it. Review Google's applicable terms before redistribution.
