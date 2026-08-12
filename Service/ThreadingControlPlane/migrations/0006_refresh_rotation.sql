ALTER TABLE refresh_sessions ADD COLUMN replacement_digest TEXT;
ALTER TABLE refresh_sessions ADD COLUMN replacement_encrypted_token TEXT;
ALTER TABLE refresh_sessions ADD COLUMN replacement_expires_at INTEGER;

CREATE INDEX refresh_sessions_replacement_idx ON refresh_sessions(replacement_digest);

CREATE TRIGGER refresh_active_limit_before_insert
BEFORE INSERT ON refresh_sessions
WHEN (
    SELECT COUNT(*)
    FROM refresh_sessions
    WHERE account_id = NEW.account_id
        AND consumed_at IS NULL
        AND revoked_at IS NULL
        AND expires_at > CAST(strftime('%s', 'now') AS INTEGER)
) >= 64
BEGIN
    SELECT RAISE(ABORT, 'threading_refresh_active_limit');
END;

CREATE TRIGGER refresh_stored_limit_before_insert
BEFORE INSERT ON refresh_sessions
WHEN (
    SELECT COUNT(*)
    FROM refresh_sessions
    WHERE account_id = NEW.account_id
) >= 256
BEGIN
    SELECT RAISE(ABORT, 'threading_refresh_stored_limit');
END;
