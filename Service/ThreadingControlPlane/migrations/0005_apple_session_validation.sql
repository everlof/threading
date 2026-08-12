ALTER TABLE accounts ADD COLUMN auth_invalidated_at INTEGER;

ALTER TABLE apple_tokens ADD COLUMN last_validation_attempt_at INTEGER;
ALTER TABLE apple_tokens ADD COLUMN last_validated_at INTEGER;
ALTER TABLE apple_tokens ADD COLUMN invalidated_at INTEGER;

CREATE INDEX apple_tokens_validation_due_idx
    ON apple_tokens(invalidated_at, last_validation_attempt_at);
