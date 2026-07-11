//
//  LoomTXTRecord.swift
//  LoomNetworking
//
//  Created by Ethan Lipnik on 7/10/26.
//

import Foundation

/// A bounded DNS-SD TXT record that preserves the exact value bytes.
public struct LoomTXTRecord: Hashable, Sendable {
    /// One DNS-SD TXT key/value item.
    public struct Entry: Hashable, Sendable {
        public let key: String
        public let value: Data?

        public init(key: String, value: Data?) throws {
            try LoomTXTRecord.validateKey(key)
            try LoomTXTRecord.validateItemLength(key: key, value: value)
            self.key = key
            self.value = value
        }

        public init(key: String, stringValue: String) throws {
            try self.init(key: key, value: Data(stringValue.utf8))
        }
    }

    /// Conservative maximum accepted by Loom's parser.
    public static let maximumEncodedBytes = 65_535
    /// Bound on item fan-out before any allocations derived from untrusted input.
    public static let maximumEntryCount = 256

    public let entries: [Entry]

    public init(entries: [Entry]) throws {
        guard entries.count <= Self.maximumEntryCount else {
            throw LoomTXTRecordError.tooManyEntries(entries.count)
        }
        var normalizedKeys: Set<String> = []
        for entry in entries {
            let normalizedKey = entry.key.lowercased()
            guard normalizedKeys.insert(normalizedKey).inserted else {
                throw LoomTXTRecordError.duplicateKey(entry.key)
            }
        }
        self.entries = entries
        _ = try encodedData()
    }

    /// Creates a deterministic TXT record from Loom's existing string dictionary form.
    public init(_ dictionary: [String: String]) throws {
        try self.init(entries: dictionary.keys.sorted().map { key in
            try Entry(key: key, stringValue: dictionary[key] ?? "")
        })
    }

    /// Decodes RFC 6763 length-prefixed TXT bytes with explicit allocation bounds.
    public init(
        encodedData: Data,
        maximumEncodedBytes: Int = LoomTXTRecord.maximumEncodedBytes,
        maximumEntryCount: Int = LoomTXTRecord.maximumEntryCount
    ) throws {
        guard encodedData.count <= max(0, maximumEncodedBytes) else {
            throw LoomTXTRecordError.recordTooLarge(encodedData.count)
        }

        var entries: [Entry] = []
        entries.reserveCapacity(min(16, maximumEntryCount))
        var normalizedKeys: Set<String> = []
        var offset = encodedData.startIndex
        while offset < encodedData.endIndex {
            guard entries.count < maximumEntryCount else {
                throw LoomTXTRecordError.tooManyEntries(entries.count + 1)
            }
            let itemLength = Int(encodedData[offset])
            offset = encodedData.index(after: offset)
            guard itemLength > 0 else {
                throw LoomTXTRecordError.emptyItem
            }
            guard let itemEnd = encodedData.index(
                offset,
                offsetBy: itemLength,
                limitedBy: encodedData.endIndex
            ) else {
                throw LoomTXTRecordError.truncatedItem
            }

            let item = encodedData[offset..<itemEnd]
            offset = itemEnd
            let separator = item.firstIndex(of: UInt8(ascii: "="))
            let keyBytes = separator.map { item[..<$0] } ?? item[...]
            guard let key = String(bytes: keyBytes, encoding: .ascii) else {
                throw LoomTXTRecordError.invalidKeyEncoding
            }
            try Self.validateKey(key)
            let normalizedKey = key.lowercased()
            guard normalizedKeys.insert(normalizedKey).inserted else {
                throw LoomTXTRecordError.duplicateKey(key)
            }

            let value: Data?
            if let separator {
                let valueStart = item.index(after: separator)
                value = Data(item[valueStart...])
            } else {
                value = nil
            }
            entries.append(try Entry(key: key, value: value))
        }
        self.entries = entries
    }

    /// Encodes the record as DNS-SD length-prefixed TXT bytes.
    public func encodedData() throws -> Data {
        var encoded = Data()
        encoded.reserveCapacity(entries.reduce(0) { result, entry in
            result + 1 + entry.key.utf8.count + (entry.value == nil ? 0 : 1 + (entry.value?.count ?? 0))
        })
        for entry in entries {
            try Self.validateKey(entry.key)
            try Self.validateItemLength(key: entry.key, value: entry.value)
            let itemLength = entry.key.utf8.count + (entry.value == nil ? 0 : 1 + (entry.value?.count ?? 0))
            encoded.append(UInt8(itemLength))
            encoded.append(contentsOf: entry.key.utf8)
            if let value = entry.value {
                encoded.append(UInt8(ascii: "="))
                encoded.append(value)
            }
            guard encoded.count <= Self.maximumEncodedBytes else {
                throw LoomTXTRecordError.recordTooLarge(encoded.count)
            }
        }
        return encoded
    }

    /// UTF-8 values projected into the dictionary used by released Loom discovery APIs.
    public var stringDictionary: [String: String] {
        entries.reduce(into: [:]) { result, entry in
            guard let value = entry.value,
                  let stringValue = String(data: value, encoding: .utf8) else {
                return
            }
            result[entry.key] = stringValue
        }
    }

    private static func validateKey(_ key: String) throws {
        let bytes = Array(key.utf8)
        guard !bytes.isEmpty else { throw LoomTXTRecordError.emptyKey }
        guard bytes.count <= 254 else { throw LoomTXTRecordError.itemTooLarge(bytes.count) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e && $0 != UInt8(ascii: "=") }) else {
            throw LoomTXTRecordError.invalidKeyEncoding
        }
    }

    private static func validateItemLength(key: String, value: Data?) throws {
        let itemLength = key.utf8.count + (value == nil ? 0 : 1 + (value?.count ?? 0))
        guard itemLength <= 255 else {
            throw LoomTXTRecordError.itemTooLarge(itemLength)
        }
    }
}

/// Failures produced while validating untrusted DNS-SD TXT bytes.
public enum LoomTXTRecordError: Error, Equatable, LocalizedError, Sendable {
    case recordTooLarge(Int)
    case tooManyEntries(Int)
    case itemTooLarge(Int)
    case emptyItem
    case emptyKey
    case invalidKeyEncoding
    case duplicateKey(String)
    case truncatedItem

    public var errorDescription: String? {
        switch self {
        case let .recordTooLarge(size):
            "DNS-SD TXT record exceeds the Loom limit (\(size) bytes)."
        case let .tooManyEntries(count):
            "DNS-SD TXT record contains too many entries (\(count))."
        case let .itemTooLarge(size):
            "DNS-SD TXT item exceeds 255 bytes (\(size) bytes)."
        case .emptyItem:
            "DNS-SD TXT record contains an empty item."
        case .emptyKey:
            "DNS-SD TXT record contains an empty key."
        case .invalidKeyEncoding:
            "DNS-SD TXT key is not printable ASCII or contains '='."
        case let .duplicateKey(key):
            "DNS-SD TXT record repeats key '\(key)'."
        case .truncatedItem:
            "DNS-SD TXT item is truncated."
        }
    }
}
