CREATE TABLE apple_tokens (
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    client_id TEXT NOT NULL,
    encrypted_refresh_token TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (account_id, client_id)
) STRICT;
