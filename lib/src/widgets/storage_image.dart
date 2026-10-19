// A network picture that may live in a private document bucket: the
// skeleton while its signed link is made, then the picture. Anything else
// is shown exactly as Image.network would. With [StorageImage.preferThumb],
// a document photo is shown from the small thumbnail stored beside it, and
// from the file itself only when it has none (an older upload).
import 'package:flutter/material.dart';

import '../core/doc_photo.dart' show docThumbUrl;
import '../core/storage_links.dart';
import '../data/storage_links.dart';
import 'net_image.dart';

class StorageImage extends StatefulWidget {
  const StorageImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.frameBuilder,
    this.errorBuilder,
    this.loadingBuilder,
    this.cacheWidth,
    this.cacheHeight,
    this.preferThumb = false,
  });

  final String url;
  final double? width, height;
  final BoxFit? fit;
  final Alignment alignment;
  final ImageFrameBuilder? frameBuilder;
  final ImageErrorWidgetBuilder? errorBuilder;
  final ImageLoadingBuilder? loadingBuilder;

  /// The size to decode the picture at (see [Image.network]).
  final int? cacheWidth, cacheHeight;

  /// Show the list thumbnail beside the file when there is one: for a
  /// picture in a list or a small slot. Opening it shows the file itself.
  final bool preferThumb;

  @override
  State<StorageImage> createState() => _StorageImageState();
}

class _StorageImageState extends State<StorageImage> {
  Future<String>? _link;

  /// The thumbnail being shown, while it is.
  String? _thumb;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(StorageImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.preferThumb != widget.preferThumb) _resolve();
  }

  void _resolve() {
    _thumb = null;
    if (privateStorageRef(widget.url) == null) {
      _link = null;
      return;
    }
    final thumb = widget.preferThumb ? docThumbUrl(widget.url) : null;
    if (thumb == null) {
      _link = signedStorageUrl(widget.url);
      return;
    }
    _thumb = thumb;
    final url = widget.url;
    _link = signedThumbUrl(url).then((t) {
      if (t != null) return t;
      if (_thumb == thumb) _thumb = null;
      return signedStorageUrl(url);
    });
  }

  Widget _image(String url, {bool thumb = false}) => Image.network(
    url,
    width: widget.width,
    height: widget.height,
    fit: widget.fit,
    alignment: widget.alignment,
    frameBuilder: widget.frameBuilder,
    // A thumbnail that won't load gives way to the file itself.
    errorBuilder: thumb ? _thumbFailed : widget.errorBuilder,
    loadingBuilder: widget.loadingBuilder,
    cacheWidth: widget.cacheWidth,
    cacheHeight: widget.cacheHeight,
  );

  Widget _thumbFailed(BuildContext context, Object error, StackTrace? stack) {
    final thumb = _thumb;
    if (thumb != null) markThumbMissing(thumb);
    return StorageImage(
      widget.url,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      frameBuilder: widget.frameBuilder,
      errorBuilder: widget.errorBuilder,
      loadingBuilder: widget.loadingBuilder,
      cacheWidth: widget.cacheWidth,
      cacheHeight: widget.cacheHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final link = _link;
    if (link == null) return _image(widget.url);
    return FutureBuilder<String>(
      future: link,
      builder: (context, snap) =>
          snap.hasData ? _image(snap.data!, thumb: _thumb != null) : ImageBone(width: widget.width, height: widget.height),
    );
  }
}
