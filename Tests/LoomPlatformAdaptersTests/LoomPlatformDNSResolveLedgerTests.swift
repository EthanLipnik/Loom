//
//  LoomPlatformDNSResolveLedgerTests.swift
//  LoomPlatformAdaptersTests
//
//  Created by Ethan Lipnik on 7/10/26.
//

import LoomNetworking
@testable import LoomPlatformAdapters
import Testing

@Suite("Platform DNS-SD Resolve Ordering")
struct LoomPlatformDNSResolveLedgerTests {
    @Test("Removal invalidates an older resolve completion for every interface")
    func removalInvalidatesOlderResolves() {
        var ledger = LoomPlatformDNSResolveLedger()
        let first = identity(interfaceIndex: 4)
        let second = identity(interfaceIndex: 7)
        let unscoped = identity(interfaceIndex: nil)

        let acceptedFirst = ledger.acceptResolution(first, eventSequence: 1)
        let acceptedSecond = ledger.acceptResolution(second, eventSequence: 2)
        let acceptedRemoval = ledger.acceptRemoval(unscoped, eventSequence: 3)
        #expect(acceptedFirst)
        #expect(acceptedSecond)
        #expect(acceptedRemoval)
        #expect(ledger.shouldApplyRemoval(to: first, eventSequence: 3))
        #expect(ledger.shouldApplyRemoval(to: second, eventSequence: 3))
        let acceptedLateFirst = ledger.acceptResolution(first, eventSequence: 1)
        let acceptedLateSecond = ledger.acceptResolution(second, eventSequence: 2)
        let acceptedNewFirst = ledger.acceptResolution(first, eventSequence: 4)
        #expect(!acceptedLateFirst)
        #expect(!acceptedLateSecond)
        #expect(acceptedNewFirst)
    }

    @Test("A late removal cannot erase a newer service generation")
    func lateRemovalIsRejected() {
        var ledger = LoomPlatformDNSResolveLedger()
        let scoped = identity(interfaceIndex: 12)
        let unscoped = identity(interfaceIndex: nil)

        let acceptedRemoval = ledger.acceptRemoval(unscoped, eventSequence: 8)
        let acceptedNewResolution = ledger.acceptResolution(scoped, eventSequence: 9)
        let acceptedLateRemoval = ledger.acceptRemoval(unscoped, eventSequence: 8)
        #expect(acceptedRemoval)
        #expect(acceptedNewResolution)
        #expect(acceptedLateRemoval)
        #expect(!ledger.shouldApplyRemoval(to: scoped, eventSequence: 8))
    }

    @Test("Interface-scoped removal leaves other interface generations valid")
    func scopedRemovalDoesNotInvalidateOtherInterfaces() {
        var ledger = LoomPlatformDNSResolveLedger()
        let first = identity(interfaceIndex: 2)
        let second = identity(interfaceIndex: 3)

        let acceptedFirst = ledger.acceptResolution(first, eventSequence: 10)
        let acceptedSecond = ledger.acceptResolution(second, eventSequence: 11)
        let acceptedRemoval = ledger.acceptRemoval(first, eventSequence: 12)
        let acceptedLateFirst = ledger.acceptResolution(first, eventSequence: 10)
        let acceptedRepeatedSecond = ledger.acceptResolution(second, eventSequence: 11)
        #expect(acceptedFirst)
        #expect(acceptedSecond)
        #expect(acceptedRemoval)
        #expect(!acceptedLateFirst)
        #expect(acceptedRepeatedSecond)
    }

    private func identity(interfaceIndex: UInt32?) -> LoomDNSServiceIdentity {
        LoomDNSServiceIdentity(
            name: "Studio Mac",
            type: "_loom._tcp",
            domain: "local",
            interfaceIndex: interfaceIndex
        )
    }
}
