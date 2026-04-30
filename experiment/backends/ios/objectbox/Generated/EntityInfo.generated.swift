// Generated using the ObjectBox Swift Generator — https://objectbox.io
// DO NOT EDIT
// swiftlint:disable all
import ObjectBox
import Foundation

// MARK: - Entity metadata

extension AnomalyEntity: ObjectBox.Entity {}
extension CheckpointEntity: ObjectBox.Entity {}
extension DecisionEntity: ObjectBox.Entity {}
extension ReadingEntity: ObjectBox.Entity {}
extension StatsEntity: ObjectBox.Entity {}

extension AnomalyEntity: ObjectBox.__EntityRelatable {
    internal typealias EntityType = AnomalyEntity

    internal var _id: EntityId<AnomalyEntity> {
        return EntityId<AnomalyEntity>(self.id.value)
    }
}

extension AnomalyEntity: ObjectBox.EntityInspectable {
    internal typealias EntityBindingType = AnomalyEntityBinding

    /// Generated metadata used by ObjectBox to persist the entity.
    internal static let entityInfo = ObjectBox.EntityInfo(name: "AnomalyEntity", id: 1)

    internal static let entityBinding = EntityBindingType()

    fileprivate static func buildEntity(modelBuilder: ObjectBox.ModelBuilder) throws {
        let entityBuilder = try modelBuilder.entityBuilder(for: AnomalyEntity.self, id: 1, uid: 9167064991161629440)
        try entityBuilder.addProperty(name: "id", type: PropertyType.long, flags: [.id], id: 1, uid: 5731869460967938304)
        try entityBuilder.addProperty(name: "minute", type: PropertyType.long, id: 2, uid: 6107458320019732480)

        try entityBuilder.lastProperty(id: 2, uid: 6107458320019732480)
    }
}

extension AnomalyEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { AnomalyEntity.id == myId }
    internal static var id: Property<AnomalyEntity, Id, Id> { return Property<AnomalyEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { AnomalyEntity.minute > 1234 }
    internal static var minute: Property<AnomalyEntity, Int, Void> { return Property<AnomalyEntity, Int, Void>(propertyId: 2, isPrimaryKey: false) }

    fileprivate func __setId(identifier: ObjectBox.Id) {
        self.id = Id(identifier)
    }
}

extension ObjectBox.Property where E == AnomalyEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .id == myId }

    internal static var id: Property<AnomalyEntity, Id, Id> { return Property<AnomalyEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .minute > 1234 }

    internal static var minute: Property<AnomalyEntity, Int, Void> { return Property<AnomalyEntity, Int, Void>(propertyId: 2, isPrimaryKey: false) }

}


/// Generated service type to handle persisting and reading entity data. Exposed through `AnomalyEntity.EntityBindingType`.
internal final class AnomalyEntityBinding: ObjectBox.EntityBinding, Sendable {
    internal typealias EntityType = AnomalyEntity
    internal typealias IdType = Id

    internal required init() {}

    internal func generatorBindingVersion() -> Int { 1 }

    internal func setEntityIdUnlessStruct(of entity: EntityType, to entityId: ObjectBox.Id) {
        entity.__setId(identifier: entityId)
    }

    internal func entityId(of entity: EntityType) -> ObjectBox.Id {
        return entity.id.value
    }

    internal func collect(fromEntity entity: EntityType, id: ObjectBox.Id,
                                  propertyCollector: ObjectBox.FlatBufferBuilder, store: ObjectBox.Store) throws {

        propertyCollector.collect(id, at: 2 + 2 * 1)
        propertyCollector.collect(entity.minute, at: 2 + 2 * 2)
    }

    internal func createEntity(entityReader: ObjectBox.FlatBufferReader, store: ObjectBox.Store) -> EntityType {
        let entity = AnomalyEntity()

        entity.id = entityReader.read(at: 2 + 2 * 1)
        entity.minute = entityReader.read(at: 2 + 2 * 2)

        return entity
    }
}



extension CheckpointEntity: ObjectBox.__EntityRelatable {
    internal typealias EntityType = CheckpointEntity

    internal var _id: EntityId<CheckpointEntity> {
        return EntityId<CheckpointEntity>(self.id.value)
    }
}

extension CheckpointEntity: ObjectBox.EntityInspectable {
    internal typealias EntityBindingType = CheckpointEntityBinding

    /// Generated metadata used by ObjectBox to persist the entity.
    internal static let entityInfo = ObjectBox.EntityInfo(name: "CheckpointEntity", id: 2)

    internal static let entityBinding = EntityBindingType()

    fileprivate static func buildEntity(modelBuilder: ObjectBox.ModelBuilder) throws {
        let entityBuilder = try modelBuilder.entityBuilder(for: CheckpointEntity.self, id: 2, uid: 4700891722054603264)
        try entityBuilder.addProperty(name: "id", type: PropertyType.long, flags: [.id], id: 1, uid: 3871284685631692288)
        try entityBuilder.addProperty(name: "cpIndex", type: PropertyType.long, id: 2, uid: 1427580949390599936)
        try entityBuilder.addProperty(name: "minute", type: PropertyType.long, id: 3, uid: 9164546104442581504)
        try entityBuilder.addProperty(name: "anomaly", type: PropertyType.bool, id: 4, uid: 7209664011810414080)
        try entityBuilder.addProperty(name: "severity", type: PropertyType.string, id: 5, uid: 486461122285868800)
        try entityBuilder.addProperty(name: "trend", type: PropertyType.string, id: 6, uid: 6871338352400544256)

        try entityBuilder.lastProperty(id: 6, uid: 6871338352400544256)
    }
}

extension CheckpointEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { CheckpointEntity.id == myId }
    internal static var id: Property<CheckpointEntity, Id, Id> { return Property<CheckpointEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { CheckpointEntity.cpIndex > 1234 }
    internal static var cpIndex: Property<CheckpointEntity, Int, Void> { return Property<CheckpointEntity, Int, Void>(propertyId: 2, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { CheckpointEntity.minute > 1234 }
    internal static var minute: Property<CheckpointEntity, Int, Void> { return Property<CheckpointEntity, Int, Void>(propertyId: 3, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { CheckpointEntity.anomaly == true }
    internal static var anomaly: Property<CheckpointEntity, Bool, Void> { return Property<CheckpointEntity, Bool, Void>(propertyId: 4, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { CheckpointEntity.severity.startsWith("X") }
    internal static var severity: Property<CheckpointEntity, String, Void> { return Property<CheckpointEntity, String, Void>(propertyId: 5, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { CheckpointEntity.trend.startsWith("X") }
    internal static var trend: Property<CheckpointEntity, String, Void> { return Property<CheckpointEntity, String, Void>(propertyId: 6, isPrimaryKey: false) }

    fileprivate func __setId(identifier: ObjectBox.Id) {
        self.id = Id(identifier)
    }
}

extension ObjectBox.Property where E == CheckpointEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .id == myId }

    internal static var id: Property<CheckpointEntity, Id, Id> { return Property<CheckpointEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .cpIndex > 1234 }

    internal static var cpIndex: Property<CheckpointEntity, Int, Void> { return Property<CheckpointEntity, Int, Void>(propertyId: 2, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .minute > 1234 }

    internal static var minute: Property<CheckpointEntity, Int, Void> { return Property<CheckpointEntity, Int, Void>(propertyId: 3, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .anomaly == true }

    internal static var anomaly: Property<CheckpointEntity, Bool, Void> { return Property<CheckpointEntity, Bool, Void>(propertyId: 4, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .severity.startsWith("X") }

    internal static var severity: Property<CheckpointEntity, String, Void> { return Property<CheckpointEntity, String, Void>(propertyId: 5, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .trend.startsWith("X") }

    internal static var trend: Property<CheckpointEntity, String, Void> { return Property<CheckpointEntity, String, Void>(propertyId: 6, isPrimaryKey: false) }

}


/// Generated service type to handle persisting and reading entity data. Exposed through `CheckpointEntity.EntityBindingType`.
internal final class CheckpointEntityBinding: ObjectBox.EntityBinding, Sendable {
    internal typealias EntityType = CheckpointEntity
    internal typealias IdType = Id

    internal required init() {}

    internal func generatorBindingVersion() -> Int { 1 }

    internal func setEntityIdUnlessStruct(of entity: EntityType, to entityId: ObjectBox.Id) {
        entity.__setId(identifier: entityId)
    }

    internal func entityId(of entity: EntityType) -> ObjectBox.Id {
        return entity.id.value
    }

    internal func collect(fromEntity entity: EntityType, id: ObjectBox.Id,
                                  propertyCollector: ObjectBox.FlatBufferBuilder, store: ObjectBox.Store) throws {
        let propertyOffset_severity = propertyCollector.prepare(string: entity.severity)
        let propertyOffset_trend = propertyCollector.prepare(string: entity.trend)

        propertyCollector.collect(id, at: 2 + 2 * 1)
        propertyCollector.collect(entity.cpIndex, at: 2 + 2 * 2)
        propertyCollector.collect(entity.minute, at: 2 + 2 * 3)
        propertyCollector.collect(entity.anomaly, at: 2 + 2 * 4)
        propertyCollector.collect(dataOffset: propertyOffset_severity, at: 2 + 2 * 5)
        propertyCollector.collect(dataOffset: propertyOffset_trend, at: 2 + 2 * 6)
    }

    internal func createEntity(entityReader: ObjectBox.FlatBufferReader, store: ObjectBox.Store) -> EntityType {
        let entity = CheckpointEntity()

        entity.id = entityReader.read(at: 2 + 2 * 1)
        entity.cpIndex = entityReader.read(at: 2 + 2 * 2)
        entity.minute = entityReader.read(at: 2 + 2 * 3)
        entity.anomaly = entityReader.read(at: 2 + 2 * 4)
        entity.severity = entityReader.read(at: 2 + 2 * 5)
        entity.trend = entityReader.read(at: 2 + 2 * 6)

        return entity
    }
}



extension DecisionEntity: ObjectBox.__EntityRelatable {
    internal typealias EntityType = DecisionEntity

    internal var _id: EntityId<DecisionEntity> {
        return EntityId<DecisionEntity>(self.id.value)
    }
}

extension DecisionEntity: ObjectBox.EntityInspectable {
    internal typealias EntityBindingType = DecisionEntityBinding

    /// Generated metadata used by ObjectBox to persist the entity.
    internal static let entityInfo = ObjectBox.EntityInfo(name: "DecisionEntity", id: 3)

    internal static let entityBinding = EntityBindingType()

    fileprivate static func buildEntity(modelBuilder: ObjectBox.ModelBuilder) throws {
        let entityBuilder = try modelBuilder.entityBuilder(for: DecisionEntity.self, id: 3, uid: 8816019786257580544)
        try entityBuilder.addProperty(name: "id", type: PropertyType.long, flags: [.id], id: 1, uid: 5408439932521847296)
        try entityBuilder.addProperty(name: "cpIndex", type: PropertyType.long, id: 2, uid: 90288257001896704)
        try entityBuilder.addProperty(name: "decision", type: PropertyType.string, id: 3, uid: 4181757736301419776)

        try entityBuilder.lastProperty(id: 3, uid: 4181757736301419776)
    }
}

extension DecisionEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { DecisionEntity.id == myId }
    internal static var id: Property<DecisionEntity, Id, Id> { return Property<DecisionEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { DecisionEntity.cpIndex > 1234 }
    internal static var cpIndex: Property<DecisionEntity, Int, Void> { return Property<DecisionEntity, Int, Void>(propertyId: 2, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { DecisionEntity.decision.startsWith("X") }
    internal static var decision: Property<DecisionEntity, String, Void> { return Property<DecisionEntity, String, Void>(propertyId: 3, isPrimaryKey: false) }

    fileprivate func __setId(identifier: ObjectBox.Id) {
        self.id = Id(identifier)
    }
}

extension ObjectBox.Property where E == DecisionEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .id == myId }

    internal static var id: Property<DecisionEntity, Id, Id> { return Property<DecisionEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .cpIndex > 1234 }

    internal static var cpIndex: Property<DecisionEntity, Int, Void> { return Property<DecisionEntity, Int, Void>(propertyId: 2, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .decision.startsWith("X") }

    internal static var decision: Property<DecisionEntity, String, Void> { return Property<DecisionEntity, String, Void>(propertyId: 3, isPrimaryKey: false) }

}


/// Generated service type to handle persisting and reading entity data. Exposed through `DecisionEntity.EntityBindingType`.
internal final class DecisionEntityBinding: ObjectBox.EntityBinding, Sendable {
    internal typealias EntityType = DecisionEntity
    internal typealias IdType = Id

    internal required init() {}

    internal func generatorBindingVersion() -> Int { 1 }

    internal func setEntityIdUnlessStruct(of entity: EntityType, to entityId: ObjectBox.Id) {
        entity.__setId(identifier: entityId)
    }

    internal func entityId(of entity: EntityType) -> ObjectBox.Id {
        return entity.id.value
    }

    internal func collect(fromEntity entity: EntityType, id: ObjectBox.Id,
                                  propertyCollector: ObjectBox.FlatBufferBuilder, store: ObjectBox.Store) throws {
        let propertyOffset_decision = propertyCollector.prepare(string: entity.decision)

        propertyCollector.collect(id, at: 2 + 2 * 1)
        propertyCollector.collect(entity.cpIndex, at: 2 + 2 * 2)
        propertyCollector.collect(dataOffset: propertyOffset_decision, at: 2 + 2 * 3)
    }

    internal func createEntity(entityReader: ObjectBox.FlatBufferReader, store: ObjectBox.Store) -> EntityType {
        let entity = DecisionEntity()

        entity.id = entityReader.read(at: 2 + 2 * 1)
        entity.cpIndex = entityReader.read(at: 2 + 2 * 2)
        entity.decision = entityReader.read(at: 2 + 2 * 3)

        return entity
    }
}



extension ReadingEntity: ObjectBox.__EntityRelatable {
    internal typealias EntityType = ReadingEntity

    internal var _id: EntityId<ReadingEntity> {
        return EntityId<ReadingEntity>(self.id.value)
    }
}

extension ReadingEntity: ObjectBox.EntityInspectable {
    internal typealias EntityBindingType = ReadingEntityBinding

    /// Generated metadata used by ObjectBox to persist the entity.
    internal static let entityInfo = ObjectBox.EntityInfo(name: "ReadingEntity", id: 4)

    internal static let entityBinding = EntityBindingType()

    fileprivate static func buildEntity(modelBuilder: ObjectBox.ModelBuilder) throws {
        let entityBuilder = try modelBuilder.entityBuilder(for: ReadingEntity.self, id: 4, uid: 7394040494430619136)
        try entityBuilder.addProperty(name: "id", type: PropertyType.long, flags: [.id], id: 1, uid: 7764953713073935872)
        try entityBuilder.addProperty(name: "minute", type: PropertyType.long, id: 2, uid: 8032496270843291392)
        try entityBuilder.addProperty(name: "temp", type: PropertyType.double, id: 3, uid: 8021719147883007232)
        try entityBuilder.addProperty(name: "humidity", type: PropertyType.double, id: 4, uid: 3454893104624945152)
        try entityBuilder.addProperty(name: "anomalous", type: PropertyType.bool, id: 5, uid: 7556897812920762368)

        try entityBuilder.lastProperty(id: 5, uid: 7556897812920762368)
    }
}

extension ReadingEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { ReadingEntity.id == myId }
    internal static var id: Property<ReadingEntity, Id, Id> { return Property<ReadingEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { ReadingEntity.minute > 1234 }
    internal static var minute: Property<ReadingEntity, Int, Void> { return Property<ReadingEntity, Int, Void>(propertyId: 2, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { ReadingEntity.temp > 1234 }
    internal static var temp: Property<ReadingEntity, Double, Void> { return Property<ReadingEntity, Double, Void>(propertyId: 3, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { ReadingEntity.humidity > 1234 }
    internal static var humidity: Property<ReadingEntity, Double, Void> { return Property<ReadingEntity, Double, Void>(propertyId: 4, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { ReadingEntity.anomalous == true }
    internal static var anomalous: Property<ReadingEntity, Bool, Void> { return Property<ReadingEntity, Bool, Void>(propertyId: 5, isPrimaryKey: false) }

    fileprivate func __setId(identifier: ObjectBox.Id) {
        self.id = Id(identifier)
    }
}

extension ObjectBox.Property where E == ReadingEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .id == myId }

    internal static var id: Property<ReadingEntity, Id, Id> { return Property<ReadingEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .minute > 1234 }

    internal static var minute: Property<ReadingEntity, Int, Void> { return Property<ReadingEntity, Int, Void>(propertyId: 2, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .temp > 1234 }

    internal static var temp: Property<ReadingEntity, Double, Void> { return Property<ReadingEntity, Double, Void>(propertyId: 3, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .humidity > 1234 }

    internal static var humidity: Property<ReadingEntity, Double, Void> { return Property<ReadingEntity, Double, Void>(propertyId: 4, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .anomalous == true }

    internal static var anomalous: Property<ReadingEntity, Bool, Void> { return Property<ReadingEntity, Bool, Void>(propertyId: 5, isPrimaryKey: false) }

}


/// Generated service type to handle persisting and reading entity data. Exposed through `ReadingEntity.EntityBindingType`.
internal final class ReadingEntityBinding: ObjectBox.EntityBinding, Sendable {
    internal typealias EntityType = ReadingEntity
    internal typealias IdType = Id

    internal required init() {}

    internal func generatorBindingVersion() -> Int { 1 }

    internal func setEntityIdUnlessStruct(of entity: EntityType, to entityId: ObjectBox.Id) {
        entity.__setId(identifier: entityId)
    }

    internal func entityId(of entity: EntityType) -> ObjectBox.Id {
        return entity.id.value
    }

    internal func collect(fromEntity entity: EntityType, id: ObjectBox.Id,
                                  propertyCollector: ObjectBox.FlatBufferBuilder, store: ObjectBox.Store) throws {

        propertyCollector.collect(id, at: 2 + 2 * 1)
        propertyCollector.collect(entity.minute, at: 2 + 2 * 2)
        propertyCollector.collect(entity.temp, at: 2 + 2 * 3)
        propertyCollector.collect(entity.humidity, at: 2 + 2 * 4)
        propertyCollector.collect(entity.anomalous, at: 2 + 2 * 5)
    }

    internal func createEntity(entityReader: ObjectBox.FlatBufferReader, store: ObjectBox.Store) -> EntityType {
        let entity = ReadingEntity()

        entity.id = entityReader.read(at: 2 + 2 * 1)
        entity.minute = entityReader.read(at: 2 + 2 * 2)
        entity.temp = entityReader.read(at: 2 + 2 * 3)
        entity.humidity = entityReader.read(at: 2 + 2 * 4)
        entity.anomalous = entityReader.read(at: 2 + 2 * 5)

        return entity
    }
}



extension StatsEntity: ObjectBox.__EntityRelatable {
    internal typealias EntityType = StatsEntity

    internal var _id: EntityId<StatsEntity> {
        return EntityId<StatsEntity>(self.id.value)
    }
}

extension StatsEntity: ObjectBox.EntityInspectable {
    internal typealias EntityBindingType = StatsEntityBinding

    /// Generated metadata used by ObjectBox to persist the entity.
    internal static let entityInfo = ObjectBox.EntityInfo(name: "StatsEntity", id: 5)

    internal static let entityBinding = EntityBindingType()

    fileprivate static func buildEntity(modelBuilder: ObjectBox.ModelBuilder) throws {
        let entityBuilder = try modelBuilder.entityBuilder(for: StatsEntity.self, id: 5, uid: 8370887192439301120)
        try entityBuilder.addProperty(name: "id", type: PropertyType.long, flags: [.id], id: 1, uid: 1959981054635054848)
        try entityBuilder.addProperty(name: "key", type: PropertyType.string, id: 2, uid: 6077748803931151616)
        try entityBuilder.addProperty(name: "value", type: PropertyType.double, id: 3, uid: 2378819212264094720)

        try entityBuilder.lastProperty(id: 3, uid: 2378819212264094720)
    }
}

extension StatsEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { StatsEntity.id == myId }
    internal static var id: Property<StatsEntity, Id, Id> { return Property<StatsEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { StatsEntity.key.startsWith("X") }
    internal static var key: Property<StatsEntity, String, Void> { return Property<StatsEntity, String, Void>(propertyId: 2, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { StatsEntity.value > 1234 }
    internal static var value: Property<StatsEntity, Double, Void> { return Property<StatsEntity, Double, Void>(propertyId: 3, isPrimaryKey: false) }

    fileprivate func __setId(identifier: ObjectBox.Id) {
        self.id = Id(identifier)
    }
}

extension ObjectBox.Property where E == StatsEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .id == myId }

    internal static var id: Property<StatsEntity, Id, Id> { return Property<StatsEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .key.startsWith("X") }

    internal static var key: Property<StatsEntity, String, Void> { return Property<StatsEntity, String, Void>(propertyId: 2, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .value > 1234 }

    internal static var value: Property<StatsEntity, Double, Void> { return Property<StatsEntity, Double, Void>(propertyId: 3, isPrimaryKey: false) }

}


/// Generated service type to handle persisting and reading entity data. Exposed through `StatsEntity.EntityBindingType`.
internal final class StatsEntityBinding: ObjectBox.EntityBinding, Sendable {
    internal typealias EntityType = StatsEntity
    internal typealias IdType = Id

    internal required init() {}

    internal func generatorBindingVersion() -> Int { 1 }

    internal func setEntityIdUnlessStruct(of entity: EntityType, to entityId: ObjectBox.Id) {
        entity.__setId(identifier: entityId)
    }

    internal func entityId(of entity: EntityType) -> ObjectBox.Id {
        return entity.id.value
    }

    internal func collect(fromEntity entity: EntityType, id: ObjectBox.Id,
                                  propertyCollector: ObjectBox.FlatBufferBuilder, store: ObjectBox.Store) throws {
        let propertyOffset_key = propertyCollector.prepare(string: entity.key)

        propertyCollector.collect(id, at: 2 + 2 * 1)
        propertyCollector.collect(entity.value, at: 2 + 2 * 3)
        propertyCollector.collect(dataOffset: propertyOffset_key, at: 2 + 2 * 2)
    }

    internal func createEntity(entityReader: ObjectBox.FlatBufferReader, store: ObjectBox.Store) -> EntityType {
        let entity = StatsEntity()

        entity.id = entityReader.read(at: 2 + 2 * 1)
        entity.key = entityReader.read(at: 2 + 2 * 2)
        entity.value = entityReader.read(at: 2 + 2 * 3)

        return entity
    }
}


/// Helper function that allows calling Enum(rawValue: value) with a nil value, which will return nil.
fileprivate func optConstruct<T: RawRepresentable>(_ type: T.Type, rawValue: T.RawValue?) -> T? {
    guard let rawValue = rawValue else { return nil }
    return T(rawValue: rawValue)
}

// MARK: - Store setup

fileprivate func cModel() throws -> OpaquePointer {
    let modelBuilder = try ObjectBox.ModelBuilder()
    try AnomalyEntity.buildEntity(modelBuilder: modelBuilder)
    try CheckpointEntity.buildEntity(modelBuilder: modelBuilder)
    try DecisionEntity.buildEntity(modelBuilder: modelBuilder)
    try ReadingEntity.buildEntity(modelBuilder: modelBuilder)
    try StatsEntity.buildEntity(modelBuilder: modelBuilder)
    modelBuilder.lastEntity(id: 5, uid: 8370887192439301120)
    return modelBuilder.finish()
}

extension ObjectBox.Store {
    /// A store with a fully configured model. Created by the code generator with your model's metadata in place.
    ///
    /// # In-memory database
    /// To use a file-less in-memory database, instead of a directory path pass `memory:` 
    /// together with an identifier string:
    /// ```swift
    /// let inMemoryStore = try Store(directoryPath: "memory:test-db")
    /// ```
    ///
    /// - Parameters:
    ///   - directoryPath: The directory path in which ObjectBox places its database files for this store,
    ///     or to use an in-memory database `memory:<identifier>`.
    ///   - maxDbSizeInKByte: Limit of on-disk space for the database files. Default is `1024 * 1024` (1 GiB).
    ///   - fileMode: UNIX-style bit mask used for the database files; default is `0o644`.
    ///     Note: directories become searchable if the "read" or "write" permission is set (e.g. 0640 becomes 0750).
    ///   - maxReaders: The maximum number of readers.
    ///     "Readers" are a finite resource for which we need to define a maximum number upfront.
    ///     The default value is enough for most apps and usually you can ignore it completely.
    ///     However, if you get the maxReadersExceeded error, you should verify your
    ///     threading. For each thread, ObjectBox uses multiple readers. Their number (per thread) depends
    ///     on number of types, relations, and usage patterns. Thus, if you are working with many threads
    ///     (e.g. in a server-like scenario), it can make sense to increase the maximum number of readers.
    ///     Note: The internal default is currently around 120. So when hitting this limit, try values around 200-500.
    ///   - readOnly: Opens the database in read-only mode, i.e. not allowing write transactions.
    ///
    /// - important: This initializer is created by the code generator. If you only see the internal `init(model:...)`
    ///              initializer, trigger code generation by building your project.
    internal convenience init(directoryPath: String, maxDbSizeInKByte: UInt64 = 1024 * 1024,
                            fileMode: UInt32 = 0o644, maxReaders: UInt32 = 0, readOnly: Bool = false) throws {
        try self.init(
            model: try cModel(),
            directory: directoryPath,
            maxDbSizeInKByte: maxDbSizeInKByte,
            fileMode: fileMode,
            maxReaders: maxReaders,
            readOnly: readOnly)
    }
}

// swiftlint:enable all
