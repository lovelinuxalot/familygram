-- Familygram migration 0005: staged uploads for resilient multi-photo posts.
--
-- Photos are now uploaded one-at-a-time (POST /media) before the post exists,
-- so a stalling uplink can't kill a whole 5-photo post. Each uploaded photo
-- lands in R2 and gets a pending_media row; POST /posts later consumes the
-- rows (by id, scoped to the owner) into post_media and deletes them. Rows
-- left behind by an abandoned upload are swept on the user's next upload.

CREATE TABLE pending_media (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL,
  image_key  TEXT NOT NULL,
  thumb_key  TEXT NOT NULL,
  width      INTEGER,
  height     INTEGER,
  created_at INTEGER NOT NULL
);

-- Owner-scoped lookups on consume, and the created_at filter on the orphan sweep.
CREATE INDEX idx_pending_media_user ON pending_media (user_id, created_at);
