import { describe, expect, it } from "vitest";
import {
  BOUNDS,
  ProtocolError,
  encodeEnvelope,
  parseEnvelope,
  type Envelope,
} from "../src/protocol";

describe("rendezvous protocol", () => {
  it("round-trips the bounded ready configuration used by Swift", () => {
    const envelope: Envelope = {
      version: 1,
      kind: "ready",
      sessionID: "session-1",
      expiresAt: Math.floor(Date.now() / 1000) * 1000 + 120_000,
      iceServers: [
        { urls: ["stun:stun.cloudflare.com:3478"] },
        {
          urls: [
            "turn:turn.cloudflare.com:3478?transport=udp",
            "turns:turn.cloudflare.com:443?transport=tcp",
          ],
          username: "temporary-user",
          credential: "temporary-credential",
        },
      ],
    };
    expect(parseEnvelope(encodeEnvelope(envelope))).toEqual(envelope);
  });

  it("rejects unknown fields and invalid kind/field combinations", () => {
    expect(() => parseEnvelope(JSON.stringify({
      version: 1,
      kind: "hostHello",
      hostID: "host-1",
      deviceID: "smuggled-device",
    }))).toThrow(ProtocolError);
    expect(() => parseEnvelope(JSON.stringify({
      version: 1,
      kind: "hostHello",
      hostID: "host-1",
      unexpected: true,
    }))).toThrow(ProtocolError);
  });

  it("rejects oversized SDP, candidates, and envelopes before forwarding", () => {
    expect(() => encodeEnvelope({
      version: 1,
      kind: "offer",
      sessionID: "session-1",
      description: {
        kind: "offer",
        sdp: "s".repeat(BOUNDS.maximumSessionDescriptionBytes + 1),
      },
    })).toThrow(ProtocolError);
    expect(() => encodeEnvelope({
      version: 1,
      kind: "candidate",
      sessionID: "session-1",
      candidate: {
        sdp: "c".repeat(BOUNDS.maximumCandidateBytes + 1),
        sdpMLineIndex: 0,
      },
    })).toThrow(ProtocolError);
    expect(() => parseEnvelope(new ArrayBuffer(BOUNDS.maximumEnvelopeBytes + 1)))
      .toThrow(ProtocolError);
  });

  it("rejects ICE URLs and lists outside the native transport contract", () => {
    expect(() => encodeEnvelope({
      version: 1,
      kind: "ready",
      sessionID: "session-1",
      expiresAt: Math.floor(Date.now() / 1000) * 1000 + 120_000,
      iceServers: [{ urls: ["https://not-ice.example"] }],
    })).toThrow(ProtocolError);
    expect(() => encodeEnvelope({
      version: 1,
      kind: "ready",
      sessionID: "session-1",
      expiresAt: Math.floor(Date.now() / 1000) * 1000 + 120_000,
      iceServers: Array.from(
        { length: BOUNDS.maximumIceServers + 1 },
        () => ({ urls: ["stun:stun.example:3478"] }),
      ),
    })).toThrow(ProtocolError);
  });
});
