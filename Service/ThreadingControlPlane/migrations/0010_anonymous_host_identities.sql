-- One installation secret owns one accountless Mac. Removing the account revokes the secret.
CREATE TABLE anonymous_host_identities (
    account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    host_id TEXT NOT NULL UNIQUE,
    secret_digest TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL
) STRICT;

CREATE TRIGGER anonymous_host_capacity_before_insert
BEFORE INSERT ON anonymous_host_identities
WHEN (SELECT COUNT(*) FROM anonymous_host_identities) >= 100
BEGIN
    SELECT RAISE(ABORT, 'threading_anon_capacity');
END;

-- Bound accountless relay identities even when concurrent issuance races the Worker check.
CREATE TRIGGER anonymous_host_device_limit_before_insert
BEFORE INSERT ON rendezvous_credentials
WHEN NEW.kind = 'device' AND substr(NEW.account_id, 1, 5) = 'anon_'
    AND (SELECT COUNT(*) FROM rendezvous_credentials
         WHERE host_id = NEW.host_id AND kind = 'device' AND revoked_at IS NULL
           AND expires_at > unixepoch()) >= 8
BEGIN
    SELECT RAISE(ABORT, 'threading_anon_device_limit');
END;
