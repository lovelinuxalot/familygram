-- Familygram initial schema.
-- Run with: wrangler d1 migrations apply familygram --remote

CREATE TABLE users (
  id              TEXT PRIMARY KEY,                  -- nanoid
  ory_id          TEXT NOT NULL UNIQUE,              -- Ory identity id
  email           TEXT NOT NULL UNIQUE,
  username        TEXT NOT NULL UNIQUE,
  display_name    TEXT NOT NULL,
  avatar_key      TEXT,                              -- R2 key for avatar
  created_at      INTEGER NOT NULL                   -- unix seconds
);
CREATE INDEX idx_users_ory_id ON users(ory_id);

CREATE TABLE invites (
  code            TEXT PRIMARY KEY,                  -- random short code
  created_by      TEXT,                              -- user id, NULL for bootstrap
  used_by         TEXT,                              -- user id, NULL until redeemed
  used_at         INTEGER,
  expires_at      INTEGER NOT NULL,
  created_at      INTEGER NOT NULL,
  FOREIGN KEY (created_by) REFERENCES users(id),
  FOREIGN KEY (used_by) REFERENCES users(id)
);
CREATE INDEX idx_invites_unused ON invites(used_by) WHERE used_by IS NULL;

CREATE TABLE posts (
  id              TEXT PRIMARY KEY,
  user_id         TEXT NOT NULL,
  image_key       TEXT NOT NULL,                     -- R2 key for full image
  thumb_key       TEXT NOT NULL,                     -- R2 key for thumbnail
  caption         TEXT,
  width           INTEGER,
  height          INTEGER,
  created_at      INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX idx_posts_created ON posts(created_at DESC);
CREATE INDEX idx_posts_user ON posts(user_id, created_at DESC);

CREATE TABLE likes (
  post_id         TEXT NOT NULL,
  user_id         TEXT NOT NULL,
  created_at      INTEGER NOT NULL,
  PRIMARY KEY (post_id, user_id),
  FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX idx_likes_post ON likes(post_id);

CREATE TABLE comments (
  id              TEXT PRIMARY KEY,
  post_id         TEXT NOT NULL,
  user_id         TEXT NOT NULL,
  body            TEXT NOT NULL,
  created_at      INTEGER NOT NULL,
  FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX idx_comments_post ON comments(post_id, created_at ASC);
