//
//  LoomQuery.swift
//  LoomKit
//
//  Created by Codex on 3/10/26.
//

#if canImport(SwiftUI)
import SwiftUI

/// SwiftUI property wrapper modeled after SwiftData's `@Query`.
@propertyWrapper
@MainActor
public struct LoomQuery<Value>: DynamicProperty {
    @Environment(\.loomContext) private var loomContext

    private let descriptor: LoomQueryDescriptor

    /// Creates a query bound to the current ``LoomContext`` environment value.
    public init(_ descriptor: LoomQueryDescriptor) {
        self.descriptor = descriptor
    }

    /// Returns the filtered and sorted snapshot array requested by the descriptor.
    public var wrappedValue: Value {
        switch descriptor {
        case let .peers(filter, sort):
            let peers = LoomQueryEvaluator.sortPeers(
                LoomQueryEvaluator.filterPeers(loomContext.peers, filter: filter),
                sort: sort
            )
            return peers as! Value

        case let .connections(filter, sort):
            let connections = LoomQueryEvaluator.sortConnections(
                LoomQueryEvaluator.filterConnections(loomContext.connections, filter: filter),
                sort: sort
            )
            return connections as! Value

        case let .transfers(filter, sort):
            let transfers = LoomQueryEvaluator.sortTransfers(
                LoomQueryEvaluator.filterTransfers(loomContext.transfers, filter: filter),
                sort: sort
            )
            return transfers as! Value
        }
    }
}
#endif
