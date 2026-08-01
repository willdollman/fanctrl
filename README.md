# FanCtrl PlusPlus

FanCtrl PlusPlus is an independently installable Unraid plugin for automatic PWM fan control based on HDD, NVMe, Unassigned Devices, and optional CPU temperatures. It supports per-fan temperature sources and thresholds, quiet mode, labels, and dashboard monitoring.

> **Hardware safety:** uninstall or disable every other fan controller before using FanCtrl PlusPlus. FanCtrl PlusPlus has a separate plugin and filesystem identity and can coexist with other plugins, but two controllers must never drive the same PWM hardware.

## Install

Paste this URL into **Unraid → Plugins → Install Plugin**:

```text
https://raw.githubusercontent.com/willdollman/fanctrl/main/unraid/fanctrlplusplus.plg
```

Releases and issues are hosted at [github.com/willdollman/fanctrl](https://github.com/willdollman/fanctrl).

## Release

1. Merge reviewed changes to `main` and ensure the working tree is clean.
2. Run the **Release** workflow manually and enter a semantic version without a leading `v` (for example, `2.0.0`).
3. The workflow checks out `main`, rejects an existing tag/release, builds the deterministic package, updates the manifest version and MD5, commits that manifest as `github-actions[bot]`, tags and pushes it, then creates the GitHub release with the `.txz` asset.

The workflow requires `contents: write`; a protected `main` branch must permit the GitHub Actions bot to push the release commit and tag.

For a local package build:

```bash
scripts/build-package.sh 2.0.0 dist
```

## Attribution and licensing

FanCtrl PlusPlus originated as a fork of [ck9393/fanctrlplus](https://github.com/ck9393/fanctrlplus). The upstream project currently has no visible license. No license is added here; clarification of redistribution terms is a blocker before submitting FanCtrl PlusPlus to Community Applications.
