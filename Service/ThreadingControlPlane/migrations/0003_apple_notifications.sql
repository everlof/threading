CREATE TABLE apple_notifications (
    jti_digest TEXT PRIMARY KEY,
    expires_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL
) STRICT;

CREATE INDEX apple_notifications_expiry_idx ON apple_notifications(expires_at);
