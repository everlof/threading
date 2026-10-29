-- Independent of alert delivery: evidence remains available after a successful page.
-- At most eight content-free examples per fixed route/status/15-minute bucket, for seven days.
CREATE TABLE service_failure_diagnostics (
  window_start INTEGER NOT NULL,
  route TEXT NOT NULL,
  status INTEGER NOT NULL,
  count INTEGER NOT NULL,
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  samples TEXT NOT NULL CHECK (json_valid(samples) AND json_array_length(samples) <= 8),
  PRIMARY KEY (window_start, route, status)
);
