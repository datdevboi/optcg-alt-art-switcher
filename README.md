# OPTCG Alt Art Switcher

**A free, local macOS utility for reapplying your preferred One Piece TCG Simulator card art after a simulator update.** It never uploads your collection or changes the files in your source collection.

> **Unofficial software:** OPTCG Alt Art Switcher is not affiliated with, endorsed by, or sponsored by Bandai, One Piece, or OPTCGSim. You must provide your own legally obtained simulator and card-art files. This project does not include or distribute card artwork or the simulator.

## Install on your Mac

Requires macOS 13 (Ventura) or later, on either an Apple Silicon or Intel Mac.

1. Go to the [latest release](../../releases/latest) and download `OPTCG Alt Art Switcher-<version>.zip`.
2. Double-click the downloaded ZIP file, then drag **OPTCG Alt Art Switcher** into your **Applications** folder.
3. Open the app from Applications. Because the app is unsigned, macOS will block the first launch: go to **System Settings → Privacy & Security** and choose **Open Anyway**, then confirm **Open**. This is needed only once.
4. Select your **OP TCG Card Collection** folder and your **OPTCGSim.app** application.
5. Click **Refresh & Apply**. The app finds your artwork, saves the automatic choice for each card, and updates the simulator.

Use **Review** to choose a different version of any card, including DON cards. Use **Restore Originals** to undo the latest compatible installation session.

### Updating

Updates are manual. Download the newest ZIP from the [Releases](../../releases) page, replace the copy in Applications, and open it normally. Your saved choices and backups remain in `~/Library/Application Support/OPTCGAltArtSwitcher`.

### Troubleshooting

- **macOS says the app cannot be opened:** This is expected on the first launch because the app is unsigned. Make sure you downloaded it from this project’s Releases page, then open **System Settings → Privacy & Security** and choose **Open Anyway**. You only need to do this once.
- **The simulator or collection cannot be found:** Click the matching location in the sidebar and select it again. Choose the `OPTCGSim.app` bundle itself, not its contents.
- **Changes do not appear:** Quit OPTCGSim before clicking **Refresh & Apply**, then start the simulator again.
- **Want to undo changes?** Open the app and choose **Restore Originals**.

## Build from source (advanced)

This option is only for people comfortable using Terminal and Xcode Command Line Tools.

```sh
git clone https://github.com/datdevboi/optcg-alt-art-switcher.git
cd optcg-alt-art-switcher
swift run AltArtCoreValidation
scripts/build-app.sh
open "dist/OPTCG Alt Art Switcher.app"
```

For a release-quality universal app, build on a Mac with full Xcode installed:

```sh
ARCHS="arm64 x86_64" VERSION=1.0.0 scripts/build-app.sh
```

## For maintainers: publishing a release

The GitHub Actions release workflow runs when a tag such as `v1.0.0` is pushed. It validates the core logic, builds a universal app, verifies the archive, and publishes the ZIP plus a SHA-256 checksum.

The downloadable app is unsigned and is not notarized by Apple. Its GitHub Release and these installation instructions are the source of trust; users must complete the one-time **Open Anyway** step above. No Apple Developer Program membership or repository secrets are required.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
