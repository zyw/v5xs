# Mole GPU and temperature collection (2026-10-22)

## Evidence

- Mole for Mac is a separate, closed-source SwiftUI app. Its public repository contains documentation, not its sensor implementation; the open-source Mole CLI cannot establish precisely how the app reads temperatures. Source: https://github.com/tw93/Mole-App
- Mole CLI's GPU collector first reads GPU metadata from `system_profiler`; utilization is obtained from a separate `powermetrics` path when permitted. The collector explicitly leaves utilization unavailable if collection fails. Source: https://github.com/tw93/Mole/blob/main/cmd/status/metrics_gpu.go
- Mole's public status model has optional CPU and GPU temperatures. The locally installed Mole CLI 1.61.0 returned `gpu.usage = -1`, `thermal.cpu_temp = 0`, and `thermal.gpu_temp = 0` on this Apple M2 in the current execution context. This does not prove what Mole.app uses internally.
- On this M2, `ioreg -r -c IOAccelerator -w0 -l` exposes `PerformanceStatistics` with a changing `Device Utilization %` (82, then 79). This is an IOKit registry implementation detail rather than a documented, uniform metric for every GPU.
- `/usr/bin/powermetrics --samplers gpu_power -i 500 -n 1` fails with `powermetrics must be invoked as the superuser` in the current account.
- Apple Silicon temperature alternatives include device-specific SMC/HID sensor collection. Stats reads HID temperature events and SMC sensor keys, validates readings, and computes averages from identified CPU/GPU sensors: https://github.com/exelban/stats/blob/master/Modules/Sensors/reader.m and https://github.com/exelban/stats/blob/master/Modules/Sensors/readers.swift
- The existing app currently reads GPU core count through `system_profiler`, and thermal severity via `ProcessInfo.thermalState`. It has no GPU-utilization or Celsius-temperature collector; its dashes are deliberate placeholders.

## Implemented in OrbitMonitor

- `IOAccelerator` now supplies optional GPU utilization with a 0–100% range check and an unavailable fallback.
- On the locally verified `Mac14,2`, SMC keys `Tp01`, `Tp05`, `Tp09`, and `Tp0D` yield CPU temperatures; `Tg0f` yields a GPU temperature. Raw `flt ` readings were validated outside the execution sandbox against the local M2. Other models remain unsupported and display “—” alongside system thermal state.
- The menu-bar app does not require administrator privileges or run `powermetrics` continuously.
