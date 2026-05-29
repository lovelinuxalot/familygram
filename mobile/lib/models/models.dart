// Media URLs returned from the Worker are HMAC-signed and short-lived
// (~1 hour). We cache by post/user id in cached_network_image so a refresh
// of the URL doesn't trigger a re-download.

class Author {
  final String id;
  final String username;
  final String displayName;
  final String? avatarUrl;
  Author({required this.id, required this.username, required this.displayName, this.avatarUrl});
  factory Author.fromJson(Map<String, dynamic> j) => Author(
        id: j['id'] as String,
        username: j['username'] as String,
        displayName: j['display_name'] as String,
        avatarUrl: j['avatar_url'] as String?,
      );
}

// One photo in a post. A post can hold multiple, indexed 0..N-1.
class PostMedia {
  final int idx;
  final String imageUrl;
  final String thumbUrl;
  final int? width;
  final int? height;
  const PostMedia({required this.idx, required this.imageUrl, required this.thumbUrl, this.width, this.height});
  factory PostMedia.fromJson(Map<String, dynamic> j) => PostMedia(
        idx: j['idx'] as int,
        imageUrl: j['image_url'] as String,
        thumbUrl: j['thumb_url'] as String,
        width: j['width'] as int?,
        height: j['height'] as int?,
      );
}

class Post {
  final String id;
  final String userId;
  final List<PostMedia> media;
  final String? caption;
  final int createdAt;
  final Author author;
  final int likeCount;
  final int commentCount;
  final bool liked;

  Post({
    required this.id,
    required this.userId,
    required this.media,
    required this.caption,
    required this.createdAt,
    required this.author,
    required this.likeCount,
    required this.commentCount,
    required this.liked,
  });

  // Convenience: first photo's URLs / dimensions. Anything that needs the
  // whole carousel should iterate `media` directly.
  PostMedia get firstMedia => media.first;
  String get imageUrl => media.first.imageUrl;
  String get thumbUrl => media.first.thumbUrl;
  int? get width => media.first.width;
  int? get height => media.first.height;

  Post copyWith({int? likeCount, int? commentCount, bool? liked, List<PostMedia>? media}) => Post(
        id: id, userId: userId,
        media: media ?? this.media,
        caption: caption, createdAt: createdAt,
        author: author,
        likeCount: likeCount ?? this.likeCount,
        commentCount: commentCount ?? this.commentCount,
        liked: liked ?? this.liked,
      );

  factory Post.fromJson(Map<String, dynamic> j) => Post(
        id: j['id'] as String,
        userId: j['user_id'] as String,
        media: ((j['media'] as List?) ?? const [])
            .map((m) => PostMedia.fromJson(m as Map<String, dynamic>))
            .toList(),
        caption: j['caption'] as String?,
        createdAt: j['created_at'] as int,
        author: Author.fromJson(j['author'] as Map<String, dynamic>),
        likeCount: j['like_count'] as int? ?? 0,
        commentCount: j['comment_count'] as int? ?? 0,
        liked: j['liked'] as bool? ?? false,
      );
}

class Comment {
  final String id;
  final String userId;
  final String body;
  final int createdAt;
  final String username;
  final String displayName;
  final String? avatarUrl;
  Comment({
    required this.id,
    required this.userId,
    required this.body,
    required this.createdAt,
    required this.username,
    required this.displayName,
    required this.avatarUrl,
  });
  factory Comment.fromJson(Map<String, dynamic> j) => Comment(
        id: j['id'] as String,
        userId: j['user_id'] as String,
        body: j['body'] as String,
        createdAt: j['created_at'] as int,
        username: j['username'] as String? ?? '',
        displayName: j['display_name'] as String? ?? '',
        avatarUrl: j['avatar_url'] as String?,
      );
}

// Public-facing user info (everything we'd show on a profile screen for any
// user, including ourselves). The full /me uses Me; this is for everyone else.
class UserProfile {
  final String id;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final int? createdAt;
  UserProfile({required this.id, required this.username, required this.displayName, this.avatarUrl, this.createdAt});
  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
        id: j['id'] as String,
        username: j['username'] as String,
        displayName: j['display_name'] as String,
        avatarUrl: j['avatar_url'] as String?,
        createdAt: j['created_at'] as int?,
      );
}

// Minimal post shape for grids — just the first photo's thumbnail plus a
// count so the tile can show a multi-photo badge.
class PostThumb {
  final String id;
  final String imageUrl;
  final String thumbUrl;
  final int? width;
  final int? height;
  final int mediaCount;
  final int createdAt;
  PostThumb({
    required this.id,
    required this.imageUrl,
    required this.thumbUrl,
    required this.width,
    required this.height,
    required this.mediaCount,
    required this.createdAt,
  });
  factory PostThumb.fromJson(Map<String, dynamic> j) => PostThumb(
        id: j['id'] as String,
        imageUrl: j['image_url'] as String,
        thumbUrl: j['thumb_url'] as String,
        width: j['width'] as int?,
        height: j['height'] as int?,
        mediaCount: j['media_count'] as int? ?? 1,
        createdAt: j['created_at'] as int,
      );
}

class Me {
  final String id;
  final String email;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final bool isAdmin;
  Me({required this.id, required this.email, required this.username, required this.displayName, this.avatarUrl, this.isAdmin = false});
  factory Me.fromJson(Map<String, dynamic> j) => Me(
        id: j['id'] as String,
        email: j['email'] as String,
        username: j['username'] as String,
        displayName: j['display_name'] as String,
        avatarUrl: j['avatar_url'] as String?,
        isAdmin: (j['is_admin'] as int? ?? 0) == 1,
      );
}

class AllowlistEntry {
  final String email;
  final int addedAt;
  final int? usedAt;
  final String? usedBy;
  final String? userUsername;
  final String? userDisplayName;
  AllowlistEntry({required this.email, required this.addedAt, this.usedAt, this.usedBy, this.userUsername, this.userDisplayName});
  bool get redeemed => usedBy != null;
  factory AllowlistEntry.fromJson(Map<String, dynamic> j) => AllowlistEntry(
        email: j['email'] as String,
        addedAt: j['added_at'] as int,
        usedAt: j['used_at'] as int?,
        usedBy: j['used_by'] as String?,
        userUsername: j['user_username'] as String?,
        userDisplayName: j['user_display_name'] as String?,
      );
}

class AdminUser {
  final String id;
  final String email;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final bool isAdmin;
  final int createdAt;
  AdminUser({required this.id, required this.email, required this.username, required this.displayName, this.avatarUrl, required this.isAdmin, required this.createdAt});
  factory AdminUser.fromJson(Map<String, dynamic> j) => AdminUser(
        id: j['id'] as String,
        email: j['email'] as String,
        username: j['username'] as String,
        displayName: j['display_name'] as String,
        avatarUrl: j['avatar_url'] as String?,
        isAdmin: (j['is_admin'] as int? ?? 0) == 1,
        createdAt: j['created_at'] as int,
      );
}
