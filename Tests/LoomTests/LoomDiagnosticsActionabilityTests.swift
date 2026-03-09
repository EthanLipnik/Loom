//
//  LoomDiagnosticsActionabilityTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Ensures diagnostics filtering relies on typed metadata, not product-specific message parsing.
//

@testable import Loom
import Foundation
import Testing

@Suite("Loom Diagnostics Actionability")
struct LoomDiagnosticsActionabilityTests {
    @Test("Typed NSURLError metadata is filtered")
    func typedURLErrorMetadataIsFiltered() {
        let event = makeEvent(
            message: "Socket dropped",
            metadata: LoomDiagnosticsErrorMetadata(
                typeName: "NSError",
                domain: NSURLErrorDomain,
                code: -1009
            )
        )

        #expect(LoomDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Typed Cocoa decode metadata is filtered")
    func typedCocoaDecodeMetadataIsFiltered() {
        let event = makeEvent(
            message: "Failed to decode payload",
            metadata: LoomDiagnosticsErrorMetadata(
                typeName: "Swift.DecodingError",
                domain: NSCocoaErrorDomain,
                code: 4865
            )
        )

        #expect(LoomDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Typed OSStatus metadata without a Loom rule is captured")
    func typedOSStatusMetadataWithoutLoomRuleIsCaptured() {
        let event = makeEvent(
            message: "Decode callback failed",
            metadata: LoomDiagnosticsErrorMetadata(
                typeName: "NSError",
                domain: NSOSStatusErrorDomain,
                code: -12909
            )
        )

        #expect(LoomDiagnosticsActionability.shouldCaptureNonFatal(event))
    }

    @Test("Typed ScreenCaptureKit metadata without a Loom rule is captured")
    func typedScreenCaptureKitMetadataWithoutLoomRuleIsCaptured() {
        let event = makeEvent(
            message: "Error stopping capture",
            metadata: LoomDiagnosticsErrorMetadata(
                typeName: "NSError",
                domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
                code: -3808
            )
        )

        #expect(LoomDiagnosticsActionability.shouldCaptureNonFatal(event))
    }

    @Test("Typed metadata ignores message text")
    func typedMetadataIgnoresMessageText() {
        let event = makeEvent(
            message: "network is down",
            metadata: LoomDiagnosticsErrorMetadata(
                typeName: "NSError",
                domain: "com.loom.tests",
                code: 777
            )
        )

        #expect(LoomDiagnosticsActionability.shouldCaptureNonFatal(event))
    }

    @Test("Typed runtime condition metadata is filtered")
    func typedRuntimeConditionMetadataIsFiltered() {
        let event = makeEvent(
            message: "ignored",
            metadata: LoomDiagnosticsErrorMetadata(error: LoomRuntimeConditionError.credentialsRequired)
        )

        #expect(LoomDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Events without metadata are captured")
    func eventsWithoutMetadataAreCaptured() {
        let event = makeEvent(
            message: "The Internet connection appears to be offline",
            metadata: nil
        )

        #expect(LoomDiagnosticsActionability.shouldCaptureNonFatal(event))
    }

    @Test("Fault severity is always captured")
    func faultSeverityAlwaysCaptured() {
        let event = LoomDiagnosticsErrorEvent(
            date: Date(),
            category: .session,
            severity: .fault,
            source: .logger,
            message: "fatal",
            fileID: #fileID,
            line: #line,
            function: #function,
            metadata: nil
        )

        #expect(LoomDiagnosticsActionability.shouldCaptureNonFatal(event))
    }

    @Test("Events without metadata ignore product-shaped message text")
    func eventsWithoutMetadataIgnoreProductShapedMessageText() {
        let event = makeEvent(
            message: "Virtual display failed Retina activation for all descriptor profiles",
            metadata: nil
        )

        #expect(LoomDiagnosticsActionability.shouldCaptureNonFatal(event))
    }

    @Test("Relay auth failures without typed Loom rule are captured")
    func relayAuthFailuresWithoutTypedLoomRuleAreCaptured() {
        let event = makeEvent(
            message: "Remote signaling close failed: http(statusCode: 401, errorCode: Optional(\"app_auth_failed\"), detail: Optional(\"app_signature_verification_failed\"))",
            metadata: LoomDiagnosticsErrorMetadata(
                typeName: "Loom.LoomRelayError",
                domain: "Loom.LoomRelayError",
                code: 0
            ),
            category: .relay
        )

        #expect(LoomDiagnosticsActionability.shouldCaptureNonFatal(event))
    }

    @Test("Remote signaling invalid configuration metadata is filtered")
    func remoteSignalingInvalidConfigurationMetadataIsFiltered() {
        let event = makeEvent(
            message: "Remote signaling configuration is invalid",
            metadata: LoomDiagnosticsErrorMetadata(
                typeName: "Loom.LoomRelayError",
                domain: "Loom.LoomRelayError",
                code: 1
            ),
            category: .relay
        )

        #expect(LoomDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    private func makeEvent(
        message: String,
        metadata: LoomDiagnosticsErrorMetadata?,
        category: LoomLogCategory = .transport
    ) -> LoomDiagnosticsErrorEvent {
        LoomDiagnosticsErrorEvent(
            date: Date(),
            category: category,
            severity: .error,
            source: .logger,
            message: message,
            fileID: #fileID,
            line: #line,
            function: #function,
            metadata: metadata
        )
    }
}
