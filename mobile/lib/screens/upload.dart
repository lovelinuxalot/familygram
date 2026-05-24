import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../state/auth.dart';
import '../state/feed.dart';
import '../widgets/mention_field.dart';

// Two-tier encoding:
//   • full image (2000 px / q88) — used when sharing or downloading the post.
//   • "thumb" (which is actually our display tier — 1200 px / q88) — shown
//     on the feed and in the comments sheet. Renders crisp at @3x retina
//     widths up to 400 pt.
// File sizes roughly: full ~700 KB, thumb ~180 KB. Both well under R2 free
// tier even for thousands of posts.
const _kFullMaxEdge = 2000;
const _kThumbMaxEdge = 1200;
const _kJpegQuality = 88;
const _kThumbQuality = 88;

class UploadScreen extends ConsumerStatefulWidget {
  const UploadScreen({super.key});
  @override
  ConsumerState<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends ConsumerState<UploadScreen> {
  XFile? _picked;
  Uint8List? _fullBytes;
  Uint8List? _thumbBytes;
  int? _width, _height;
  bool _processing = false;
  bool _uploading = false;
  String? _error;
  final _caption = TextEditingController();
  final _picker = ImagePicker();

  Future<void> _pick(ImageSource source) async {
    setState(() { _error = null; });
    try {
      final x = await _picker.pickImage(source: source, maxWidth: 4096, maxHeight: 4096, imageQuality: 95);
      if (x == null) return;
      setState(() { _picked = x; _processing = true; _fullBytes = null; _thumbBytes = null; });
      final raw = await x.readAsBytes();
      // Run the decode + double resize + double encode on a background
      // isolate. On low-end Android (Note 8 / Snapdragon 835), this work
      // takes 5–15 seconds and would freeze the UI if kept on the main
      // thread. iPhones don't notice either way.
      final processed = await compute(_processImage, raw);
      setState(() {
        _fullBytes = processed.full;
        _thumbBytes = processed.thumb;
        _width = processed.width;
        _height = processed.height;
        _processing = false;
      });
    } catch (e) {
      setState(() { _processing = false; _error = e.toString(); });
    }
  }

  Future<void> _submit() async {
    if (_fullBytes == null || _thumbBytes == null || _width == null || _height == null) return;
    setState(() { _uploading = true; _error = null; });
    try {
      final api = ref.read(apiClientProvider);
      final post = await api.uploadPost(
        imageBytes: _fullBytes!,
        imageMime: 'image/jpeg',
        thumbBytes: _thumbBytes!,
        width: _width!,
        height: _height!,
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
                if (_picked == null)
                  Column(children: [
                    const SizedBox(height: 16),
                    FilledButton.icon(icon: const Icon(Icons.camera_alt), label: const Text('Take photo'), onPressed: () => _pick(ImageSource.camera)),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(icon: const Icon(Icons.photo_library), label: const Text('Choose from library'), onPressed: () => _pick(ImageSource.gallery)),
                  ])
                else if (_processing)
                  const Center(child: Padding(padding: EdgeInsets.all(48), child: CircularProgressIndicator()))
                else ...[
                  AspectRatio(
                    aspectRatio: (_width != null && _height != null && _height! > 0) ? _width! / _height! : 1.0,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(_fullBytes!, fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(height: 12),
                  MentionTextField(
                    controller: _caption,
                    decoration: const InputDecoration(labelText: 'Caption (optional)', border: OutlineInputBorder()),
                    minLines: 1,
                    maxLines: 3,
                  ),
                  const SizedBox(height: 12),
                  if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
                  FilledButton.icon(
                    icon: _uploading
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send),
                    label: Text(_uploading ? 'Uploading…' : 'Share'),
                    onPressed: _uploading ? null : _submit,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _uploading ? null : () => setState(() { _picked = null; _fullBytes = null; }),
                    child: const Text('Pick a different photo'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

}

// Top-level so `compute()` can hand it across the isolate boundary.
_Processed _processImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw Exception('Could not decode image');
  final exifFixed = img.bakeOrientation(decoded);
  final full = _resize(exifFixed, _kFullMaxEdge);
  final thumb = _resize(exifFixed, _kThumbMaxEdge);
  return _Processed(
    full: Uint8List.fromList(img.encodeJpg(full, quality: _kJpegQuality)),
    thumb: Uint8List.fromList(img.encodeJpg(thumb, quality: _kThumbQuality)),
    width: full.width,
    height: full.height,
  );
}

img.Image _resize(img.Image src, int maxEdge) {
  if (src.width <= maxEdge && src.height <= maxEdge) return src;
  // cubic produces noticeably smoother edges than linear at our scale-down
  // ratios; the CPU cost is ~2× linear but it happens once per upload.
  if (src.width >= src.height) {
    return img.copyResize(src, width: maxEdge, interpolation: img.Interpolation.cubic);
  } else {
    return img.copyResize(src, height: maxEdge, interpolation: img.Interpolation.cubic);
  }
}

class _Processed {
  final Uint8List full;
  final Uint8List thumb;
  final int width;
  final int height;
  _Processed({required this.full, required this.thumb, required this.width, required this.height});
}
