// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// SystemSnapshot — device hardware + battery state for JSON payloads.
// Shared by the LLM experiment (ExperimentPipelineIoT) and the storage-only
// harness (StorageOnlyTest). Keys mirror the Android collectDeviceInfo()
// / snapshotBattery() helpers so a single downstream analyser consumes both
// platforms' JSONs.
// ─────────────────────────────────────────────────────────────────────────────

enum SystemSnapshot {

    /// Numbers are bridged via NSNumber because this dict gets embedded inside
    /// an outer [String: Any]; raw Swift ints become __SwiftValue once nested
    /// and JSONSerialization refuses them.
    static func deviceInfo() -> [String: Any] {
        let device  = UIDevice.current
        let process = ProcessInfo.processInfo

        // Machine identifier (e.g. "iPhone13,3" → iPhone 12 Pro). Kept separate
        // from the user-visible model name so downstream scripts can match on
        // a stable hardware key.
        var machine: String = "unknown"
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.machine", &buf, &size, nil, 0) == 0 {
                machine = String(cString: buf)
            }
        }

        var storageTotal: Int64 = 0
        var storageFree:  Int64 = 0
        if let values = try? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ]) {
            if let total = values.volumeTotalCapacity { storageTotal = Int64(total) }
            if let free  = values.volumeAvailableCapacityForImportantUsage { storageFree = free }
        }

        return [
            "model":               device.model,
            "name":                device.name,
            "system_name":         device.systemName,
            "system_version":      device.systemVersion,
            "machine":             machine,
            "cpu_cores":           NSNumber(value: process.processorCount),
            "active_cpu_cores":    NSNumber(value: process.activeProcessorCount),
            "ram_total_bytes":     NSNumber(value: process.physicalMemory),
            "storage_total_bytes": NSNumber(value: storageTotal),
            "storage_free_bytes":  NSNumber(value: storageFree),
            "thermal_state":       String(describing: process.thermalState),
            "low_power_mode":      NSNumber(value: process.isLowPowerModeEnabled),
            "platform":            "iOS"
        ]
    }

    /// Battery level + charging state. Enabling `isBatteryMonitoringEnabled`
    /// is a no-op if already on; leave it enabled for the duration of the
    /// experiment so both snapshots are comparable.
    static func batterySnapshot() -> [String: Any] {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let d = UIDevice.current
        let stateString: String
        switch d.batteryState {
        case .unknown:    stateString = "unknown"
        case .unplugged:  stateString = "unplugged"
        case .charging:   stateString = "charging"
        case .full:       stateString = "full"
        @unknown default: stateString = "unknown"
        }
        return [
            // -1.0 means unavailable (simulator or permission denied); pass
            // through verbatim so the analyser tells "unknown" apart from 0%.
            "level":     NSNumber(value: d.batteryLevel),
            "state":     stateString,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
    }
}
