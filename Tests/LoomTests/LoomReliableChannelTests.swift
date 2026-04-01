//
//  LoomReliableChannelTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 4/1/26.
//

@testable import Loom
import Foundation
import Testing

@Suite("Reliable Channel Transport Policy")
struct LoomReliableChannelTests {
    @Test("Reliable packets fail once retries are exhausted and the peer is no longer active")
    func timesOutWhenRetryBudgetIsExhaustedWithoutRecentInboundTraffic() {
        let shouldFail = LoomReliableChannel.shouldFailPendingReliablePacket(
            retryCount: 5,
            maxRetries: 5,
            packetAge: 6.0,
            lastInboundPacketAge: 6.0,
            recentInboundGrace: 5.0,
            maximumPacketLifetime: 15.0
        )

        #expect(shouldFail)
    }

    @Test("Reliable packets stay alive past the retry budget while inbound traffic is still flowing")
    func defersTimeoutWhileRecentInboundTrafficContinues() {
        let shouldFail = LoomReliableChannel.shouldFailPendingReliablePacket(
            retryCount: 5,
            maxRetries: 5,
            packetAge: 6.0,
            lastInboundPacketAge: 0.2,
            recentInboundGrace: 5.0,
            maximumPacketLifetime: 15.0
        )

        #expect(!shouldFail)
    }

    @Test("Reliable packets still fail after an absolute packet lifetime even with recent inbound traffic")
    func respectsAbsolutePacketLifetime() {
        let shouldFail = LoomReliableChannel.shouldFailPendingReliablePacket(
            retryCount: 5,
            maxRetries: 5,
            packetAge: 15.1,
            lastInboundPacketAge: 0.1,
            recentInboundGrace: 5.0,
            maximumPacketLifetime: 15.0
        )

        #expect(shouldFail)
    }

    @Test("Reliable ingress sends an immediate ack after an idle gap")
    func sendsImmediateAckAfterIdleGap() {
        let now: CFAbsoluteTime = 100.0

        #expect(
            LoomReliableChannel.shouldSendImmediateReliableAck(
                lastAckSentAt: nil,
                now: now,
                idleThreshold: 0.05
            )
        )

        #expect(
            LoomReliableChannel.shouldSendImmediateReliableAck(
                lastAckSentAt: now - 0.06,
                now: now,
                idleThreshold: 0.05
            )
        )

        #expect(
            !LoomReliableChannel.shouldSendImmediateReliableAck(
                lastAckSentAt: now - 0.01,
                now: now,
                idleThreshold: 0.05
            )
        )
    }
}
