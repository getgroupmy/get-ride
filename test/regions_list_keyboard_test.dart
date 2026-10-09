import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart';
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart';
import 'package:get_ride/src/admin/screens/geo/regions_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/keyboard_dismiss.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// No token refresh: its timer would outlive the test.
final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _Repo extends GeoAdminRepository {
  _Repo(this.entries) : super(_db);
  final List<RegionEntry> entries;

  @override
  Future<List<RegionEntry>> regions() async => entries;
  @override
  Future<List<ServiceOption>> services() async => const [];
}

const _box =
    '{"coords":[{"latitude":1,"longitude":100},{"latitude":7,"longitude":100},{"latitude":7,"longitude":119}],'
    '"bbox":{"north":7,"south":1,"east":119,"west":100}}';

void main() {
  test('a press that barely moves is a tap; a scroll is not', () {
    expect(isTapOutside(const Offset(10, 10), const Offset(12, 13)), isTrue);
    expect(isTapOutside(const Offset(10, 10), const Offset(10, 80)), isFalse);
  });

  Future<void> pump(WidgetTester tester, Brightness brightness) async {
    // A phone: four buttons and three badges on one row.
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseProvider.overrideWithValue(_db),
          adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
          geoAdminRepositoryProvider.overrideWithValue(
            _Repo([
              RegionEntry(
                id: 'c1',
                values: {
                  'country': 'Malaysia', 'state': '', 'city': '', 'suburb': '', //
                  'boundary': _box, 'blocked': true,
                },
              ),
              RegionEntry(id: 'c2', values: {'country': 'Germany', 'state': '', 'city': '', 'suburb': ''}),
            ]),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          builder: (_, child) => KeyboardDismissOnTap(child: child!),
          home: const AdminRegionsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final b in Brightness.values) {
    testWidgets('a saved country keeps its name beside its badges on a phone (${b.name})', (tester) async {
      await pump(tester, b);
      final name = find.byKey(const ValueKey('region-name-malaysia|||'));
      expect(name, findsOneWidget);
      expect(tester.getSize(name).width, greaterThan(40));
      expect(find.text('Custom'), findsNWidgets(2));
      expect(find.text('Boundary'), findsOneWidget);
      expect(find.text('Blocked'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Searching still finds it by name.
      await tester.enterText(find.byType(TextField), 'ma');
      await tester.pumpAndSettle();
      expect(find.text('Malaysia'), findsOneWidget);
      expect(find.text('Germany'), findsOneWidget);
      await _drain(tester);
    });
  }

  testWidgets('the search keyboard goes on a tap outside, on opening a sheet and on submit', (tester) async {
    await pump(tester, Brightness.light);
    EditableText editable() => tester.widget<EditableText>(find.byType(EditableText).first);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(editable().focusNode.hasFocus, isTrue);
    await tester.tap(find.text('Regions'));
    await tester.pump();
    expect(editable().focusNode.hasFocus, isFalse);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(editable().focusNode.hasFocus, isFalse);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(editable().focusNode.hasFocus, isTrue);
    await tester.tap(find.byTooltip('Edit').first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Edit region'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.context?.widget is EditableText, isFalse);
    await _drain(tester);
  });

  testWidgets('a scroll keeps the keyboard; a screen change closes it', (tester) async {
    final change = ChangeNotifier();
    addTearDown(change.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => KeyboardDismissOnChange(
          listenable: change,
          child: KeyboardDismissOnTap(child: child!),
        ),
        home: Scaffold(
          body: Column(
            children: [
              TextField(focusNode: focus),
              Expanded(
                child: ListView(children: [for (var i = 0; i < 40; i++) ListTile(title: Text('Row $i'))]),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focus.hasFocus, isTrue);

    await tester.drag(find.text('Row 3'), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);

    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    change.notifyListeners();
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    await tester.pumpAndSettle(const Duration(seconds: 2));
  });
}

/// Lets any realtime retry run out.
Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}
