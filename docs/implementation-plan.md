# Menu Bar Monitor Implementation Plan

**Goal:** Build and package the approved native menu bar monitor.

**Architecture:** `MonitorCore` owns measurement models, calculations, and system collectors. `OrbitMonitor` owns the AppKit status item, SwiftUI popover, chart, and process actions. Core returns optional readings so the UI can show capability failures honestly.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Charts, Darwin/Mach, IOKit, Swift Package Manager.

**Spec:** `docs/design.md`

## Tasks

1. Create the package and write failing tests for CPU deltas, network deltas, pace thresholds, GPU count JSON, and HID battery parsing. Implement the pure model code until tests pass.
2. Add CPU, memory, disk, network, battery, peripheral, thermal, GPU metadata, and process collectors. Keep unsupported measurements optional and refresh expensive queries slowly.
3. Build the AppKit status item and SwiftUI popover with animated animal, cards, dual network chart, battery rings, process menu, shortcut menu, and preferences.
4. Package a menu bar `.app`, document build/run behavior and device capability limits, run the complete test suite and app build.

## Review Focus

- Counter reset or sleep: rates must not spike or become negative.
- Unsupported GPU/temperature/peripheral battery: display unavailable rather than a made-up value.
- Exiting process or reused PID: destructive actions must check the target at invocation time.
- Reduced Motion and animation pause: status item must remain readable without animation.
- Long run: retain bounded network and CPU history.
