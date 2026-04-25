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

package dev.dazzle.sdk

/**
 * Type-safe wrapper around a Valkey geospatial index. Obtain via
 * `valkey.geo("key")`.
 *
 * Geospatial keys are a specialisation of sorted sets: each member has a
 * (longitude, latitude) coordinate and Valkey stores it as an interleaved
 * geohash. Valkey 8 supports box / radius / sphere queries via GEOSEARCH
 * plus legacy GEORADIUSBYMEMBER for backwards compatibility.
 *
 * Relevant for edge workloads where the agent associates sensor readings
 * with a location: "give me the anomalies within 5 km of the current
 * device" is one `geo.searchByRadius` call on the client side.
 *
 * ```kotlin
 * val sensors = valkey.geo("sensors:location")
 *
 * sensors.add(longitude = -58.3816, latitude = -34.6037, member = "buenos-aires-01")
 * sensors.add(longitude = -58.4120, latitude = -34.6200, member = "buenos-aires-02")
 *
 * val nearby = sensors.searchByRadius(
 *     longitude = -58.4000, latitude = -34.6100,
 *     radius = 5.0, unit = GeoKey.Unit.KM,
 * )
 * ```
 */
class GeoKey internal constructor(
    val key: String,
    private val server: DazzleServer,
) {
    /** Distance unit for GEO commands. */
    enum class Unit(internal val token: String) {
        M("m"), KM("km"), MI("mi"), FT("ft")
    }

    /** A geocoded member with its coordinates. */
    data class Location(val member: String, val longitude: Double, val latitude: Double)

    /** A member returned by a search with the associated distance from the query point. */
    data class ScoredLocation(
        val member: String,
        val distance: Double,
        val unit: Unit,
    )

    /** GEOADD key longitude latitude member — returns true if the member is new. */
    @Suppress("FunctionName")
    fun add(longitude: Double, latitude: Double, member: String): Boolean {
        val n = server.commandTyped(
            "GEOADD", key, longitude.toString(), latitude.toString(), member
        ).asLongOrNull() ?: 0L
        return n == 1L
    }

    /** GEOPOS key m1 [m2 …] — returns the coordinates for each member (null if absent). */
    fun position(vararg members: String): List<Location?> {
        if (members.isEmpty()) return emptyList()
        val args = arrayOf("GEOPOS", key, *members)
        val items = server.commandTyped(*args).asArray()
        return members.mapIndexed { i, m ->
            val pair = items.getOrNull(i)?.asArray() ?: return@mapIndexed null
            if (pair.size < 2) return@mapIndexed null
            val lon = pair[0].asBulkOrNull()?.toDoubleOrNull() ?: return@mapIndexed null
            val lat = pair[1].asBulkOrNull()?.toDoubleOrNull() ?: return@mapIndexed null
            Location(member = m, longitude = lon, latitude = lat)
        }
    }

    /** GEODIST key m1 m2 [unit] — distance between two members. */
    fun distance(a: String, b: String, unit: Unit = Unit.M): Double? =
        server.commandTyped("GEODIST", key, a, b, unit.token).asBulkOrNull()?.toDoubleOrNull()

    /**
     * GEOSEARCH key FROMLONLAT lon lat BYRADIUS radius unit
     *
     * Returns the members within [radius] of the given point. Use
     * [searchByRadiusWithDistances] to also get each member's distance.
     */
    fun searchByRadius(
        longitude: Double,
        latitude: Double,
        radius: Double,
        unit: Unit = Unit.M,
        count: Long? = null,
    ): List<String> {
        val args = mutableListOf(
            "GEOSEARCH", key,
            "FROMLONLAT", longitude.toString(), latitude.toString(),
            "BYRADIUS", radius.toString(), unit.token,
            "ASC",
        )
        if (count != null) { args += "COUNT"; args += count.toString() }
        return server.commandTyped(*args.toTypedArray())
            .asArray()
            .mapNotNull { it.asBulkOrNull() }
    }

    /** Same as [searchByRadius] but each entry includes its distance from the query point. */
    fun searchByRadiusWithDistances(
        longitude: Double,
        latitude: Double,
        radius: Double,
        unit: Unit = Unit.M,
        count: Long? = null,
    ): List<ScoredLocation> {
        val args = mutableListOf(
            "GEOSEARCH", key,
            "FROMLONLAT", longitude.toString(), latitude.toString(),
            "BYRADIUS", radius.toString(), unit.token,
            "ASC", "WITHCOORD", "WITHDIST",
        )
        if (count != null) { args += "COUNT"; args += count.toString() }
        val items = server.commandTyped(*args.toTypedArray()).asArray()
        return items.mapNotNull { row ->
            val arr = row.asArray()
            if (arr.size < 2) return@mapNotNull null
            val member = arr[0].asBulkOrNull() ?: return@mapNotNull null
            val dist   = arr[1].asBulkOrNull()?.toDoubleOrNull() ?: return@mapNotNull null
            ScoredLocation(member = member, distance = dist, unit = unit)
        }
    }

    /**
     * GEORADIUSBYMEMBER key member radius unit — legacy alias for
     * searchByRadius centred on an existing member.
     */
    fun searchByRadiusOfMember(
        member: String,
        radius: Double,
        unit: Unit = Unit.M,
        count: Long? = null,
    ): List<String> {
        val args = mutableListOf(
            "GEOSEARCH", key,
            "FROMMEMBER", member,
            "BYRADIUS", radius.toString(), unit.token,
            "ASC",
        )
        if (count != null) { args += "COUNT"; args += count.toString() }
        return server.commandTyped(*args.toTypedArray())
            .asArray()
            .mapNotNull { it.asBulkOrNull() }
    }

    // ── Self-scoped meta ops ──────────────────────────────────────────────

    fun deleteKey(): Boolean =
        (server.commandTyped("DEL", key).asLongOrNull() ?: 0L) == 1L

    fun exists(): Boolean =
        (server.commandTyped("EXISTS", key).asLongOrNull() ?: 0L) == 1L
}
