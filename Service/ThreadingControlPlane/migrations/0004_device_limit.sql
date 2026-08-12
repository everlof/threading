-- Keep the product cap race-safe. D1 batches are transactional, so a failed insert also rolls
-- back issueDeviceCredential's preceding revocation of an older credential for the same device.
CREATE TRIGGER rendezvous_device_limit_before_insert
BEFORE INSERT ON rendezvous_credentials
WHEN NEW.kind = 'device'
    AND NEW.revoked_at IS NULL
    AND (
        SELECT COUNT(*)
        FROM rendezvous_credentials
        WHERE host_id = NEW.host_id
            AND kind = 'device'
            AND revoked_at IS NULL
            AND expires_at > CAST(strftime('%s', 'now') AS INTEGER)
    ) >= 64
BEGIN
    SELECT RAISE(ABORT, 'threading_device_limit');
END;
