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

package dev.dazzle.experiment.objectbox

import io.objectbox.annotation.Entity
import io.objectbox.annotation.Id
import io.objectbox.annotation.Index
import io.objectbox.annotation.Unique

@Entity
data class ReadingEntity(
    @Id var id: Long = 0,
    @Index var minute: Int = 0,
    var temp: Double = 0.0,
    var humidity: Double = 0.0,
    var anomalous: Boolean = false,
)

@Entity
data class StatsEntity(
    @Id var id: Long = 0,
    @Unique var key: String = "",
    var value: Double = 0.0,
)

@Entity
data class AnomalyEntity(
    @Id var id: Long = 0,
    @Unique var minute: Int = 0,
)

@Entity
data class DecisionEntity(
    @Id var id: Long = 0,
    @Unique var cpIndex: Int = 0,
    var decision: String = "",
)

@Entity
data class CheckpointEntity(
    @Id var id: Long = 0,
    @Unique var cpIndex: Int = 0,
    var minute: Int = 0,
    var anomaly: Boolean = false,
    var severity: String = "",
    var trend: String = "",
)
