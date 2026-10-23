# Menu Bar Monitor Design

The approved prototype is a macOS menu bar monitor. The status item contains only an animated animal. A left click opens a SwiftUI popover, and a right click opens an AppKit shortcut menu for changing the animal, pausing animation, opening settings, and quitting.

The popover displays CPU load and core topology, GPU core count and an optional activity reading, memory, disk, network upload/download history, thermal state and optional sensor temperatures, Mac battery and circular peripheral batteries, and high resource processes. Numbers come from live collectors. A missing or unsupported reading is shown as unavailable, never replaced with a sample value.

The collectors use Mach CPU and VM counters, Foundation disk capacity, IOKit storage counters and power sources, HID registry, ProcessInfo thermal state, and System Profiler GPU metadata. GPU activity is optional and sourced from IOAccelerator statistics where available. The validated Mac14,2 reads CPU and GPU temperatures from specific SMC keys; other models and missing readings remain unavailable. Bluetooth HID batteries appear only when their registry entries report a percentage. The process menu retains reveal, copy name/PID, terminate, and force quit, with confirmation for force quit and clear errors for unavailable actions.

The app is a Swift Package executable with AppKit lifecycle and SwiftUI views. A packaging script creates a menu bar `.app` with `LSUIElement`. The UI targets macOS 14 and later. Sampling uses one second for CPU/GPU/network and a slower interval for temperatures and other metrics. Charts retain a bounded history in memory.
