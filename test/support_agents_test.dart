import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/support_agents.dart';

void main() {
  test('agents sort by priority, untagged after, then by name', () {
    final sorted = supportAgentsFromRows([
      {'profile_id': 'c', 'name': 'carol', 'priority': null},
      {'profile_id': 'b', 'name': 'Bob', 'priority': 2},
      {'profile_id': 'a', 'name': 'Ann', 'priority': 1},
      {'profile_id': 'd', 'name': 'Dan', 'priority': null},
      {'profile_id': 'e', 'name': '  ', 'avatar_url': 'https://x/e.png', 'priority': 2},
      {'name': 'no id'},
    ]);
    expect(sorted.map((a) => a.id), ['a', 'e', 'b', 'c', 'd']);
    expect(sorted[1].name, 'Agent');
    expect(sorted[1].avatarUrl, 'https://x/e.png');
  });

  Future<SupportAgent?> pick(WidgetTester tester, List<SupportAgent> agents, {String? currentId}) async {
    SupportAgent? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () async => result = await showSupportAgentPicker(
              c,
              agents: agents,
              meId: 'me',
              meName: 'Me',
              currentId: currentId,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('picker lists me first, other agents, ticks the assignee', (tester) async {
    const agents = <SupportAgent>[
      (id: 'me', name: 'Me', avatarUrl: null, priority: 1),
      (id: 'x', name: 'Xin', avatarUrl: 'storage/path.png', priority: null),
    ];
    await pick(tester, agents, currentId: 'x');
    expect(find.byKey(const ValueKey('assign-me')), findsOneWidget);
    expect(find.byKey(const ValueKey('assign-x')), findsOneWidget);
    expect(find.text('X'), findsOneWidget); // non-http avatar falls back to the initial
    expect(
      find.descendant(of: find.byKey(const ValueKey('assign-x')), matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('assign-x')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('support-agent-picker')), findsNothing);
  });

  testWidgets('picker with only me says there is nobody else', (tester) async {
    await pick(tester, const [(id: 'me', name: 'Me', avatarUrl: null, priority: null)]);
    expect(find.text('No other support agents found.'), findsOneWidget);
  });
}
