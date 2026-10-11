-- Expand-compatible: the previous Worker can still read/write its original columns during
-- rollout. The new Worker requires a grant for every new installation; existing ones renew.
CREATE TABLE pilot_invitations (
    digest TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    claimed_host_id TEXT,
    claimed_secret_digest TEXT,
    claimed_at INTEGER,
    revoked_at INTEGER
) STRICT;

CREATE INDEX pilot_invitations_expiry ON pilot_invitations(expires_at);

ALTER TABLE anonymous_host_identities ADD COLUMN invitation_digest TEXT;

CREATE TRIGGER pilot_invitation_before_identity_insert
BEFORE INSERT ON anonymous_host_identities
WHEN NEW.invitation_digest IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM pilot_invitations
    WHERE digest = NEW.invitation_digest AND revoked_at IS NULL AND expires_at > unixepoch()
      AND claimed_at IS NULL
)
BEGIN
    SELECT RAISE(ABORT, 'threading_pilot_invitation');
END;

CREATE TRIGGER pilot_invitation_after_identity_insert
AFTER INSERT ON anonymous_host_identities
WHEN NEW.invitation_digest IS NOT NULL
BEGIN
    UPDATE pilot_invitations
    SET claimed_host_id = NEW.host_id, claimed_secret_digest = NEW.secret_digest,
        claimed_at = NEW.created_at
    WHERE digest = NEW.invitation_digest;
END;

-- One batch reserves the global day and the installation's hour/day. A CHECK refusal rolls
-- back all counters, including when two Durable Objects compete for the last global slot.
CREATE TABLE turn_issuance_budget (
    scope TEXT NOT NULL,
    period TEXT NOT NULL,
    starts_at INTEGER NOT NULL,
    count INTEGER NOT NULL,
    maximum INTEGER NOT NULL,
    CONSTRAINT threading_turn_budget CHECK (count >= 0 AND count <= maximum),
    PRIMARY KEY (scope, period, starts_at)
) STRICT;

CREATE INDEX turn_issuance_budget_age ON turn_issuance_budget(starts_at);
