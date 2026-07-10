//
//  LoomMessageLimits.swift
//  Loom
//
//  Created by Ethan Lipnik on 2/23/26.
//
//  Shared limits used by Loom control-channel framing and parsing.
//

import Foundation

/// Limits for TCP control-channel framing and buffering.
public enum LoomMessageLimits {
    /// Maximum allowed payload bytes for most control messages.
    public static let maxPayloadBytes = 8 * 1024 * 1024

    /// Maximum allowed payload bytes for large metadata snapshots.
    public static let maxLargeMetadataPayloadBytes = 32 * 1024 * 1024

    /// Maximum allowed payload bytes for inline binary assets.
    public static let maxInlineAssetPayloadBytes = 4 * 1024 * 1024

    /// Maximum allowed total frame bytes (`type + length + payload`) for all control messages.
    public static let maxFrameBytes = maxLargeMetadataPayloadBytes + 5

    /// Maximum receive buffer size for control-channel parsing.
    public static let maxReceiveBufferBytes = 64 * 1024 * 1024

    /// Maximum number of payload objects retained for one multiplexed stream.
    public static let maxBufferedPayloadsPerStream = 256

    /// Maximum payload bytes retained across all multiplexed streams in one session.
    public static let maxBufferedIncomingBytesPerSession = 256 * 1024 * 1024

    /// Maximum payload objects retained across all multiplexed streams in one session.
    public static let maxBufferedPayloadsPerSession = 4_096

    /// Maximum payload bytes retained across authenticated sessions owned by one node.
    public static let maxBufferedIncomingBytesPerNode = 512 * 1024 * 1024

    /// Maximum payload objects retained across authenticated sessions owned by one node.
    public static let maxBufferedPayloadsPerNode = 8_192

    /// Maximum hello frame bytes consumed during connection bootstrap.
    public static let maxHelloFrameBytes = 64 * 1024

    /// Maximum UTF-8 bytes accepted for a multiplexed stream label.
    public static let maxStreamLabelBytes = 4 * 1024

    /// Maximum bootstrap control request/response line bytes.
    public static let maxBootstrapControlLineBytes = 64 * 1024

    /// Maximum ciphertext bytes accepted in bootstrap credential envelopes.
    public static let maxBootstrapCredentialCiphertextBytes = 16 * 1024

    /// Maximum nonce length accepted by replay protection.
    public static let maxReplayNonceLength = 128

    /// Maximum bytes for a trust status frame during the handshake.
    public static let maxTrustStatusFrameBytes = 64
}
