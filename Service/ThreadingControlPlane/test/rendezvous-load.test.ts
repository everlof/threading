import { env } from "cloudflare:workers";
import { evictDurableObject } from "cloudflare:test";
import { expect, it } from "vitest";
import type { Env } from "../src/environment";
import { encodeEnvelope, parseEnvelope } from "../src/protocol";

interface LoadTestEnv extends Env {
  TEST_RENDEZVOUS_LOAD: string;
  TEST_RENDEZVOUS_LOAD_HOSTS: string;
}

const testEnv = env as unknown as LoadTestEnv;
const loadTest = testEnv.TEST_RENDEZVOUS_LOAD === "1" ? it : it.skip;
const hostCount = Number(testEnv.TEST_RENDEZVOUS_LOAD_HOSTS);
const batchWidth = 100;

loadTest("holds the configured host socket population and preserves sampled hibernation", async () => {
  expect(Number.isSafeInteger(hostCount) && hostCount >= 1 && hostCount <= 10_000).toBe(true);
  const startedAt = performance.now();
  const sockets: WebSocket[] = [];
  const sampledStubs = new Map<number, DurableObjectStub>();
  try {
    for (let offset = 0; offset < hostCount; offset += batchWidth) {
      const batch = Array.from(
        { length: Math.min(batchWidth, hostCount - offset) },
        (_, index) => offset + index,
      );
      const connected = await Promise.all(batch.map(async (index) => {
        const hostID = `load-host-${index}`;
        const stub = testEnv.HOST_RENDEZVOUS.getByName(hostID);
        const response = await stub.fetch("https://rendezvous.test/internal", {
          headers: {
            Upgrade: "websocket",
            "X-Threading-Principal-Kind": "host",
            "X-Threading-Account-ID": `load-account-${index}`,
            "X-Threading-Host-ID": hostID,
            "X-Threading-Credential-Expires-At": String(Date.now() + 60 * 60 * 1000),
          },
        });
        const socket = response.webSocket;
        if (!socket) throw new Error(`host ${index} did not receive a WebSocket`);
        socket.accept();
        const ready = nextMessage(socket);
        socket.send(encodeEnvelope({ version: 1, kind: "hostHello", hostID }));
        expect(parseEnvelope(await ready)).toMatchObject({ kind: "hostReady", hostID });
        if (index % Math.max(1, Math.floor(hostCount / 100)) === 0) {
          sampledStubs.set(index, stub);
        }
        return socket;
      }));
      sockets.push(...connected);
    }

    expect(sockets).toHaveLength(hostCount);
    const probeIndexes = [...sampledStubs.keys()];
    await Promise.all([...sampledStubs.values()].map((stub) => evictDurableObject(stub)));
    await Promise.all(probeIndexes.map(async (index) => {
      const socket = sockets[index];
      if (!socket) throw new Error(`missing probe socket ${index}`);
      const pong = nextMessage(socket);
      socket.send("threading-ping");
      await expect(pong).resolves.toBe("threading-pong");
    }));
    console.info("rendezvous_load_passed", {
      hosts: sockets.length,
      elapsedMilliseconds: Math.round(performance.now() - startedAt),
    });
  } finally {
    for (const socket of sockets) {
      try { socket.close(1000, "load test complete"); } catch { /* already closed */ }
    }
  }
}, 10 * 60 * 1000);

function nextMessage(socket: WebSocket): Promise<string | ArrayBuffer> {
  return new Promise((resolve, reject) => {
    socket.addEventListener("message", (event) => {
      if (typeof event.data === "string" || event.data instanceof ArrayBuffer) {
        resolve(event.data);
      } else {
        reject(new Error("unexpected WebSocket payload"));
      }
    }, { once: true });
  });
}
