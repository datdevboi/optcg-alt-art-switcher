# OPTCG Alt Art Switcher

**A free Mac app that puts your preferred One Piece TCG Simulator card art back after a simulator update.**

It runs only on your Mac. It does not upload your collection or change the artwork files you keep in your collection folder.

> **Unofficial tool:** OPTCG Alt Art Switcher is not made by, approved by, or connected with Bandai, One Piece, or OPTCGSim. You need your own legally obtained simulator and card-art files. This project does not include either one.

## Before you start

You need a Mac running macOS 13 (Ventura) or newer, your installed `OPTCGSim.app`, and your own **OP TCG Card Collection** folder.

It works on both Apple Silicon Macs (M-series) and Intel Macs.

## Install on your Mac

1. Visit the [latest release](../../releases/latest) and download the file ending in `.zip`.
2. Double-click the ZIP file in Downloads.
3. Drag **OPTCG Alt Art Switcher** into your **Applications** folder.
4. Open it from Applications.

### The first time you open it

Because the app is unsigned, macOS will block the first launch. This is normal for a free app downloaded outside the App Store.

1. Try to open the app, then dismiss the message that appears.
2. Open **System Settings → Privacy & Security**.
3. Scroll down and click **Open Anyway** next to OPTCG Alt Art Switcher.
4. Click **Open** to confirm.

You only need to do this once.

## Use the app

[Watch the video tutorial (MOV, 56 MB)](https://github.com/datdevboi/optcg-alt-art-switcher/releases/download/v1.0.1/alt.art.switcher.tutorial.mov)

1. Choose your **OP TCG Card Collection** folder in the **Collection** area.
2. Choose your `OPTCGSim.app` in the **Simulator** area.
3. Quit OPTCGSim if it is open.
4. Click **Refresh & Apply**.

The app finds your artwork and chooses the best available version for each card. Your choices are saved, so opening the app again will remember them.

### Pick different art

Open **Review** to browse card art by set, choose a different version, or set your preferred DON card. Changes are installed automatically.

### Undo your changes

Choose **Restore Originals** in the app to put back the original simulator artwork from your most recent compatible installation session.

## Updating the app

Download the newest ZIP from the [Releases](../../releases) page and replace the older copy in Applications. Your saved choices and backups stay in place.

## Need help?

- **I cannot open the app:** Follow the one-time **Open Anyway** steps above. Only use this option if you downloaded the app from this project’s Releases page.
- **I cannot find my simulator:** Choose the `OPTCGSim.app` application itself—not a folder inside it.
- **My artwork did not change:** Quit OPTCGSim, click **Refresh & Apply**, then start the simulator again.
- **I want to undo this:** Open the app and select **Restore Originals**.

## For developers and maintainers

### Build from source

You need Terminal and Xcode Command Line Tools.

```sh
git clone https://github.com/datdevboi/optcg-alt-art-switcher.git
cd optcg-alt-art-switcher
swift run AltArtCoreValidation
scripts/build-app.sh
open "dist/OPTCG Alt Art Switcher.app"
```

To build a release-quality app for both Apple Silicon and Intel Macs, use a Mac with full Xcode installed:

```sh
ARCHS="arm64 x86_64" VERSION=1.0.0 scripts/build-app.sh
```

### Publish a release

Push a tag such as `v1.0.0`. GitHub Actions validates the app, builds the download, creates a checksum, and publishes a GitHub Release.

The published app is unsigned and not notarized by Apple. Keep the first-launch instructions above in every release so users know how to open it safely.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
