CREATE TABLE accounts (
    id TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
) STRICT;

CREATE TABLE apple_assertions (
    digest TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL
) STRICT;

CREATE TABLE refresh_sessions (
    digest TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    consumed_at INTEGER,
    revoked_at INTEGER
) STRICT;

CREATE INDEX refresh_sessions_account_idx ON refresh_sessions(account_id);
CREATE INDEX refresh_sessions_expiry_idx ON refresh_sessions(expires_at);

CREATE TABLE hosts (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    display_name TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    revoked_at INTEGER
) STRICT;

CREATE INDEX hosts_account_idx ON hosts(account_id);

CREATE TABLE rendezvous_credentials (
    digest TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK(kind IN ('host', 'device')),
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
    device_id TEXT,
    expires_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    revoked_at INTEGER,
    CHECK((kind = 'host' AND device_id IS NULL) OR (kind = 'device' AND device_id IS NOT NULL))
) STRICT;

CREATE INDEX rendezvous_credentials_host_idx
    ON rendezvous_credentials(host_id, kind, revoked_at);
CREATE INDEX rendezvous_credentials_device_idx
    ON rendezvous_credentials(host_id, device_id, kind, revoked_at);
CREATE INDEX rendezvous_credentials_expiry_idx ON rendezvous_credentials(expires_at);
