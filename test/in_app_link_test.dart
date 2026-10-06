import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/link_view.dart';
import 'package:get_ride/src/widgets/in_app_page.dart';

// A 1×1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

void main() {
  test('pages, pictures and PDFs stay in the app; calls and other apps do not', () {
    expect(linkViewFor(Uri.parse('https://getride.my/terms-of-service')), LinkView.web);
    expect(linkViewFor(Uri.parse('https://getride.my/privacy')), LinkView.web);
    expect(linkViewFor(Uri.parse('https://x.supabase.co/storage/v1/object/sign/docs/ic.JPG?token=a')), LinkView.image);
    expect(linkViewFor(Uri.parse('https://cdn/permit.pdf')), LinkView.pdf);
    expect(linkViewFor(Uri.parse('https://cdn/trip.m4a')), LinkView.web);
    expect(linkViewFor(Uri.parse('data:image/png;base64,AAAA')), LinkView.image);
    expect(linkViewFor(Uri.parse('data:application/pdf;base64,AAAA')), LinkView.pdf);
    for (final s in ['tel:999', 'sms:+60123', 'mailto:a@b.c', 'waze://?ll=1,2', 'intent://#Intent;end']) {
      expect(linkViewFor(Uri.parse(s)), LinkView.external, reason: s);
    }
  });

  test('a title from the file name, else the host', () {
    expect(linkTitle(Uri.parse('https://cdn/a/my%20permit.pdf')), 'my permit.pdf');
    expect(linkTitle(Uri.parse('https://getride.my/privacy')), 'getride.my');
  });

  Future<void> open(WidgetTester tester, String url, {String? title}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () => openInApp(c, url, title: title),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  testWidgets('a picture opens on a screen of the app, and back returns', (tester) async {
    await open(tester, 'data:image/png;base64,${base64Encode(_png)}', title: 'Photo');
    expect(find.byKey(const ValueKey('image-viewer')), findsOneWidget);
    expect(find.text('Photo'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('go'), findsOneWidget);
  });

  testWidgets('a PDF is drawn page by page', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PdfViewerScreen(
          url: 'https://cdn/a.pdf',
          title: 'Permit',
          load: (_) => Stream<Uint8List>.fromIterable([_png, _png]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pdf-pages')), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('a PDF that will not load says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PdfViewerScreen(url: 'https://cdn/a.pdf', title: 'Permit', load: (_) => Stream.error('offline')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('This document could not be loaded.'), findsOneWidget);
  });
}
