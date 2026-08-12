//
//  ConfigurationRepository.swift
//  DecoderSec/Core/Protocols
//
//  Protocol seam for config storage — lets Views test against a fake store.
//  Phase 2 rewrite.
//

import Foundation

@MainActor
protocol ConfigurationRepository: AnyObject, ObservableObject {
    var configurations: [Configuration] { get }
    var storeError: String? { get }
    var selectedCore: CoreType { get set }
    var activeIDByCoreType: [CoreType: UUID] { get }
    var active: Configuration? { get }
    var configurationsForSelectedCore: [Configuration] { get }

    @discardableResult
    func create(name: String, type: CoreType, content: String, sourceURL: String?) -> Configuration?
    func update(_ config: Configuration, name: String)
    func update(_ config: Configuration, content: String)
    func delete(_ config: Configuration)
    func setActive(_ config: Configuration)
}
