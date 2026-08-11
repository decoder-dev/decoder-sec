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
        container = NSPersistentContainer(name: "Model")

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        } else {
            let storeURL = EVCore.containerURL.appendingPathComponent("Model.sqlite")
            let description = NSPersistentStoreDescription(url: storeURL)
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            container.persistentStoreDescriptions = [description]
        }

        var loadError: Error?
        container.loadPersistentStores { _, error in
            if let error {
                loadError = error
                NSLog("[Persistence] store load failed: \(error.localizedDescription)")
            }
        }
        storeLoadError = loadError
        isStoreLoaded = loadError == nil

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
}
