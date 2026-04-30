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
import ObjectBox

// MARK: - ObjectBox entities for the IoT monitoring agent benchmark.
//
// These mirror ReadingEntity/StatsEntity/AnomalyEntity/DecisionEntity/
// CheckpointEntity in experiment/backends/android/objectbox/, adapted to
// ObjectBox-Swift conventions:
//   - Each model class is annotated `// objectbox: entity` so the
//     OBXCodeGen Sourcery pass picks it up and emits the
//     EntityInfo / EntityBinding extensions in EntityInfo.generated.swift.
//   - The `id` property is the primary key (`Id` typealias = UInt64).
//   - String/Bool/Int/Double map directly; ObjectBox-Swift handles
//     FlatBuffer (de)serialization through the generated binding.

// objectbox: entity
class ReadingEntity {
    var id: Id = 0
    var minute: Int = 0
    var temp: Double = 0.0
    var humidity: Double = 0.0
    var anomalous: Bool = false
}

// objectbox: entity
class StatsEntity {
    var id: Id = 0
    var key: String = ""
    var value: Double = 0.0
}

// objectbox: entity
class AnomalyEntity {
    var id: Id = 0
    var minute: Int = 0
}

// objectbox: entity
class DecisionEntity {
    var id: Id = 0
    var cpIndex: Int = 0
    var decision: String = ""
}

// objectbox: entity
class CheckpointEntity {
    var id: Id = 0
    var cpIndex: Int = 0
    var minute: Int = 0
    var anomaly: Bool = false
    var severity: String = ""
    var trend: String = ""
}
