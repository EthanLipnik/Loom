//
//  LoomConnectionFailureTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 4/5/26.
//

@testable import Loom
import Network
import Testing

@Suite("Loom Connection Failure")
struct LoomConnectionFailureTests {
    @Test("DNS errors classify as address unavailable")
    func dnsErrorsClassifyAsAddressUnavailable() {
        let failure = LoomConnectionFailure.classify(NWError.dns(-65_554))

        #expect(failure.reason == .addressUnavailable)
        #expect((failure.errorDescription ?? "").isEmpty == false)
    }
}
