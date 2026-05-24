import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';

// Download the post's full image to a temp file and hand it to the system
// share sheet (Save to Photos, Messages, AirDrop, etc on iOS; equivalent on
// Android). Surfaces failures via SnackBar on the supplied context.
Future<void> sharePost(BuildContext context, Post post) async {
  // Capture the popover anchor synchronously, before any awaits. iPad
  // requires this Rect; iPhone ignores it.
  final box = context.findRenderObject() as RenderBox?;
  final origin = (box != null && box.hasSize)
      ? box.localToGlobal(Offset.zero) & box.size
      : null;
  try {
    final dio = Dio();
    final res = await dio.get<List<int>>(
      post.imageUrl,
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = res.data;
    if (bytes == null || bytes.isEmpty) {
      throw Exception('empty image bytes');
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/familygram-${post.id}.jpg');
    await file.writeAsBytes(bytes);
    final subject = '${post.author.displayName} on Familygram';
    final text = post.caption?.trim().isNotEmpty == true
        ? '${post.author.displayName}: ${post.caption}'
        : 'Shared from Familygram';
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: subject,
      text: text,
      sharePositionOrigin: origin,
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share: $e')),
      );
    }
  }
}
