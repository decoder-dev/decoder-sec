//
//  PersistenceController.swift
//  decoder sec.
//
//  Local Core Data only — no App Groups.
//  The Network Extension never opens this store; configs are passed at tunnel start.
//

import CoreData
import Foundation

final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer
    let isStoreLoaded: Bool
    let storeLoadError: Error?

    var viewContext: NSManagedObjectContext { container.viewContext }

    init(inMemory: Bool = false) {
        let container = NSPersistentContainer(name: "Model", managedObjectModel: Self.makeManagedObjectModel())
        container.persistentStoreDescriptions = [Self.storeDescription(inMemory: inMemory)]

        let primaryError = Self.loadStore(into: container)
        var effectiveError = primaryError

        if primaryError != nil, !inMemory {
            NSLog("[Persistence] store load failed, falling back to memory: \(primaryError!.localizedDescription)")
            let coordinator = container.persistentStoreCoordinator
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
            container.persistentStoreDescriptions = [Self.storeDescription(inMemory: true)]
            effectiveError = Self.loadStore(into: container)
            if let effectiveError {
                NSLog("[Persistence] in-memory fallback failed: \(effectiveError.localizedDescription)")
            }
        }

        self.container = container
        self.storeLoadError = primaryError ?? effectiveError
        self.isStoreLoaded = effectiveError == nil

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    @discardableResult
    func save(_ context: NSManagedObjectContext? = nil) -> Bool {
        let ctx = context ?? viewContext
        guard ctx.hasChanges else { return true }
        do {
            try ctx.save()
            return true
        } catch {
            NSLog("[Persistence] save failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func storeDescription(inMemory: Bool) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription()
        if inMemory {
            description.type = NSInMemoryStoreType
        } else {
            description.url = EVCore.containerURL.appendingPathComponent("Model.sqlite")
        }
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        return description
    }

    private static func loadStore(into container: NSPersistentContainer) -> Error? {
        var loadError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        container.loadPersistentStores { _, error in
            loadError = error
            semaphore.signal()
        }
        semaphore.wait()
        return loadError
    }

    private static func makeManagedObjectModel() -> NSManagedObjectModel {
        let entity = NSEntityDescription()
        entity.name = "Configuration"
        // Must match @objc(Configuration) — do not use NSStringFromClass (module prefix breaks).
        entity.managedObjectClassName = "Configuration"
        entity.properties = [
            attribute("id", type: .UUIDAttributeType),
            attribute("name", type: .stringAttributeType),
            attribute("type", type: .stringAttributeType),
            attribute("content", type: .stringAttributeType),
            attribute("createdAt", type: .dateAttributeType),
            attribute("updatedAt", type: .dateAttributeType),
            attribute("sourceURL", type: .stringAttributeType, optional: true),
        ]

        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }

    private static func attribute(
        _ name: String,
        type: NSAttributeType,
        optional: Bool = false
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        return attribute
    }
}
