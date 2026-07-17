//
//  LoomOrderedUnreliableSendQueueTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 4/1/26.
//

@testable import Loom
import Dispatch
import Foundation
import Network
import Testing

@Suite("Loom Ordered Unreliable Send Queue")
struct LoomOrderedUnreliableSendQueueTests {
    @Test("Stream batch uses one ingress and maps each completion exactly once")
    func streamBatchUsesOneIngressAndMapsCompletionsExactlyOnce() async throws {
        let ingressRecorder = LockedBatchIngressRecorder()
        let singleIngressCount = LockedCounter()
        let completionRecorder = LockedBatchCompletionRecorder()
        let stream = LoomMultiplexedStream(
            id: 9,
            label: "batch/ingress",
            sendHandler: { _ in },
            unreliableSendHandler: { _ in },
            queuedUnreliableSendHandler: { _, _, _, onComplete in
                singleIngressCount.increment()
                onComplete(nil)
            },
            queuedUnreliableBatchSendHandler: { items, profile in
                ingressRecorder.record(items: items, profile: profile)
                for (index, item) in items.enumerated() {
                    item.onComplete(nil)
                    item.onComplete(LoomError.protocolError("duplicate completion \(index)"))
                }
            },
            queuedUnreliableResetHandler: { _ in },
            closeHandler: {}
        )
        let payloads = (0 ..< 4).map { Data([UInt8($0)]) }

        await stream.sendUnreliableQueuedBatch(
            payloads.enumerated().map { index, payload in
                LoomQueuedUnreliableBatchItem(
                    data: payload,
                    options: .init(frameID: 77, fragmentIndex: index, fragmentCount: payloads.count),
                    onComplete: { error in
                        completionRecorder.record(index: index, error: error)
                    }
                )
            },
            profile: .interactiveMedia
        )

        try await waitForCounter(completionRecorder.totalCount, expected: payloads.count)
        #expect(ingressRecorder.ingressCount == 1)
        #expect(ingressRecorder.payloads == payloads)
        #expect(ingressRecorder.profile == .interactiveMedia)
        #expect(singleIngressCount.value == 0)
        #expect(completionRecorder.counts == [1, 1, 1, 1])
        #expect(completionRecorder.results == ["success", "success", "success", "success"])
    }

    @Test("Queue batch close preserves callback indices and exactly-once completion")
    func queueBatchClosePreservesCallbackIndices() async throws {
        let sendRecorder = LockedSendRecorder()
        let completionRecorder = LockedBatchCompletionRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.batch-close"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: 1_024,
            profile: .interactiveMedia,
            sendOperation: { data, completion in
                sendRecorder.record(data: data, completion: completion)
            }
        )
        let payloads = (0 ..< 3).map { Data([UInt8($0)]) }

        queue.enqueueBatch(payloads.enumerated().map { index, payload in
            LoomQueuedUnreliableBatchItem(
                data: payload,
                options: .init(frameID: 88, fragmentIndex: index, fragmentCount: payloads.count),
                onComplete: { error in
                    completionRecorder.record(index: index, error: error)
                }
            )
        })

        try await waitForRecordedPayloads(sendRecorder, expected: [payloads[0]])
        queue.close()
        try await waitForCounter(completionRecorder.totalCount, expected: 2)
        #expect(completionRecorder.counts == [0, 1, 1])
        #expect(completionRecorder.results == ["closed", "closed"])

        sendRecorder.completeNext(error: nil)
        try await waitForCounter(completionRecorder.totalCount, expected: 3)
        #expect(completionRecorder.counts == [1, 1, 1])
        #expect(completionRecorder.results == ["closed", "closed", "success"])
    }

    @Test("Queue batch applies per-item send priority after atomic admission")
    func queueBatchAppliesPerItemSendPriority() async throws {
        let sendRecorder = LockedSendRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.batch-priority"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: 1_024,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                sendRecorder.record(data: data, completion: completion)
            }
        )

        queue.enqueueBatch([
            LoomQueuedUnreliableBatchItem(
                data: Data([1]),
                options: .init(importance: .realtimeInterFrame, frameID: 1)
            ),
            LoomQueuedUnreliableBatchItem(
                data: Data([2]),
                options: .init(importance: .realtimeKeyframe, frameID: 2)
            ),
            LoomQueuedUnreliableBatchItem(
                data: Data([3]),
                options: .init(importance: .realtimeInterFrame, frameID: 3)
            )
        ])

        try await waitForRecordedPayloads(sendRecorder, expected: [Data([2])])
        queue.close()
        sendRecorder.completeNext(error: nil)
    }

    @Test("Throughput probe queue accepts more outstanding packets before backpressure")
    func throughputProbeQueueAcceptsDeeperBurst() async throws {
        let packetSize = 1024
        let payload = Data(repeating: 0xAB, count: packetSize)
        let interactiveLimits = LoomOrderedUnreliableSendQueue.limits(for: .interactiveMedia)
        let throughputLimits = LoomOrderedUnreliableSendQueue.limits(for: .throughputProbe)
        let interactiveCounter = LockedCounter()
        let throughputCounter = LockedCounter()

        let interactiveQueue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.interactive"),
            maxOutstandingPackets: interactiveLimits.maxOutstandingPackets,
            maxOutstandingBytes: interactiveLimits.maxOutstandingBytes,
            sendOperation: { _, _ in
                interactiveCounter.increment()
            }
        )
        let throughputQueue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.probe"),
            maxOutstandingPackets: throughputLimits.maxOutstandingPackets,
            maxOutstandingBytes: throughputLimits.maxOutstandingBytes,
            sendOperation: { _, _ in
                throughputCounter.increment()
            }
        )

        let interactiveAttemptCount = interactiveLimits.maxOutstandingPackets + 64
        let throughputAttemptCount = interactiveAttemptCount + 2_048

        for _ in 0 ..< interactiveAttemptCount {
            interactiveQueue.enqueue(payload) { _ in }
        }
        for _ in 0 ..< throughputAttemptCount {
            throughputQueue.enqueue(payload) { _ in }
        }

        try await waitForCounter(
            interactiveCounter,
            expected: interactiveLimits.maxOutstandingPackets
        )
        try await waitForCounter(
            throughputCounter,
            expected: throughputAttemptCount
        )

        #expect(interactiveCounter.value == interactiveLimits.maxOutstandingPackets)
        #expect(throughputCounter.value == throughputAttemptCount)

        interactiveQueue.close()
        throughputQueue.close()
    }

    @Test("Stream reset forwards only the selected queued-unreliable profile")
    func streamResetForwardsOnlySelectedQueuedUnreliableProfile() async {
        let recorder = ResetProfileRecorder()
        let stream = LoomMultiplexedStream(
            id: 7,
            label: "quality-test/reset",
            sendHandler: { _ in },
            unreliableSendHandler: { _ in },
            queuedUnreliableSendHandler: { _, _, _, onComplete in
                onComplete(nil)
            },
            queuedUnreliableResetHandler: { profile in
                recorder.record(profile)
            },
            closeHandler: {}
        )

        await stream.resetQueuedUnreliableSends(profile: .throughputProbe)

        #expect(recorder.recordedProfiles == [.throughputProbe])
    }

    @Test("Stream diagnostics forwards only the selected queued-unreliable profile")
    func streamDiagnosticsForwardsOnlySelectedQueuedUnreliableProfile() async {
        let recorder = ResetProfileRecorder()
        let stream = LoomMultiplexedStream(
            id: 8,
            label: "quality-test/diagnostics",
            sendHandler: { _ in },
            unreliableSendHandler: { _ in },
            queuedUnreliableSendHandler: { _, _, _, onComplete in
                onComplete(nil)
            },
            queuedUnreliableResetHandler: { _ in },
            queuedUnreliableDiagnosticsHandler: { profile in
                recorder.record(profile)
                return LoomQueuedUnreliableSendDiagnostics(
                    profile: profile,
                    enqueuedCount: 42
                )
            },
            closeHandler: {}
        )

        let snapshot = await stream.consumeQueuedUnreliableSendDiagnostics(
            profile: .proximityRealtimeDisplay
        )

        #expect(recorder.recordedProfiles == [.proximityRealtimeDisplay])
        #expect(snapshot?.profile == .proximityRealtimeDisplay)
        #expect(snapshot?.enqueuedCount == 42)
    }

    @Test("Proximity realtime display profile keeps a shorter media backlog than generic proximity media")
    func proximityRealtimeDisplayProfileKeepsShorterMediaBacklog() {
        let displayLimits = LoomQueuedUnreliableSendProfile.proximityRealtimeDisplay.recommendedLimits
        let singleLaneDisplayLimits = LoomQueuedUnreliableSendProfile.proximityRealtimeDisplaySingleLane.recommendedLimits
        let proximityLimits = LoomQueuedUnreliableSendProfile.proximityInteractiveMedia.recommendedLimits
        let displayQueueLimits = LoomOrderedUnreliableSendQueue.limits(for: .proximityRealtimeDisplay)
        let singleLaneDisplayQueueLimits = LoomOrderedUnreliableSendQueue.limits(
            for: .proximityRealtimeDisplaySingleLane
        )

        #expect(displayLimits.maxOutstandingPackets < proximityLimits.maxOutstandingPackets)
        #expect(displayLimits.maxOutstandingBytes < proximityLimits.maxOutstandingBytes)
        #expect((displayLimits.maxQueuedPackets ?? 0) < (proximityLimits.maxQueuedPackets ?? 0))
        #expect(singleLaneDisplayLimits == displayLimits)
        #expect(displayQueueLimits.maxOutstandingPackets == displayLimits.maxOutstandingPackets)
        #expect(displayQueueLimits.maxOutstandingBytes == displayLimits.maxOutstandingBytes)
        #expect(displayQueueLimits.maxQueuedPackets == displayLimits.maxQueuedPackets)
        #expect(displayQueueLimits.replacesQueuedSends == false)
        #expect(displayQueueLimits.maxDrainBurstPackets == 4)
        #expect(displayQueueLimits.drainBurstIntervalSeconds > 0)
        #expect(singleLaneDisplayQueueLimits == displayQueueLimits)
    }

    @Test("Queue diagnostics report queued-unreliable pacing window and reset after consumption")
    func queueDiagnosticsReportRealtimeWindowAndResetAfterConsumption() async throws {
        let recorder = LockedSendRecorder()
        let completedCounter = LockedCounter()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.diagnostics"),
            maxOutstandingPackets: 8,
            maxOutstandingBytes: 64 * 1024,
            maxQueuedPackets: 8,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        queue.enqueue(
            Data([0xA1]),
            options: LoomQueuedUnreliableSendOptions(
                deadlineUptime: ProcessInfo.processInfo.systemUptime + 0.250,
                importance: .realtimeInterFrame,
                frameID: 10,
                fragmentIndex: 0,
                fragmentCount: 2
            )
        ) { error in
            #expect(error == nil)
            completedCounter.increment()
        }
        queue.enqueue(
            Data([0xA2]),
            options: LoomQueuedUnreliableSendOptions(
                deadlineUptime: ProcessInfo.processInfo.systemUptime + 0.250,
                importance: .realtimeInterFrame,
                frameID: 10,
                fragmentIndex: 1,
                fragmentCount: 2
            )
        ) { error in
            #expect(error == nil)
            completedCounter.increment()
        }

        try await waitForRecordedPayloads(
            recorder,
            expected: [Data([0xA1]), Data([0xA2])]
        )
        recorder.completeNext(error: nil)
        recorder.completeNext(error: nil)
        try await waitForCounter(completedCounter, expected: 2)

        let snapshot = queue.consumeDiagnosticsSnapshot()
        #expect(snapshot.profile == .proximityRealtimeDisplay)
        #expect(snapshot.enqueuedCount == 2)
        #expect(snapshot.sentCount == 2)
        #expect(snapshot.completedCount == 2)
        #expect(snapshot.droppedCount == 0)
        #expect(snapshot.pendingPackets == 0)
        #expect(snapshot.outstandingPackets == 0)
        #expect(snapshot.queueDwellP99Ms >= snapshot.queueDwellP50Ms)
        #expect(snapshot.sendGapP99Ms >= snapshot.sendGapP50Ms)
        #expect(snapshot.contentProcessedP99Ms >= snapshot.contentProcessedP50Ms)

        let resetSnapshot = queue.consumeDiagnosticsSnapshot()
        #expect(resetSnapshot.enqueuedCount == 0)
        #expect(resetSnapshot.sentCount == 0)
        #expect(resetSnapshot.completedCount == 0)
        #expect(resetSnapshot.droppedCount == 0)

        queue.close()
    }

    @Test("Realtime display queue shapes drains into bounded bursts")
    func realtimeDisplayQueueShapesDrainsIntoBoundedBursts() async throws {
        let recorder = LockedSendRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.media-burst-shaping"),
            maxOutstandingPackets: 64,
            maxOutstandingBytes: 64 * 1024,
            maxQueuedPackets: 16,
            maxDrainBurstPackets: 2,
            drainBurstIntervalSeconds: 0.050,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        let payloads = (1 ... 5).map { Data([UInt8($0)]) }
        for payload in payloads {
            queue.enqueue(payload) { _ in }
        }

        try await waitForRecordedPayloads(recorder, expected: Array(payloads[0 ..< 2]))
        try await Task.sleep(for: .milliseconds(15))
        #expect(recorder.recordedPayloads == Array(payloads[0 ..< 2]))

        try await waitForRecordedPayloads(recorder, expected: Array(payloads[0 ..< 4]))
        try await Task.sleep(for: .milliseconds(15))
        #expect(recorder.recordedPayloads == Array(payloads[0 ..< 4]))

        try await waitForRecordedPayloads(recorder, expected: payloads)

        queue.close()
    }

    @Test("Realtime display queue deadline-paces frame fragments when slack is available")
    func realtimeDisplayQueueDeadlinePacesFrameFragmentsWhenSlackIsAvailable() async throws {
        let recorder = LockedSendRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.media-deadline-pacing"),
            maxOutstandingPackets: 64,
            maxOutstandingBytes: 64 * 1024,
            maxQueuedPackets: 8,
            maxDrainBurstPackets: 64,
            drainBurstIntervalSeconds: 0.001,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        let deadline = ProcessInfo.processInfo.systemUptime + 0.120
        for index in 0 ..< 3 {
            queue.enqueue(
                Data([UInt8(index + 1)]),
                options: .init(
                    deadlineUptime: deadline,
                    importance: .realtimeInterFrame,
                    frameID: 77,
                    fragmentIndex: index,
                    fragmentCount: 3
                )
            ) { _ in }
        }

        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([2]), Data([3])])
        let sendTimes = recorder.recordedTimes
        #expect(sendTimes.count == 3)
        #expect(sendTimes[1] - sendTimes[0] >= 0.003)
        #expect(sendTimes[2] - sendTimes[1] >= 0.003)

        queue.close()
    }

    @Test("Single-lane realtime display queue deadline-paces frame fragments")
    func singleLaneRealtimeDisplayQueueDeadlinePacesFrameFragments() async throws {
        let recorder = LockedSendRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.media-single-lane-deadline-pacing"),
            maxOutstandingPackets: 64,
            maxOutstandingBytes: 64 * 1024,
            maxQueuedPackets: 8,
            maxDrainBurstPackets: 64,
            drainBurstIntervalSeconds: 0.001,
            profile: .proximityRealtimeDisplaySingleLane,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        let deadline = ProcessInfo.processInfo.systemUptime + 0.120
        for index in 0 ..< 3 {
            queue.enqueue(
                Data([UInt8(index + 1)]),
                options: .init(
                    deadlineUptime: deadline,
                    importance: .realtimeInterFrame,
                    frameID: 78,
                    fragmentIndex: index,
                    fragmentCount: 3
                )
            ) { _ in }
        }

        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([2]), Data([3])])
        let sendTimes = recorder.recordedTimes
        #expect(sendTimes.count == 3)
        #expect(sendTimes[1] - sendTimes[0] >= 0.003)
        #expect(sendTimes[2] - sendTimes[1] >= 0.003)

        queue.close()
    }

    @Test("Audio profiles use independent shallow queue limits")
    func audioProfilesUseIndependentShallowQueueLimits() {
        let audioLimits = LoomQueuedUnreliableSendProfile.interactiveAudio.recommendedLimits
        let proximityAudioLimits = LoomQueuedUnreliableSendProfile.proximityInteractiveAudio.recommendedLimits
        let mediaLimits = LoomQueuedUnreliableSendProfile.interactiveMedia.recommendedLimits

        #expect(audioLimits.maxOutstandingPackets < mediaLimits.maxOutstandingPackets)
        #expect(audioLimits.maxOutstandingBytes < mediaLimits.maxOutstandingBytes)
        #expect(proximityAudioLimits.maxOutstandingPackets < audioLimits.maxOutstandingPackets)
        #expect(proximityAudioLimits.maxOutstandingBytes < audioLimits.maxOutstandingBytes)
        #expect(LoomOrderedUnreliableSendQueue.limits(for: .interactiveAudio).replacesQueuedSends == false)
        #expect(LoomOrderedUnreliableSendQueue.limits(for: .proximityInteractiveAudio).replacesQueuedSends == false)
    }

    @Test("Interactive media profiles reserve send gaps for control traffic")
    func interactiveMediaProfilesReserveSendGapsForControlTraffic() {
        let mediaQueueLimits = LoomOrderedUnreliableSendQueue.limits(for: .interactiveMedia)
        let proximityMediaQueueLimits = LoomOrderedUnreliableSendQueue.limits(for: .proximityInteractiveMedia)
        let audioQueueLimits = LoomOrderedUnreliableSendQueue.limits(for: .interactiveAudio)
        let probeQueueLimits = LoomOrderedUnreliableSendQueue.limits(for: .throughputProbe)

        #expect(mediaQueueLimits.maxDrainBurstPackets == 32)
        #expect(mediaQueueLimits.drainBurstIntervalSeconds > 0)
        #expect(proximityMediaQueueLimits.maxDrainBurstPackets == mediaQueueLimits.maxDrainBurstPackets)
        #expect(audioQueueLimits.maxDrainBurstPackets == 8)
        #expect(probeQueueLimits.maxDrainBurstPackets == nil)
    }

    @Test("Priority realtime queue keeps newest pending input")
    func priorityRealtimeQueueKeepsNewestPendingInput() async throws {
        let limits = LoomOrderedUnreliableSendQueue.limits(for: .priorityInputRealtime)
        let recorder = LockedSendRecorder()
        let droppedCount = LockedCounter()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.priority-input"),
            maxOutstandingPackets: limits.maxOutstandingPackets,
            maxOutstandingBytes: limits.maxOutstandingBytes,
            replacesQueuedSends: limits.replacesQueuedSends,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        queue.enqueue(Data([1])) { _ in }
        queue.enqueue(Data([2])) { error in
            if error != nil {
                droppedCount.increment()
            }
        }
        queue.enqueue(Data([3])) { _ in }

        try await waitForCounter(droppedCount, expected: 1)
        #expect(recorder.recordedPayloads == [Data([1])])

        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([3])])

        queue.close()
    }

    @Test("Priority sequenced realtime queue keeps short FIFO input window")
    func prioritySequencedRealtimeQueueKeepsShortFIFOInputWindow() async throws {
        let limits = LoomOrderedUnreliableSendQueue.limits(for: .priorityInputRealtimeSequenced)
        let recorder = LockedSendRecorder()
        let droppedPayloads = LockedDataRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.priority-input-sequenced"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: limits.maxOutstandingBytes,
            maxQueuedPackets: 2,
            replacesQueuedSends: limits.replacesQueuedSends,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        queue.enqueue(Data([1])) { _ in }
        queue.enqueue(Data([2])) { error in
            if error != nil { droppedPayloads.record(Data([2])) }
        }
        queue.enqueue(Data([3])) { error in
            if error != nil { droppedPayloads.record(Data([3])) }
        }
        queue.enqueue(Data([4])) { error in
            if error != nil { droppedPayloads.record(Data([4])) }
        }

        try await waitForRecordedPayloads(recorder, expected: [Data([1])])
        try await waitForDroppedPayloads(droppedPayloads, expected: [Data([2])])

        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([3])])

        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([3]), Data([4])])

        queue.close()
    }

    @Test("Realtime media queue drops expired inter-frame packets before transport submission")
    func realtimeMediaQueueDropsExpiredInterFramesBeforeTransportSubmission() async throws {
        let recorder = LockedSendRecorder()
        let droppedPayloads = LockedDataRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.media-expired"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: 1_024,
            maxQueuedPackets: 8,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )
        let expiredOptions = LoomQueuedUnreliableSendOptions(
            deadlineUptime: ProcessInfo.processInfo.systemUptime - 0.001,
            importance: .realtimeInterFrame,
            frameID: 42,
            fragmentIndex: 0,
            fragmentCount: 1
        )

        queue.enqueue(Data([1]), options: expiredOptions) { error in
            if error is LoomQueuedUnreliableSendDrop {
                droppedPayloads.record(Data([1]))
            }
        }

        try await waitForDroppedPayloads(droppedPayloads, expected: [Data([1])])
        #expect(recorder.recordedPayloads.isEmpty)

        queue.close()
    }

    @Test("Realtime media queue expires pending inter-frames while transport is blocked")
    func realtimeMediaQueueExpiresPendingInterFramesWhileTransportIsBlocked() async throws {
        let recorder = LockedSendRecorder()
        let droppedPayloads = LockedDataRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.media-expiry-timer"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: 1_024,
            maxQueuedPackets: 8,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        queue.enqueue(Data([1]), options: .init(importance: .realtimeKeyframe, frameID: 1)) { _ in }
        queue.enqueue(
            Data([2]),
            options: .init(
                deadlineUptime: ProcessInfo.processInfo.systemUptime + 0.025,
                importance: .realtimeInterFrame,
                frameID: 2
            )
        ) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop,
               drop.reason == .deadlineExpired {
                droppedPayloads.record(Data([2]))
            }
        }

        try await waitForRecordedPayloads(recorder, expected: [Data([1])])
        try await waitForDroppedPayloads(droppedPayloads, expected: [Data([2])])
        #expect(recorder.recordedPayloads == [Data([1])])

        queue.close()
    }

    @Test("Realtime media queue expires sibling P-frame fragments together")
    func realtimeMediaQueueExpiresSiblingPFrameFragmentsTogether() async throws {
        let recorder = LockedSendRecorder()
        let droppedPayloads = LockedDataRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.media-sibling-expiry"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: 1_024,
            maxQueuedPackets: 8,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        queue.enqueue(Data([1]), options: .init(importance: .realtimeKeyframe, frameID: 1)) { _ in }
        queue.enqueue(
            Data([2]),
            options: .init(
                deadlineUptime: ProcessInfo.processInfo.systemUptime + 0.025,
                importance: .realtimeInterFrame,
                frameID: 2,
                fragmentIndex: 0,
                fragmentCount: 3
            )
        ) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop,
               drop.reason == .deadlineExpired {
                droppedPayloads.record(Data([2]))
            }
        }
        queue.enqueue(
            Data([3]),
            options: .init(
                deadlineUptime: ProcessInfo.processInfo.systemUptime + 0.500,
                importance: .realtimeInterFrame,
                frameID: 2,
                fragmentIndex: 1,
                fragmentCount: 3
            )
        ) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop,
               drop.reason == .deadlineExpired {
                droppedPayloads.record(Data([3]))
            }
        }
        queue.enqueue(
            Data([4]),
            options: .init(
                deadlineUptime: ProcessInfo.processInfo.systemUptime + 0.500,
                importance: .realtimeParity,
                frameID: 2,
                fragmentIndex: 2,
                fragmentCount: 3
            )
        ) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop,
               drop.reason == .deadlineExpired {
                droppedPayloads.record(Data([4]))
            }
        }

        try await waitForRecordedPayloads(recorder, expected: [Data([1])])
        try await waitForDroppedPayloads(droppedPayloads, expected: [Data([2]), Data([3]), Data([4])])
        #expect(recorder.recordedPayloads == [Data([1])])

        queue.close()
    }

    @Test("Realtime media queue expires configured recovery fragments together")
    func realtimeMediaQueueExpiresConfiguredRecoveryFragmentsTogether() async throws {
        let recorder = LockedSendRecorder()
        let droppedPayloads = LockedDataRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.media-recovery-expiry"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: 1_024,
            maxQueuedPackets: 8,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        queue.enqueue(Data([1]), options: .init(importance: .realtimeKeyframe, frameID: 1)) { _ in }
        queue.enqueue(
            Data([2]),
            options: .init(
                deadlineUptime: ProcessInfo.processInfo.systemUptime + 0.025,
                importance: .realtimeRecovery,
                frameID: 2,
                fragmentIndex: 0,
                fragmentCount: 2,
                dropsWhenExpired: true,
                dropsWhenQueueFull: false
            )
        ) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop,
               drop.reason == .deadlineExpired {
                droppedPayloads.record(Data([2]))
            }
        }
        queue.enqueue(
            Data([3]),
            options: .init(
                deadlineUptime: ProcessInfo.processInfo.systemUptime + 0.500,
                importance: .realtimeRecovery,
                frameID: 2,
                fragmentIndex: 1,
                fragmentCount: 2,
                dropsWhenExpired: true,
                dropsWhenQueueFull: false
            )
        ) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop,
               drop.reason == .deadlineExpired {
                droppedPayloads.record(Data([3]))
            }
        }

        try await waitForRecordedPayloads(recorder, expected: [Data([1])])
        try await waitForDroppedPayloads(droppedPayloads, expected: [Data([2]), Data([3])])
        #expect(recorder.recordedPayloads == [Data([1])])

        queue.close()
    }

    @Test("Realtime media queue drops sibling P-frame fragments under queue pressure")
    func realtimeMediaQueueDropsSiblingPFrameFragmentsUnderQueuePressure() async throws {
        let recorder = LockedSendRecorder()
        let droppedPayloads = LockedDataRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.media-sibling-queue-limit"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: 1_024,
            maxQueuedPackets: 2,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        queue.enqueue(Data([1]), options: .init(importance: .realtimeKeyframe, frameID: 1)) { _ in }
        queue.enqueue(
            Data([2]),
            options: .init(
                importance: .realtimeInterFrame,
                frameID: 2,
                fragmentIndex: 0,
                fragmentCount: 2
            )
        ) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop,
               drop.reason == .queueLimit {
                droppedPayloads.record(Data([2]))
            }
        }
        queue.enqueue(
            Data([3]),
            options: .init(
                importance: .realtimeInterFrame,
                frameID: 2,
                fragmentIndex: 1,
                fragmentCount: 2
            )
        ) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop,
               drop.reason == .queueLimit {
                droppedPayloads.record(Data([3]))
            }
        }
        queue.enqueue(Data([4]), options: .init(importance: .realtimeKeyframe, frameID: 4)) { _ in }

        try await waitForRecordedPayloads(recorder, expected: [Data([1])])
        try await waitForDroppedPayloads(droppedPayloads, expected: [Data([2]), Data([3])])

        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([4])])

        queue.close()
    }

    @Test("Realtime media queue preserves sibling recovery fragments inside protected overflow budget")
    func realtimeMediaQueuePreservesSiblingRecoveryFragmentsInsideProtectedOverflowBudget() async throws {
        let recorder = LockedSendRecorder()
        let droppedPayloads = LockedDataRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.media-recovery-sibling-queue-limit"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: 1_024,
            maxQueuedPackets: 1,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        queue.enqueue(Data([1]), options: .init(importance: .realtimeKeyframe, frameID: 1)) { _ in }
        queue.enqueue(
            Data([2]),
            options: .init(
                importance: .realtimeRecovery,
                frameID: 2,
                fragmentIndex: 0,
                fragmentCount: 2
            )
        ) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop,
               drop.reason == .queueLimit {
                droppedPayloads.record(Data([2]))
            }
        }
        queue.enqueue(
            Data([3]),
            options: .init(
                importance: .realtimeRecovery,
                frameID: 2,
                fragmentIndex: 1,
                fragmentCount: 2
            )
        ) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop,
               drop.reason == .queueLimit {
                droppedPayloads.record(Data([3]))
            }
        }

        try await waitForRecordedPayloads(recorder, expected: [Data([1])])
        try await Task.sleep(for: .milliseconds(50))
        #expect(droppedPayloads.recordedPayloads.isEmpty)

        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([2])])
        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([2]), Data([3])])

        queue.close()
    }

    @Test("Realtime media queue preserves sibling keyframe fragments inside protected overflow budget")
    func realtimeMediaQueuePreservesSiblingKeyframeFragmentsInsideProtectedOverflowBudget() async throws {
        let recorder = LockedSendRecorder()
        let droppedPayloads = LockedDataRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.media-keyframe-sibling-queue-limit"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: 1_024,
            maxQueuedPackets: 1,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        queue.enqueue(Data([1]), options: .init(importance: .realtimeKeyframe, frameID: 1)) { _ in }
        queue.enqueue(
            Data([2]),
            options: .init(
                importance: .realtimeKeyframe,
                frameID: 2,
                fragmentIndex: 0,
                fragmentCount: 2
            )
        ) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop,
               drop.reason == .queueLimit {
                droppedPayloads.record(Data([2]))
            }
        }
        queue.enqueue(
            Data([3]),
            options: .init(
                importance: .realtimeKeyframe,
                frameID: 2,
                fragmentIndex: 1,
                fragmentCount: 2
            )
        ) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop,
               drop.reason == .queueLimit {
                droppedPayloads.record(Data([3]))
            }
        }

        try await waitForRecordedPayloads(recorder, expected: [Data([1])])
        try await Task.sleep(for: .milliseconds(50))
        #expect(droppedPayloads.recordedPayloads.isEmpty)

        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([2])])
        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([2]), Data([3])])

        queue.close()
    }

    @Test("Realtime media queue keeps protected group until newer protected group is whole")
    func realtimeMediaQueueKeepsProtectedGroupUntilNewerProtectedGroupIsWhole() async throws {
        let recorder = LockedSendRecorder()
        let droppedPayloads = LockedDataRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.media-protected-whole-group-admission"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: 1_024,
            maxQueuedPackets: 1,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )
        let olderProtectedPayloads = [Data([1]), Data([2])]
        let newerProtectedPayloads = [Data([3]), Data([4])]

        queue.enqueue(Data([0])) { _ in }
        for fragmentIndex in 0 ..< olderProtectedPayloads.count {
            let payload = olderProtectedPayloads[fragmentIndex]
            queue.enqueue(
                payload,
                options: .init(
                    importance: .realtimeKeyframe,
                    frameID: 2,
                    fragmentIndex: fragmentIndex,
                    fragmentCount: olderProtectedPayloads.count
                )
            ) { error in
                if let drop = error as? LoomQueuedUnreliableSendDrop,
                   drop.reason == .queueLimit {
                    droppedPayloads.record(payload)
                }
            }
        }

        queue.enqueue(
            newerProtectedPayloads[0],
            options: .init(
                importance: .realtimeRecovery,
                frameID: 3,
                fragmentIndex: 0,
                fragmentCount: newerProtectedPayloads.count
            )
        ) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop,
               drop.reason == .queueLimit {
                droppedPayloads.record(newerProtectedPayloads[0])
            }
        }

        try await waitForRecordedPayloads(recorder, expected: [Data([0])])
        try await Task.sleep(for: .milliseconds(50))
        #expect(droppedPayloads.recordedPayloads.isEmpty)

        queue.enqueue(
            newerProtectedPayloads[1],
            options: .init(
                importance: .realtimeRecovery,
                frameID: 3,
                fragmentIndex: 1,
                fragmentCount: newerProtectedPayloads.count
            )
        ) { error in
            if let drop = error as? LoomQueuedUnreliableSendDrop,
               drop.reason == .queueLimit {
                droppedPayloads.record(newerProtectedPayloads[1])
            }
        }

        try await waitForDroppedPayloads(droppedPayloads, expected: olderProtectedPayloads)

        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(recorder, expected: [Data([0]), newerProtectedPayloads[0]])
        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(
            recorder,
            expected: [Data([0]), newerProtectedPayloads[0], newerProtectedPayloads[1]]
        )

        queue.close()
    }

    @Test("Realtime display queue admits one protected frame group within byte cap")
    func realtimeDisplayQueueAdmitsOneProtectedFrameGroupWithinByteCap() async throws {
        let recorder = LockedSendRecorder()
        let droppedPayloads = LockedDataRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.media-protected-oversized-frame-drop"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: 1_024,
            maxQueuedPackets: 4,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )
        let protectedPayloads = (0 ..< 13).map { Data([UInt8($0 + 2)]) }

        queue.enqueue(Data([1]), options: .init(importance: .realtimeKeyframe, frameID: 1)) { _ in }
        for fragmentIndex in 0 ..< protectedPayloads.count {
            let payload = protectedPayloads[fragmentIndex]
            queue.enqueue(
                payload,
                options: .init(
                    importance: .realtimeKeyframe,
                    frameID: 2,
                    fragmentIndex: fragmentIndex,
                    fragmentCount: protectedPayloads.count
                )
            ) { error in
                if let drop = error as? LoomQueuedUnreliableSendDrop,
                   drop.reason == .queueLimit {
                    droppedPayloads.record(payload)
                }
            }
        }

        try await waitForRecordedPayloads(recorder, expected: [Data([1])])
        try await Task.sleep(for: .milliseconds(50))
        #expect(droppedPayloads.recordedPayloads.isEmpty)

        for payload in protectedPayloads {
            recorder.completeNext(error: nil)
            try await waitForRecordedPayloads(recorder, expected: [Data([1])] + Array(protectedPayloads.prefix(through: protectedPayloads.firstIndex(of: payload)!)))
        }

        queue.close()
    }

    @Test("Realtime display queue drops protected group only beyond absolute byte cap")
    func realtimeDisplayQueueDropsProtectedGroupOnlyBeyondAbsoluteByteCap() async throws {
        let recorder = LockedSendRecorder()
        let droppedCount = LockedCounter()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.media-protected-absolute-byte-cap"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: 1,
            maxQueuedPackets: 1,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )
        let protectedPayloads = [
            Data(repeating: 0xAB, count: 40 * 1024),
            Data(repeating: 0xCD, count: 40 * 1024)
        ]

        queue.enqueue(Data([0])) { _ in }
        for fragmentIndex in 0 ..< protectedPayloads.count {
            queue.enqueue(
                protectedPayloads[fragmentIndex],
                options: .init(
                    importance: .realtimeKeyframe,
                    frameID: 2,
                    fragmentIndex: fragmentIndex,
                    fragmentCount: protectedPayloads.count
                )
            ) { error in
                if let drop = error as? LoomQueuedUnreliableSendDrop,
                   drop.reason == .queueLimit {
                    droppedCount.increment()
                }
            }
        }

        try await waitForRecordedPayloads(recorder, expected: [Data([0])])
        try await waitForCounter(droppedCount, expected: protectedPayloads.count)
        #expect(recorder.recordedPayloads == [Data([0])])

        queue.close()
    }

    @Test("Realtime media queue trims droppable P-frames before protected keyframes")
    func realtimeMediaQueueTrimsPFramesBeforeKeyframes() async throws {
        let recorder = LockedSendRecorder()
        let droppedPayloads = LockedDataRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.media-priority"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: 1,
            maxQueuedPackets: 1,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        queue.enqueue(Data([1]), options: .init(importance: .realtimeKeyframe, frameID: 1)) { _ in }
        queue.enqueue(Data([2]), options: .init(importance: .realtimeInterFrame, frameID: 2)) { error in
            if error is LoomQueuedUnreliableSendDrop {
                droppedPayloads.record(Data([2]))
            }
        }
        queue.enqueue(Data([3]), options: .init(importance: .realtimeKeyframe, frameID: 3)) { _ in }

        try await waitForRecordedPayloads(recorder, expected: [Data([1])])
        try await waitForDroppedPayloads(droppedPayloads, expected: [Data([2])])

        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([3])])

        queue.close()
    }

    @Test("Realtime media queue sends protected keyframes before older P-frames")
    func realtimeMediaQueueSendsProtectedKeyframesBeforeOlderPFrames() async throws {
        let recorder = LockedSendRecorder()
        let queue = LoomOrderedUnreliableSendQueue(
            queue: DispatchQueue(label: "loom.tests.queue.media-priority-send"),
            maxOutstandingPackets: 1,
            maxOutstandingBytes: 1_024,
            maxQueuedPackets: 8,
            profile: .proximityRealtimeDisplay,
            sendOperation: { data, completion in
                recorder.record(data: data, completion: completion)
            }
        )

        queue.enqueue(Data([1]), options: .init(importance: .realtimeInterFrame, frameID: 1)) { _ in }
        queue.enqueue(Data([2]), options: .init(importance: .realtimeInterFrame, frameID: 2)) { _ in }
        queue.enqueue(Data([3]), options: .init(importance: .realtimeKeyframe, frameID: 3)) { _ in }

        try await waitForRecordedPayloads(recorder, expected: [Data([1])])

        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([3])])

        recorder.completeNext(error: nil)
        try await waitForRecordedPayloads(recorder, expected: [Data([1]), Data([3]), Data([2])])

        queue.close()
    }

    @Test("Ordered submitter expires stale realtime operations before transport enqueue")
    func orderedSubmitterExpiresStaleRealtimeOperationsBeforeTransportEnqueue() async throws {
        let submitter = LoomOrderedAsyncSubmitter()
        let firstOperation = LockedSubmitterMark()
        let expiredCount = LockedCounter()
        let ranCount = LockedCounter()

        submitter.enqueue(
            operation: { markQueued in
                firstOperation.store(markQueued)
            },
            onDropped: {}
        )
        submitter.enqueue(
            operation: { markQueued in
                ranCount.increment()
                markQueued()
            },
            deadlineUptime: ProcessInfo.processInfo.systemUptime + 0.02,
            dropsWhenExpired: true,
            onExpired: {
                expiredCount.increment()
            },
            onDropped: {}
        )

        try await Task.sleep(for: .milliseconds(60))
        firstOperation.complete()
        try await waitForCounter(expiredCount, expected: 1)
        #expect(ranCount.value == 0)

        submitter.close()
    }

    @Test("Ordered submitter bounds realtime operations before transport enqueue")
    func orderedSubmitterBoundsRealtimeOperationsBeforeTransportEnqueue() async throws {
        let submitter = LoomOrderedAsyncSubmitter()
        let firstOperation = LockedSubmitterMark()
        let droppedCount = LockedCounter()
        let ranCount = LockedCounter()

        submitter.enqueue(
            operation: { markQueued in
                firstOperation.store(markQueued)
            },
            onDropped: {}
        )
        for _ in 0 ..< 5 {
            submitter.enqueue(
                operation: { markQueued in
                    ranCount.increment()
                    markQueued()
                },
                maxPendingOperations: 2,
                dropsWhenQueueFull: true,
                queueFullDropPriority: LoomQueuedUnreliableSendOptions.Importance.realtimeInterFrame.queueFullDropPriority,
                onQueueLimit: {
                    droppedCount.increment()
                },
                onDropped: {}
            )
        }

        try await waitForCounter(droppedCount, expected: 3)
        firstOperation.complete()
        try await waitForCounter(ranCount, expected: 2)
        #expect(ranCount.value == 2)

        submitter.close()
    }

    @Test("Ordered submitter preserves protected realtime operations before transport enqueue")
    func orderedSubmitterPreservesProtectedRealtimeOperationsBeforeTransportEnqueue() async throws {
        let submitter = LoomOrderedAsyncSubmitter()
        let firstOperation = LockedSubmitterMark()
        let droppedCount = LockedCounter()
        let ranPayloads = LockedDataRecorder()

        submitter.enqueue(
            operation: { markQueued in
                firstOperation.store(markQueued)
            },
            onDropped: {}
        )
        for payload in 0 ..< 3 {
            submitter.enqueue(
                operation: { markQueued in
                    ranPayloads.record(Data([UInt8(payload)]))
                    markQueued()
                },
                maxPendingOperations: 1,
                dropsWhenQueueFull: false,
                queueFullDropPriority: LoomQueuedUnreliableSendOptions.Importance.realtimeKeyframe.queueFullDropPriority,
                onQueueLimit: {
                    droppedCount.increment()
                },
                onDropped: {}
            )
        }

        try await Task.sleep(for: .milliseconds(20))
        #expect(droppedCount.value == 0)
        firstOperation.complete()
        try await waitForDroppedPayloads(
            ranPayloads,
            expected: [Data([0]), Data([1]), Data([2])]
        )

        submitter.close()
    }

    private func waitForCounter(
        _ counter: LockedCounter,
        expected: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if counter.value >= expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for queued sends to reach \(expected); saw \(counter.value)")
    }

    private func waitForRecordedPayloads(
        _ recorder: LockedSendRecorder,
        expected: [Data],
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if recorder.recordedPayloads == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for recorded payloads; saw \(recorder.recordedPayloads)")
    }

    private func waitForDroppedPayloads(
        _ recorder: LockedDataRecorder,
        expected: [Data],
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if recorder.recordedPayloads == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for dropped payloads; saw \(recorder.recordedPayloads)")
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class LockedBatchIngressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ingressCountStorage = 0
    private var payloadStorage: [Data] = []
    private var profileStorage: LoomQueuedUnreliableSendProfile?

    var ingressCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return ingressCountStorage
    }

    var payloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return payloadStorage
    }

    var profile: LoomQueuedUnreliableSendProfile? {
        lock.lock()
        defer { lock.unlock() }
        return profileStorage
    }

    func record(
        items: [LoomQueuedUnreliableBatchItem],
        profile: LoomQueuedUnreliableSendProfile
    ) {
        lock.lock()
        ingressCountStorage += 1
        payloadStorage = items.map(\.data)
        profileStorage = profile
        lock.unlock()
    }
}

private final class LockedBatchCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var countStorage: [Int] = []
    private var resultStorage: [String] = []
    let totalCount = LockedCounter()

    var counts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return countStorage
    }

    var results: [String] {
        lock.lock()
        defer { lock.unlock() }
        return resultStorage
    }

    func record(index: Int, error: Error?) {
        lock.lock()
        if countStorage.count <= index {
            countStorage.append(contentsOf: repeatElement(0, count: index - countStorage.count + 1))
        }
        countStorage[index] += 1
        if let drop = error as? LoomQueuedUnreliableSendDrop {
            resultStorage.append(drop.reason.rawValue)
        } else if error != nil {
            resultStorage.append("error")
        } else {
            resultStorage.append("success")
        }
        lock.unlock()
        totalCount.increment()
    }
}

private final class LockedSendRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var payloadStorage: [Data] = []
    private var timeStorage: [TimeInterval] = []
    private var completionStorage: [@Sendable (Error?) -> Void] = []

    var recordedPayloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return payloadStorage
    }

    var recordedTimes: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return timeStorage
    }

    func record(
        data: Data,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        lock.lock()
        payloadStorage.append(data)
        timeStorage.append(ProcessInfo.processInfo.systemUptime)
        completionStorage.append(completion)
        lock.unlock()
    }

    func completeNext(error: Error?) {
        lock.lock()
        let completion = completionStorage.isEmpty ? nil : completionStorage.removeFirst()
        lock.unlock()
        completion?(error)
    }
}

private final class LockedDataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var payloadStorage: [Data] = []

    var recordedPayloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return payloadStorage
    }

    func record(_ payload: Data) {
        lock.lock()
        payloadStorage.append(payload)
        lock.unlock()
    }
}

private final class ResetProfileRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LoomQueuedUnreliableSendProfile] = []

    var recordedProfiles: [LoomQueuedUnreliableSendProfile] {
        lock.lock()
        let profiles = storage
        lock.unlock()
        return profiles
    }

    func record(_ profile: LoomQueuedUnreliableSendProfile) {
        lock.lock()
        storage.append(profile)
        lock.unlock()
    }
}

private final class LockedSubmitterMark: @unchecked Sendable {
    private let lock = NSLock()
    private var markQueued: (@Sendable () -> Void)?

    func store(_ markQueued: @escaping @Sendable () -> Void) {
        lock.lock()
        self.markQueued = markQueued
        lock.unlock()
    }

    func complete() {
        lock.lock()
        let markQueued = self.markQueued
        self.markQueued = nil
        lock.unlock()
        markQueued?()
    }
}
