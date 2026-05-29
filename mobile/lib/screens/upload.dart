import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../api/api_client.dart';
import '../state/auth.dart';
import '../state/feed.dart';
import '../widgets/mention_field.dart';

// Two-tier WebP encoding via native platform codecs (flutter_image_compress).
//   • full (2000 px / q82) — used when sharing or downloading the post.
//   • thumb (1200 px / q80) — shown on the feed and in the comments sheet.
// WebP at these qualities matches JPEG q88 visually but is ~35% smaller.
// Native codecs are also ~5x faster than the pure-Dart `image` package the
// previous implementation used.
const _kFullMaxEdge = 2000;
const _kThumbMaxEdge = 1200;
const _kFullQuality = 82;
const _kThumbQuality = 80;

// Fallback cap if /config hasn't loaded yet. Worker has the authoritative
// number; this is just so the picker behaves sensibly when offline at boot.
const _kFallbackMaxMedia = 5;

class UploadScreen extends ConsumerStatefulWidget {
  const UploadScreen({super.key});
  @override
  ConsumerState<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends ConsumerState<UploadScreen> {
  final List<_PickedItem> _items = [];
  bool _processing = false;
  bool _uploading = false;
  String? _error;
  final _caption = TextEditingController();
  final _picker = ImagePicker();

  int get _maxMedia => ApiClient.lastConfig?.maxPostMedia ?? _kFallbackMaxMedia;
  int get _remaining => (_maxMedia - _items.length).clamp(0, _maxMedia);

  Future<void> _pickFromCamera() async {
    if (_remaining <= 0) return;
    setState(() { _error = null; });
    try {
      final x = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 4096,
        maxHeight: 4096,
        imageQuality: 95,
      );
      if (x == null) return;
      await _ingest([x]);
    } catch (e) {
      setState(() { _processing = false; _error = e.toString(); });
    }
  }

  Future<void> _pickFromLibrary() async {
    if (_remaining <= 0) return;
    setState(() { _error = null; });
    try {
      final picked = await _picker.pickMultiImage(
        maxWidth: 4096,
        maxHeight: 4096,
        imageQuality: 95,
        limit: _remaining,
      );
      if (picked.isEmpty) return;
      // pickMultiImage may return more than `limit` on some platforms — clamp.
      final trimmed = picked.take(_remaining).toList();
      await _ingest(trimmed);
    } catch (e) {
      setState(() { _processing = false; _error = e.toString(); });
    }
  }

  Future<void> _ingest(List<XFile> picked) async {
    setState(() { _processing = true; });
    try {
      final processed = <_PickedItem>[];
      for (final x in picked) {
        final raw = await x.readAsBytes();
        final p = await _processImage(raw);
        processed.add(_PickedItem(source: x, full: p.full, thumb: p.thumb, width: p.width, height: p.height));
      }
      if (!mounted) return;
      setState(() {
        _items.addAll(processed);
        _processing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _processing = false; _error = e.toString(); });
    }
  }

  void _removeAt(int index) {
    setState(() { _items.removeAt(index); });
  }

  Future<void> _submit() async {
    if (_items.isEmpty) return;
    setState(() { _uploading = true; _error = null; });
    try {
      final api = ref.read(apiClientProvider);
      final post = await api.uploadPost(
        media: _items
            .map((it) => UploadMedia(
                  imageBytes: it.full,
                  imageMime: 'image/webp',
                  thumbBytes: it.thumb,
                  width: it.width,
                  height: it.height,
                ))
            .toList(),
        caption: _caption.text.trim(),
      );
      ref.read(feedProvider.notifier).prepend(post);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Shared with the family.'), duration: Duration(seconds: 2)),
      );
      context.go('/');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New post')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_items.isEmpty && !_processing) _pickerButtons(),
                if (_items.isNotEmpty) ...[
                  _carouselPreview(),
                  const SizedBox(height: 8),
                  Text(
                    '${_items.length} of $_maxMedia photo${_maxMedia == 1 ? "" : "s"}',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  if (_remaining > 0)
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.add_a_photo, size: 18),
                          label: const Text('Add more'),
                          onPressed: _processing || _uploading ? null : _pickFromLibrary,
                        ),
                      ),
                    ]),
                  const SizedBox(height: 12),
                  MentionTextField(
                    controller: _caption,
                    decoration: const InputDecoration(labelText: 'Caption (optional)', border: OutlineInputBorder()),
                    minLines: 1,
                    maxLines: 3,
                  ),
                  const SizedBox(height: 12),
                  if (_error != null)
                    Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
                  FilledButton.icon(
                    icon: _uploading
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send),
                    label: Text(_uploading ? 'Uploading…' : 'Share'),
                    onPressed: _uploading ? null : _submit,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _uploading ? null : () => setState(() { _items.clear(); }),
                    child: const Text('Start over'),
                  ),
                ],
                if (_processing)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pickerButtons() {
    return Column(children: [
      const SizedBox(height: 16),
      FilledButton.icon(
        icon: const Icon(Icons.camera_alt),
        label: const Text('Take photo'),
        onPressed: _pickFromCamera,
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        icon: const Icon(Icons.photo_library),
        label: Text(_maxMedia > 1 ? 'Choose up to $_maxMedia from library' : 'Choose from library'),
        onPressed: _pickFromLibrary,
      ),
    ]);
  }

  Widget _carouselPreview() {
    // First image sets the aspect ratio of the preview pane; later images
    // are letter-boxed inside it so the layout doesn't jump per page.
    final first = _items.first;
    final ar = first.height > 0 ? first.width / first.height : 1.0;
    final ctrl = PageController();
    return Column(children: [
      AspectRatio(
        aspectRatio: ar,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(children: [
            PageView.builder(
              controller: ctrl,
              itemCount: _items.length,
              itemBuilder: (_, i) {
                final it = _items[i];
                return Container(
                  color: Colors.black,
                  child: Center(child: Image.memory(it.full, fit: BoxFit.contain)),
                );
              },
            ),
            if (_items.length > 1)
              Positioned(
                top: 8, right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: AnimatedBuilder(
                    animation: ctrl,
                    builder: (_, __) {
                      final page = ctrl.hasClients && ctrl.page != null ? ctrl.page!.round() : 0;
                      return Text('${page + 1}/${_items.length}', style: const TextStyle(color: Colors.white, fontSize: 12));
                    },
                  ),
                ),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      // Strip of small thumbnails with delete affordances.
      SizedBox(
        height: 64,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final it = _items[i];
            return Stack(clipBehavior: Clip.none, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(it.thumb, width: 64, height: 64, fit: BoxFit.cover),
              ),
              Positioned(
                top: -6, right: -6,
                child: InkWell(
                  onTap: _uploading ? null : () => _removeAt(i),
                  child: Container(
                    decoration: const BoxDecoration(color: Colors.black87, shape: BoxShape.circle),
                    padding: const EdgeInsets.all(2),
                    child: const Icon(Icons.close, color: Colors.white, size: 14),
                  ),
                ),
              ),
            ]);
          },
        ),
      ),
    ]);
  }

}

class _PickedItem {
  final XFile source;
  final Uint8List full;
  final Uint8List thumb;
  final int width;
  final int height;
  _PickedItem({required this.source, required this.full, required this.thumb, required this.width, required this.height});
}

Future<_Processed> _processImage(Uint8List bytes) async {
  final full = await FlutterImageCompress.compressWithList(
    bytes,
    minWidth: _kFullMaxEdge,
    minHeight: _kFullMaxEdge,
    quality: _kFullQuality,
    format: CompressFormat.webp,
    keepExif: false,
  );
  if (full.isEmpty) throw Exception('Could not compress full image');

  final thumb = await FlutterImageCompress.compressWithList(
    full,
    minWidth: _kThumbMaxEdge,
    minHeight: _kThumbMaxEdge,
    quality: _kThumbQuality,
    format: CompressFormat.webp,
    keepExif: false,
  );
  if (thumb.isEmpty) throw Exception('Could not compress thumb image');

  final dims = await _imageDimensions(full);
  return _Processed(full: full, thumb: thumb, width: dims.$1, height: dims.$2);
}

Future<(int, int)> _imageDimensions(Uint8List bytes) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromList(bytes, completer.complete);
  final img = await completer.future;
  final wh = (img.width, img.height);
  img.dispose();
  return wh;
}

class _Processed {
  final Uint8List full;
  final Uint8List thumb;
  final int width;
  final int height;
  _Processed({required this.full, required this.thumb, required this.width, required this.height});
}
