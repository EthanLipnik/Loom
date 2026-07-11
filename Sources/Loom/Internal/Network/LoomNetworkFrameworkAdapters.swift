//
//  LoomNetworkFrameworkAdapters.swift
//  Loom
//
//  Created by Ethan Lipnik on 7/10/26.
//

#if canImport(Network)
import Foundation
import LoomNetworking
import Network

package extension LoomNetworkHost {
    init(_ host: NWEndpoint.Host) {
        self.init(String(describing: host))
    }

    var nwHost: NWEndpoint.Host {
        NWEndpoint.Host(rawValue)
    }
}

package extension LoomNetworkEndpoint {
    init?(_ endpoint: NWEndpoint) {
        switch endpoint {
        case let .hostPort(host, port):
            self = .hostPort(
                host: LoomNetworkHost(host),
                port: port.rawValue
            )
        case let .service(name, type, domain, interface):
            self = .service(
                name: name,
                type: type,
                domain: domain,
                interfaceName: interface?.name
            )
        case .unix, .url, .opaque:
            self = .opaque(description: String(describing: endpoint))
        @unknown default:
            return nil
        }
    }

    /// Converts endpoints representable without an opaque platform interface handle.
    var nwEndpoint: NWEndpoint? {
        switch self {
        case let .hostPort(host, port):
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
            return .hostPort(host: host.nwHost, port: nwPort)
        case let .service(name, type, domain, interfaceName):
            guard interfaceName == nil else { return nil }
            return .service(name: name, type: type, domain: domain, interface: nil)
        case .opaque:
            return nil
        }
    }
}

package extension LoomNetworkInterfaceType {
    init(_ type: NWInterface.InterfaceType) {
        self = switch type {
        case .wifi:
            .wifi
        case .wiredEthernet:
            .wiredEthernet
        case .cellular:
            .cellular
        case .loopback:
            .loopback
        case .other:
            .other
        @unknown default:
            LoomNetworkInterfaceType(rawValue: String(describing: type))
        }
    }

    var nwInterfaceType: NWInterface.InterfaceType? {
        switch self {
        case .wifi:
            .wifi
        case .wiredEthernet:
            .wiredEthernet
        case .cellular:
            .cellular
        case .loopback:
            .loopback
        case .other:
            .other
        default:
            nil
        }
    }
}

package extension LoomNetworkInterface {
    init(_ interface: NWInterface) {
        self.init(
            name: interface.name,
            index: interface.index,
            type: LoomNetworkInterfaceType(interface.type)
        )
    }
}

package extension LoomNetworkServiceClass {
    init(_ serviceClass: NWParameters.ServiceClass) {
        self = switch serviceClass {
        case .bestEffort:
            .bestEffort
        case .background:
            .background
        case .interactiveVideo:
            .interactiveVideo
        case .interactiveVoice:
            .interactiveVoice
        case .responsiveData:
            .responsiveData
        case .signaling:
            .signaling
        @unknown default:
            LoomNetworkServiceClass(rawValue: String(describing: serviceClass))
        }
    }

    var nwServiceClass: NWParameters.ServiceClass? {
        switch self {
        case .bestEffort:
            .bestEffort
        case .background:
            .background
        case .interactiveVideo:
            .interactiveVideo
        case .interactiveVoice:
            .interactiveVoice
        case .responsiveData:
            .responsiveData
        case .signaling:
            .signaling
        default:
            nil
        }
    }
}

package extension LoomNetworkPathStatus {
    init(_ status: NWPath.Status) {
        self = switch status {
        case .satisfied:
            .satisfied
        case .unsatisfied:
            .unsatisfied
        case .requiresConnection:
            .requiresConnection
        @unknown default:
            .requiresConnection
        }
    }
}

package extension LoomNetworkPath {
    init(_ path: NWPath) {
        self.init(
            status: LoomNetworkPathStatus(path.status),
            interfaces: path.availableInterfaces.map(LoomNetworkInterface.init),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            usesWiFi: path.usesInterfaceType(.wifi),
            usesWiredEthernet: path.usesInterfaceType(.wiredEthernet),
            usesCellular: path.usesInterfaceType(.cellular),
            usesLoopback: path.usesInterfaceType(.loopback),
            usesOther: path.usesInterfaceType(.other),
            localEndpoint: path.localEndpoint.flatMap(LoomNetworkEndpoint.init),
            remoteEndpoint: path.remoteEndpoint.flatMap(LoomNetworkEndpoint.init)
        )
    }
}

#endif
