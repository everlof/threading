-- Bounded route/status buckets; never request bodies, identities, URLs or error text.
CREATE TABLE service_failure_alerts (
  window_start INTEGER NOT NULL,
  route TEXT NOT NULL,
  status INTEGER NOT NULL,
  count INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (window_start, route, status)
);
