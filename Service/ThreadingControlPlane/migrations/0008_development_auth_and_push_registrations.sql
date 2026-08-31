CREATE TABLE development_auth_transactions (
    transaction_digest TEXT PRIMARY KEY,
    poll_token_digest TEXT NOT NULL,
    code_challenge TEXT NOT NULL,
    host_id TEXT NOT NULL,
    authorized_account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
    authorized_identity_digest TEXT,
    expires_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    authorized_at INTEGER,
    consumed_at INTEGER,
    CHECK(
        (authorized_account_id IS NULL AND authorized_identity_digest IS NULL AND authorized_at IS NULL)
        OR
        (authorized_account_id IS NOT NULL AND authorized_identity_digest IS NOT NULL AND authorized_at IS NOT NULL)
    )
) STRICT;

CREATE INDEX development_auth_transactions_expiry_idx
    ON development_auth_transactions(expires_at);

CREATE TABLE push_registrations (
    digest TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    encrypted_device_token TEXT NOT NULL,
    device_token_digest TEXT NOT NULL,
    environment TEXT NOT NULL CHECK(environment IN ('sandbox', 'production')),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    revoked_at INTEGER
) STRICT;

CREATE UNIQUE INDEX push_registrations_active_device_idx
    ON push_registrations(host_id, device_id)
    WHERE revoked_at IS NULL;

CREATE INDEX push_registrations_expiry_lookup_idx
    ON push_registrations(host_id, digest, revoked_at);
