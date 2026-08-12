import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { Env } from "../src/environment";
import { decryptAppleToken, encryptAppleToken } from "../src/apple-tokens";

const testEnv = env as unknown as Env;

describe("Apple token storage", () => {
  it("round trips an encrypted refresh token without retaining plaintext", async () => {
    const plaintext = "apple_refresh_secret-value";
    const encrypted = await encryptAppleToken(plaintext, testEnv);

    expect(encrypted).not.toContain(plaintext);
    await expect(decryptAppleToken(encrypted, testEnv)).resolves.toBe(plaintext);
  });

  it("rejects modified ciphertext", async () => {
    const encrypted = await encryptAppleToken("apple_refresh_secret-value", testEnv);
    const replacement = encrypted.endsWith("A") ? "B" : "A";

    await expect(decryptAppleToken(encrypted.slice(0, -1) + replacement, testEnv))
      .rejects.toMatchObject({ status: 503, code: "serviceConfiguration" });
  });
});
