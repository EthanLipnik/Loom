//
//  LoomNetworkingModelTests.swift
//  LoomNetworkingTests
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation
import LoomNetworking
import Testing

@Suite("Loom Networking Models")
struct LoomNetworkingModelTests {
    @Test("Scoped IPv6 endpoints preserve their host and encode deterministically")
    func scopedIPv6EndpointRoundTrip() throws {
        let endpoint = LoomNetworkEndpoint.hostPort(
            host: LoomNetworkHost("fe80::1%17"),
            port: 38_447
        )

        let encoded = try JSONEncoder().encode(endpoint)
        let decoded = try JSONDecoder().decode(LoomNetworkEndpoint.self, from: encoded)

        #expect(decoded == endpoint)
        #expect(endpoint.description == "[fe80::1%17]:38447")
    }

    @Test("Service endpoints retain interface scope")
    func serviceEndpointRoundTrip() throws {
        let endpoint = LoomNetworkEndpoint.service(
            name: "Studio Mac",
            type: "_loom._tcp",
            domain: "local.",
            interfaceName: "en7"
        )

        let encoded = try JSONEncoder().encode(endpoint)
        let decoded = try JSONDecoder().decode(LoomNetworkEndpoint.self, from: encoded)

        #expect(decoded == endpoint)
        #expect(endpoint.description == "Studio Mac._loom._tcp.local.%en7")
    }

    @Test("Open network value vocabularies retain unknown backend values")
    func openValueRoundTrip() throws {
        let interfaceType = LoomNetworkInterfaceType(rawValue: "virtual-switch")
        let serviceClass = LoomNetworkServiceClass(rawValue: "bulk-interactive")

        let interfaceData = try JSONEncoder().encode(interfaceType)
        let serviceClassData = try JSONEncoder().encode(serviceClass)

        #expect(
            try JSONDecoder().decode(LoomNetworkInterfaceType.self, from: interfaceData) == interfaceType
        )
        #expect(
            try JSONDecoder().decode(LoomNetworkServiceClass.self, from: serviceClassData) == serviceClass
        )
    }

    @Test("Opaque native endpoints and backend failures preserve diagnostics")
    func opaqueEndpointAndFailureDiagnostics() throws {
        let endpoint = LoomNetworkEndpoint.opaque(description: "native endpoint")
        let encoded = try JSONEncoder().encode(endpoint)
        let error = LoomNetworkError(code: .unsupported, detail: "Backend cannot use this endpoint.")

        #expect(try JSONDecoder().decode(LoomNetworkEndpoint.self, from: encoded) == endpoint)
        #expect(endpoint.description == "native endpoint")
        #expect(error.localizedDescription == error.detail)
    }

    @Test("Portable path snapshots retain route identity")
    func pathRoundTrip() throws {
        let path = LoomNetworkPath(
            status: .satisfied,
            interfaces: [
                LoomNetworkInterface(name: "ethernet0", index: 12, type: .wiredEthernet),
            ],
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true,
            usesWiFi: false,
            usesWiredEthernet: true,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            localEndpoint: .hostPort(host: "192.0.2.4", port: 50_000),
            remoteEndpoint: .hostPort(host: "192.0.2.8", port: 38_447)
        )

        let encoded = try JSONEncoder().encode(path)
        let decoded = try JSONDecoder().decode(LoomNetworkPath.self, from: encoded)

        #expect(decoded == path)
    }

    @Test("Direct connection defaults remain wire-compatible")
    func directConnectionDefaults() {
        let policy = LoomDirectConnectionPolicy.default

        #expect(policy.preferredLocalPathOrder == [.wired, .wifi, .awdl, .other])
        #expect(policy.preferredTransportOrder == [.udp, .tcp])
        #expect(policy.localDiscoveryHostOverride == nil)
        #expect(policy.racesLocalCandidates)
        #expect(policy.racesRemoteCandidates)
        #expect(LoomTransportKind.allCases == [.tcp, .quic, .udp])
    }

    @Test("DNS-SD TXT vectors preserve exact released string bytes")
    func txtRecordVectors() throws {
        let record = try LoomTXTRecord([
            "did": "4BA7DCD6-4EB5-45C4-A22B-15AC2D3C201A",
            "dt": "mac",
            "proto": "3",
            "tcp": "38447",
        ])
        let encoded = try record.encodedData()
        let expected = Data([
            40, 100, 105, 100, 61, 52, 66, 65, 55, 68, 67, 68, 54, 45, 52, 69, 66, 53, 45, 52,
            53, 67, 52, 45, 65, 50, 50, 66, 45, 49, 53, 65, 67, 50, 68, 51, 67, 50, 48, 49, 65,
            6, 100, 116, 61, 109, 97, 99,
            7, 112, 114, 111, 116, 111, 61, 51,
            9, 116, 99, 112, 61, 51, 56, 52, 52, 55,
        ])

        #expect(encoded == expected)
        #expect(try LoomTXTRecord(encodedData: encoded) == record)
        #expect(record.stringDictionary["tcp"] == "38447")
    }

    @Test("DNS-SD TXT records preserve binary values and reject unbounded items")
    func txtRecordBounds() throws {
        let binaryValue = Data([0x00, 0x7f, 0x80, 0xff])
        let record = try LoomTXTRecord(entries: [
            LoomTXTRecord.Entry(key: "binary", value: binaryValue),
            LoomTXTRecord.Entry(key: "present", value: nil),
        ])
        let encoded = try record.encodedData()

        #expect(try LoomTXTRecord(encodedData: encoded) == record)
        #expect(throws: LoomTXTRecordError.self) {
            _ = try LoomTXTRecord(entries: [
                LoomTXTRecord.Entry(key: "duplicate", value: nil),
                LoomTXTRecord.Entry(key: "DUPLICATE", value: nil),
            ])
        }
        #expect(throws: LoomTXTRecordError.self) {
            _ = try LoomTXTRecord.Entry(
                key: "oversized",
                value: Data(repeating: 0, count: 247)
            )
        }
    }

    @Test("DNS-SD names retain Unicode, punctuation, and interface scope")
    func dnsServiceNames() throws {
        let identity = LoomDNSServiceIdentity(
            name: "Étude.Mac\\Lab",
            type: "_loom-default._tcp.",
            domain: "local.",
            interfaceIndex: 17
        )

        #expect(identity.fullyQualifiedName == "Étude\\.Mac\\\\Lab._loom-default._tcp.local")
        #expect(
            LoomDNSServiceIdentity(
                fullyQualifiedName: identity.fullyQualifiedName,
                interfaceIndex: 17
            ) == identity
        )
        #expect(
            LoomDNSServiceIdentity(
                fullyQualifiedName: "\\195\\137tude\\046Mac._loom-default._tcp.local"
            )?.name == "Étude.Mac"
        )
    }
}
