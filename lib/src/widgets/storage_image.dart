// A network picture that may live in a private document bucket: the
// skeleton while its signed link is made, then the picture. Anything else
// is shown exactly as Image.network would.
import 'package:flutter/material.dart';

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

  @override
  State<StorageImage> createState() => _StorageImageState();
}

class _StorageImageState extends State<StorageImage> {
  Future<String>? _link;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(StorageImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _resolve();
  }

  void _resolve() => _link = privateStorageRef(widget.url) == null ? null : signedStorageUrl(widget.url);

  Widget _image(String url) => Image.network(
    url,
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

  @override
  Widget build(BuildContext context) {
    final link = _link;
    if (link == null) return _image(widget.url);
    return FutureBuilder<String>(
      future: link,
      builder: (context, snap) =>
          snap.hasData ? _image(snap.data!) : ImageBone(width: widget.width, height: widget.height),
    );
  }
}
