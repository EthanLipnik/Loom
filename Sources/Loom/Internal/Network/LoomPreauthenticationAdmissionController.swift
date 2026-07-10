//
//  LoomPreauthenticationAdmissionController.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/9/26.
//

import Foundation

/// Bounds connection work retained before a peer completes authentication.
package actor LoomPreauthenticationAdmissionController {
    private var maxConcurrentConnections: Int
    private var activeConnectionCount = 0

    package init(maxConcurrentConnections: Int) {
        self.maxConcurrentConnections = max(1, maxConcurrentConnections)
    }

    package func acquire() -> Bool {
        guard activeConnectionCount < maxConcurrentConnections else { return false }
        activeConnectionCount += 1
        return true
    }

    package func release() {
        activeConnectionCount = max(0, activeConnectionCount - 1)
    }

    package var activeCount: Int {
        activeConnectionCount
    }

    package func updateLimit(_ maxConcurrentConnections: Int) {
        self.maxConcurrentConnections = max(1, maxConcurrentConnections)
    }
}
