import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

// Wrangler validates the production required-secret contract before Miniflare applies its
// explicit bindings. Supply process-local placeholders so the test runner exercises that gate
// without reading a developer's real Cloudflare or Apple environment. The worker itself receives
// the deterministic bindings below, where optional network integrations stay disabled.
Object.assign(process.env, {
  SESSION_SIGNING_SECRET: "test-required-signing-secret-at-least-32-bytes",
  APPLE_TEAM_ID: "test-required-team",
  APPLE_KEY_ID: "test-required-key",
  APPLE_PRIVATE_KEY: "test-required-private-key",
  APPLE_TOKEN_ENCRYPTION_SECRET: "test-required-encryption-secret-at-least-32-bytes",
  TURN_KEY_ID: "test-required-turn-key",
  TURN_KEY_API_TOKEN: "test-required-turn-token",
});

export default defineConfig({
  plugins: [
    cloudflareTest(async () => {
      const migrations = await readD1Migrations(
        fileURLToPath(new URL("./migrations", import.meta.url)),
      );
      return {
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            SESSION_SIGNING_SECRET: "test-only-signing-secret-that-is-at-least-32-bytes",
            APPLE_TEAM_ID: "",
            APPLE_KEY_ID: "",
            APPLE_PRIVATE_KEY: "",
            APPLE_TOKEN_ENCRYPTION_SECRET: "test-only-apple-token-secret-at-least-32-bytes",
            TURN_KEY_ID: "",
            TURN_KEY_API_TOKEN: "",
            TEST_RENDEZVOUS_LOAD: process.env.THREADING_RENDEZVOUS_LOAD ?? "0",
            TEST_RENDEZVOUS_LOAD_HOSTS: process.env.THREADING_RENDEZVOUS_LOAD_HOSTS ?? "100",
            TEST_MIGRATIONS: migrations,
          },
        },
      };
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
    setupFiles: ["./test/apply-migrations.ts"],
    testTimeout: 10_000,
  },
});
