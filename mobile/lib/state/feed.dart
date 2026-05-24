import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/api_client.dart';
import '../models/models.dart';
import 'auth.dart';

class FeedState {
  final List<Post> items;
  final String? nextCursor;
  final bool loading;
  final bool exhausted;
  final Object? error;
  const FeedState({this.items = const [], this.nextCursor, this.loading = false, this.exhausted = false, this.error});
  FeedState copyWith({List<Post>? items, String? nextCursor, bool? loading, bool? exhausted, Object? error, bool clearCursor = false}) =>
      FeedState(
        items: items ?? this.items,
        nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
        loading: loading ?? this.loading,
        exhausted: exhausted ?? this.exhausted,
        error: error,
      );
}

class FeedController extends StateNotifier<FeedState> {
  final ApiClient _api;
  FeedController(this._api) : super(const FeedState());

  Future<void> refresh() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final page = await _api.feed();
      state = FeedState(items: page.items, nextCursor: page.nextCursor, exhausted: page.nextCursor == null);
    } catch (e) {
      state = state.copyWith(loading: false, error: e);
    }
  }

  Future<void> loadMore() async {
    if (state.loading || state.exhausted) return;
    state = state.copyWith(loading: true);
    try {
      final page = await _api.feed(cursor: state.nextCursor);
      state = FeedState(
        items: [...state.items, ...page.items],
        nextCursor: page.nextCursor,
        exhausted: page.nextCursor == null,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e);
    }
  }

  void replacePost(Post p) {
    state = state.copyWith(items: [for (final it in state.items) if (it.id == p.id) p else it]);
  }

  void prepend(Post p) {
    state = state.copyWith(items: [p, ...state.items]);
  }

  void remove(String id) {
    state = state.copyWith(items: state.items.where((p) => p.id != id).toList());
  }
}

final feedProvider = StateNotifierProvider<FeedController, FeedState>((ref) {
  return FeedController(ref.read(apiClientProvider));
});
