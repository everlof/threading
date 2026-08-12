-- Anonymous native reports need a distributed cost ceiling in addition to per-location edge
-- limits. This table deliberately stores no source, report id, or other customer metadata.
CREATE TABLE issue_report_daily_quota (
    day TEXT PRIMARY KEY CHECK(length(day) = 10),
    accepted_count INTEGER NOT NULL CHECK(accepted_count >= 0)
) STRICT;
