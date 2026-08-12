import { env } from "cloudflare:workers";
import { evictDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { Env } from "../src/environment";
import { encodeEnvelope, parseEnvelope, type Envelope } from "../src/protocol";

const testEnv = env as unknown as Env;

describe("host rendezvous durable object", () => {
  it("pairs one authenticated device and forwards only session-scoped trickle signaling", async () => {
    const hostID = `host-${crypto.randomUUID()}`;
    const deviceID = `device-${crypto.randomUUID()}`;
    const stub = testEnv.HOST_RENDEZVOUS.getByName(hostID);
    const host = await connect(stub, {
      kind: "host",
      accountID: "account-1",
      hostID,
    });
    const hostReady = nextEnvelope(host);
    host.send(encodeEnvelope({ version: 1, kind: "hostHello", hostID }));
    expect(await hostReady).toMatchObject({ kind: "hostReady", hostID });

    // Reconstruct the object while its hibernatable host socket remains connected. The device
    // must still reach the same Mac from serialized socket attachments.
    await evictDurableObject(stub);

    const device = await connect(stub, {
      kind: "device",
      accountID: "account-1",
      hostID,
      deviceID,
    });
    const incoming = nextEnvelope(host);
    device.send(encodeEnvelope({ version: 1, kind: "deviceConnect", hostID, deviceID }));
    const invitation = await incoming;
    expect(invitation).toMatchObject({ kind: "incomingSession", hostID, deviceID });
    expect(invitation.sessionID).toBeTypeOf("string");
    expect(invitation.sessionToken).toBeTypeOf("string");
    const sessionID = invitation.sessionID;
    if (!sessionID) throw new Error("Expected session ID");

    const peer = await connect(stub, {
      kind: "session",
      accountID: "account-1",
      hostID,
      sessionID,
    });
    const deviceReady = nextEnvelope(device);
    const peerReady = nextEnvelope(peer);
    peer.send(encodeEnvelope({
      version: 1,
      kind: "sessionJoin",
      sessionID,
    }));
    expect(await deviceReady).toMatchObject({ kind: "ready", sessionID });
    expect(await peerReady).toMatchObject({ kind: "ready", sessionID });

    const forwardedOffer = nextEnvelope(peer);
    device.send(encodeEnvelope({
      version: 1,
      kind: "offer",
      sessionID,
      description: { kind: "offer", sdp: "v=0\r\n" },
    }));
    expect(await forwardedOffer).toMatchObject({ kind: "offer" });

    const forwardedAnswer = nextEnvelope(device);
    peer.send(encodeEnvelope({
      version: 1,
      kind: "answer",
      sessionID,
      description: { kind: "answer", sdp: "v=0\r\n" },
    }));
    expect(await forwardedAnswer).toMatchObject({ kind: "answer" });

    const candidate: Envelope = {
      version: 1,
      kind: "candidate",
      sessionID,
      candidate: { sdp: "candidate:1 1 UDP 1 192.0.2.1 1234 typ host", sdpMLineIndex: 0 },
    };
    const forwardedCandidate = nextEnvelope(peer);
    device.send(encodeEnvelope(candidate));
    expect(await forwardedCandidate).toEqual(candidate);

    host.close(1000, "done");
    device.close(1000, "done");
    peer.close(1000, "done");
  });

  it("returns a typed offline failure without allocating a session", async () => {
    const hostID = `host-${crypto.randomUUID()}`;
    const deviceID = `device-${crypto.randomUUID()}`;
    const stub = testEnv.HOST_RENDEZVOUS.getByName(hostID);
    const device = await connect(stub, {
      kind: "device",
      accountID: "account-1",
      hostID,
      deviceID,
    });
    const failure = nextEnvelope(device);
    device.send(encodeEnvelope({ version: 1, kind: "deviceConnect", hostID, deviceID }));
    expect(await failure).toMatchObject({ kind: "failure", errorCode: "hostOffline" });
  });
});

async function connect(
  stub: DurableObjectStub,
  principal: {
    kind: "host" | "device" | "session";
    accountID: string;
    hostID: string;
    deviceID?: string;
    sessionID?: string;
  },
): Promise<WebSocket> {
  const headers = new Headers({
    Upgrade: "websocket",
    "X-Threading-Principal-Kind": principal.kind,
    "X-Threading-Account-ID": principal.accountID,
    "X-Threading-Host-ID": principal.hostID,
  });
  if (principal.kind === "host" || principal.kind === "device") {
    headers.set("X-Threading-Credential-Expires-At", String(Date.now() + 60_000));
  }
  if (principal.deviceID) headers.set("X-Threading-Device-ID", principal.deviceID);
  if (principal.sessionID) headers.set("X-Threading-Session-ID", principal.sessionID);
  const response = await stub.fetch("https://rendezvous.test/internal", { headers });
  if (!response.webSocket) throw new Error("Expected WebSocket upgrade");
  response.webSocket.accept();
  return response.webSocket;
}

function nextEnvelope(socket: WebSocket): Promise<Envelope> {
  return new Promise((resolve, reject) => {
    socket.addEventListener("message", (event) => {
      try {
        if (typeof event.data === "string") resolve(parseEnvelope(event.data));
        else if (event.data instanceof ArrayBuffer) resolve(parseEnvelope(event.data));
        else reject(new Error("Unexpected WebSocket payload"));
      } catch (error) {
        reject(error);
      }
    }, { once: true });
  });
}
