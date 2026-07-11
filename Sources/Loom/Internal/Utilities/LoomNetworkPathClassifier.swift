//
//  LoomNetworkPathClassifier.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  Path classification helpers used for AWDL transport stabilization.
//

#if canImport(Network)
import Foundation
import Network

package enum LoomNetworkPathKind: String, Sendable, Equatable {
    case awdl
    case overlay
    case wifi
    case wired
    case cellular
    case loopback
    case other
    case unknown
}

package struct LoomNetworkPathSnapshot: Sendable, Equatable {
    package let kind: LoomNetworkPathKind
    package let status: String
    package let signature: String
    package let interfaceNames: [String]
    package let isExpensive: Bool
    package let isConstrained: Bool
    package let supportsIPv4: Bool
    package let supportsIPv6: Bool
    package let usesWiFi: Bool
    package let usesWired: Bool
    package let usesCellular: Bool
    package let usesLoopback: Bool
    package let usesOther: Bool
    package let localEndpointDescription: String?
    package let remoteEndpointDescription: String?

    package var isReady: Bool {
        status == "satisfied"
    }
}

package enum LoomNetworkPathClassifier {
    package static func classify(_ path: NWPath) -> LoomNetworkPathSnapshot {
        let interfaces = path.availableInterfaces.map { $0.name.lowercased() }
        return classify(
            interfaceNames: interfaces,
            usesWiFi: path.usesInterfaceType(.wifi),
            usesWired: path.usesInterfaceType(.wiredEthernet),
            usesCellular: path.usesInterfaceType(.cellular),
            usesLoopback: path.usesInterfaceType(.loopback),
            usesOther: path.usesInterfaceType(.other),
            status: String(describing: path.status),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            localEndpointDescription: endpointDescription(path.localEndpoint),
            remoteEndpointDescription: endpointDescription(path.remoteEndpoint)
        )
    }

    package static func classify(_ snapshot: LoomSessionNetworkPathSnapshot) -> LoomNetworkPathSnapshot {
        classify(
            interfaceNames: snapshot.interfaceNames,
            usesWiFi: snapshot.usesWiFi,
            usesWired: snapshot.usesWiredEthernet,
            usesCellular: snapshot.usesCellular,
            usesLoopback: snapshot.usesLoopback,
            usesOther: snapshot.usesOther,
            status: snapshot.status.rawValue,
            isExpensive: snapshot.isExpensive,
            isConstrained: snapshot.isConstrained,
            supportsIPv4: snapshot.supportsIPv4,
            supportsIPv6: snapshot.supportsIPv6,
            localEndpointDescription: endpointDescription(snapshot.localEndpoint),
            remoteEndpointDescription: endpointDescription(snapshot.remoteEndpoint)
        )
    }

    package static func classify(
        interfaceNames: [String],
        usesWiFi: Bool,
        usesWired: Bool,
        usesCellular: Bool,
        usesLoopback: Bool,
        usesOther: Bool,
        status: String,
        isExpensive: Bool,
        isConstrained: Bool,
        supportsIPv4: Bool,
        supportsIPv6: Bool,
        localEndpointDescription: String? = nil,
        remoteEndpointDescription: String? = nil
    ) -> LoomNetworkPathSnapshot {
        let endpointRouteInterfaces = InterfaceSummary(
            selectedInterfaceNames(
                localEndpointDescription: localEndpointDescription,
                remoteEndpointDescription: remoteEndpointDescription
            )
        )
        let interfaces = InterfaceSummary(interfaceNames)
        let kind: LoomNetworkPathKind
        if endpointRouteInterfaces.hasProximity {
            kind = .awdl
        } else if endpointRouteInterfaces.hasBridge {
            kind = .wired
        } else if endpointRouteInterfaces.hasOverlay || interfaces.hasOverlay {
            kind = .overlay
        } else if usesWiFi && (interfaces.hasNonProximityRouteInterface || !interfaces.hasProximity) {
            kind = .wifi
        } else if usesWiFi {
            kind = .wifi
        } else if usesWired {
            kind = .wired
        } else if interfaces.hasAWDL &&
                    !usesCellular &&
                    !usesLoopback &&
                    !interfaces.hasApplePrivateNCM &&
                    !interfaces.hasLowLatencyWireless &&
                    !interfaces.hasBridge {
            kind = .awdl
        } else if interfaces.hasProximity {
            kind = .awdl
        } else if usesCellular {
            kind = .cellular
        } else if usesLoopback {
            kind = .loopback
        } else if interfaces.hasBridge {
            kind = .wired
        } else if usesOther {
            kind = .other
        } else {
            kind = .unknown
        }

        let signature =
            "status=\(status)" +
            "|kind=\(kind.rawValue)" +
            "|if=\(interfaces.names.joined(separator: ","))" +
            "|exp=\(isExpensive)" +
            "|con=\(isConstrained)" +
            "|v4=\(supportsIPv4)" +
            "|v6=\(supportsIPv6)" +
            "|local=\(localEndpointDescription ?? "-")" +
            "|remote=\(remoteEndpointDescription ?? "-")"

        return LoomNetworkPathSnapshot(
            kind: kind,
            status: status,
            signature: signature,
            interfaceNames: interfaces.names,
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            supportsIPv4: supportsIPv4,
            supportsIPv6: supportsIPv6,
            usesWiFi: usesWiFi,
            usesWired: usesWired,
            usesCellular: usesCellular,
            usesLoopback: usesLoopback,
            usesOther: usesOther,
            localEndpointDescription: localEndpointDescription,
            remoteEndpointDescription: remoteEndpointDescription
        )
    }

    private static func endpointDescription(_ endpoint: NWEndpoint?) -> String? {
        endpoint.map { "\($0)" }
    }

    private static func selectedInterfaceNames(
        localEndpointDescription: String?,
        remoteEndpointDescription: String?
    ) -> [String] {
        [localEndpointDescription, remoteEndpointDescription]
            .compactMap { $0 }
            .flatMap(selectedInterfaceNames(in:))
    }

    private static func selectedInterfaceNames(in endpointDescription: String) -> [String] {
        let normalized = endpointDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let routePrefixes = ["%25", "%"]
        let proximityPrefixes = ["anpi", "apni", "awdl", "llw", "bridge"]
        return routePrefixes.flatMap { marker in
            proximityPrefixes.compactMap { prefix in
                guard let range = normalized.range(of: marker + prefix) else { return nil }
                let suffix = normalized[range.upperBound...]
                let digits = suffix.prefix { $0.isNumber }
                return prefix + digits
            }
        }
    }

    private struct InterfaceSummary {
        let names: [String]
        let hasApplePrivateNCM: Bool
        let hasAWDL: Bool
        let hasLowLatencyWireless: Bool
        let hasBridge: Bool
        let hasOverlay: Bool
        let hasProximity: Bool
        let hasNonProximityRouteInterface: Bool

        init(_ interfaceNames: [String]) {
            names = interfaceNames
                .map { $0.lowercased() }
                .sorted()
            hasApplePrivateNCM = names.contains {
                $0.hasPrefix("anpi") || $0.hasPrefix("apni")
            }
            hasAWDL = names.contains { $0.hasPrefix("awdl") }
            hasLowLatencyWireless = names.contains { $0.hasPrefix("llw") }
            hasBridge = names.contains { $0.hasPrefix("bridge") }
            hasOverlay = names.contains { $0.hasPrefix("utun") }
            hasProximity = hasApplePrivateNCM || hasAWDL || hasLowLatencyWireless
            hasNonProximityRouteInterface = names.contains {
                !$0.hasPrefix("anpi") &&
                    !$0.hasPrefix("apni") &&
                    !$0.hasPrefix("awdl") &&
                    !$0.hasPrefix("llw") &&
                    !$0.hasPrefix("utun") &&
                    !$0.hasPrefix("bridge")
            }
        }
    }
}

#endif
