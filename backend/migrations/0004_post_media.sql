-- Familygram migration 0004: multi-photo posts.
--
-- Move the single image_key/thumb_key/width/height columns off `posts` into
-- a side table keyed by (post_id, idx). Existing single-photo posts are
-- backfilled at idx=0 so the column drop is non-lossy.

CREATE TABLE post_media (
  post_id     TEXT NOT NULL,
  idx         INTEGER NOT NULL,                  -- 0-based position in the carousel
  image_key   TEXT NOT NULL,
  thumb_key   TEXT NOT NULL,
  width       INTEGER,
  height      INTEGER,
  PRIMARY KEY (post_id, idx),
  FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE
);

INSERT INTO post_media (post_id, idx, image_key, thumb_key, width, height)
  SELECT id, 0, image_key, thumb_key, width, height FROM posts;

ALTER TABLE posts DROP COLUMN image_key;
ALTER TABLE posts DROP COLUMN thumb_key;
ALTER TABLE posts DROP COLUMN width;
ALTER TABLE posts DROP COLUMN height;
