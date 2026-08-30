-- Familygram migration 0009: in-app content reports.
--
-- Why: Google Play's Child Safety Standards policy requires apps in the Social
-- category to let users report child-safety concerns from inside the app, not
-- only by email. This table is the sink for those reports.
--
-- Rows are deliberately NOT deleted when the reported post or comment is
-- removed — the report is the audit trail, and the whole point is that it
-- survives the offending content. Hence target_id is a plain TEXT with no
-- foreign key, and the reporter's own text is kept verbatim.

CREATE TABLE reports (
  id           TEXT PRIMARY KEY,
  reporter_id  TEXT NOT NULL,
  tenant_id    TEXT NOT NULL,
  target_type  TEXT NOT NULL CHECK (target_type IN ('post', 'comment')),
  target_id    TEXT NOT NULL,
  target_owner TEXT,
  reason       TEXT NOT NULL CHECK (reason IN ('child_safety', 'nudity', 'harassment', 'other')),
  note         TEXT,
  created_at   INTEGER NOT NULL,
  FOREIGN KEY (reporter_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX idx_reports_created ON reports(created_at DESC);
CREATE INDEX idx_reports_target ON reports(target_type, target_id);
