# OPTCG Alt Art Switcher

A local macOS utility that reapplies your preferred One Piece TCG Simulator card art after a simulator update.

## Use

1. Run `scripts/build-app.sh`, then double-click `dist/OPTCG Alt Art Switcher.app`.
2. Confirm the defaults point to your `OP TCG Card Collection` folder and `OPTCGSim.app`.
3. The app automatically loads the saved collection every time it opens. On first use, choose the collection folder and simulator; those locations and every automatically chosen card are saved right away. After adding or changing artwork files, use **Refresh & Apply**: it discovers new card IDs, saves their built-in rarity choice (**Manga → SP → Alt Art → Base**), and updates the simulator. Use the set dropdown in **Review** to browse cards and override any automatic pick.
4. The **Review** workspace includes the dedicated **DON card** section, where one artwork is chosen for every DON card in the simulator.

When choosing cards one at a time, selecting an artwork automatically opens the next card that still needs a choice. **Cancel** stops this quick-pick flow at any point.
5. Quit OPTCGSim before changing artwork. Selections made in **Review** install automatically.

Use **Review** any time you want to switch an existing card to a different version. Use **Restore originals** to revert the most recent compatible install session.

The app leaves the source collection untouched. Settings, backups, and session manifests live in `~/Library/Application Support/OPTCGAltArtSwitcher`.

## Development

```sh
swift run AltArtCoreValidation
scripts/build-app.sh
```

For a read-only check against the current local collection and simulator:

```sh
swift run AltArtCoreValidation --scan-current
```

The scanner accepts parenthesized image filenames such as `OP07-099(Custom).png`, `OP11-067(3rdAnn).png`, and `P-093(Custom).png`. It installs the matching existing simulator formats (`.png`/`.jpg` full art and `_small.jpg` thumbnails) at their original pixel dimensions.
