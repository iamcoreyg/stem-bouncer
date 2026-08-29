# StemBouncer

StemBouncer is a personal macOS 14+ utility that drives Logic Pro through macOS Accessibility to export wet stem groups with the same signal path as soloing and bouncing by hand.

This repository is published for reference and personal use. No open-source license or permission to redistribute the app is granted.

## What is implemented

- Role/attribute-based Logic track discovery without modifying the session
- Ordered, overlapping stem groups with explicit contribute-only membership
- One-group-per-track and Track Stack/folder defaults
- Name-matched reusable presets
- Preflight for Accessibility, Logic, output-folder access, exposed solo-safe/solo-lock state, metronome, and cycle state
- Focus guard that pauses before sending keys to another app
- Sequential solo → offline bounce → file-stability wait → unsolo loop
- Versioned `Session - Take NN` output directories
- State persisted after every transition, including interruption recovery
- Incremental `manifest.json` with group makeup, observed dialog labels, Logic version, timestamps, output names, and summing caveat
- Dry-run mode, derived bounce timeout, diagnostics screenshots, sound, and macOS completion notification
- A focused macOS workflow for moving song-by-song through an album: reuse the current stem set, review only exceptions, then export

## Build the app

```sh
./Scripts/build-app.sh
open dist/StemBouncer.app
```

For a Developer ID release build on a Mac with the certificate installed:

```sh
SIGN_IDENTITY="Developer ID Application: Corey Griffin (7D2JL8JH4Z)" ./Scripts/build-app.sh
```

The built app is unsandboxed because Accessibility automation and synthesized key events are core to its job. On first use, macOS will ask you to allow StemBouncer in **System Settings → Privacy & Security → Accessibility**.

## First run

1. Open the Logic session and make one manual bounce to establish the desired file format, sample rate, normalization, range/tail behavior, and destination.
2. Open StemBouncer, grant Accessibility access, and choose **Read Open Logic Session**.
3. Choose a saved Stem Set or start from Track Stacks. Open any stem to adjust membership; **Processing contributor** keeps a sidechain/support track active and audible by design.
4. Choose the parent output folder. Each run creates a fresh take directory and navigates Logic's save panel there.
5. Run a **Dry run** first. Then disable Dry run and choose **Review & Export**.

Do not interact with the computer during a bounce run. If focus leaves Logic, StemBouncer pauses immediately. It remembers an actively soloed group and resets that group before resuming.

## Logic key commands

Defaults are the standard `S` for Solo and `Command-B` for Bounce. Custom mappings can be represented as macOS virtual key codes in StemBouncer Settings.

## Important audio caveat

Isolated passes through nonlinear shared-bus processing may not sum back to the mix. Reverb, delay, chorus, and EQ are linear for this purpose; compressors, limiters, gates, and saturation generally are not. This matches manual solo-and-bounce behavior.

## Development

```sh
swift test
swift run StemBouncer
```

The first real-Logic validation should use a disposable test session and Accessibility Inspector. Logic's AX labels can vary by release and localization; the discovery code intentionally searches by roles and named attributes rather than coordinates or child indexes.
