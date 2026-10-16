// The services as a tree: master services (Service Settings), sub-services
// under them or under each other to any depth, from any category.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/service_tree.dart';

ServiceEntry master(String id) => ServiceEntry(id: id, name: id, category: masterServiceCategory);
ServiceEntry sub(
  String id, {
  List<String> parents = const [],
  List<String> types = const [],
  String category = 'vehicle-services',
}) => ServiceEntry(id: id, name: id, category: category, parentIds: parents, typeNames: types);

List<String> shape(List<ServiceNode> nodes) => [
  for (final n in nodes) ...['${'  ' * n.depth}${n.id}', ...shape(n.children)],
];

void main() {
  test('sub-services under their master by type name or id, and under each other to any depth', () {
    final tree = ServiceTree.build(
      [master('Car'), master('Food')],
      [
        sub('ride', types: ['car']),
        sub('ride-xl', parents: ['ride']),
        sub('ride-xl-pet', parents: ['ride-xl']),
        sub('burger', parents: ['Food'], category: 'food-menu'),
        sub('cheese', parents: ['burger'], category: 'food-options'),
      ],
    );
    expect(shape(tree.roots), ['Car', '  ride', '    ride-xl', '      ride-xl-pet', 'Food', '  burger', '    cheese']);
    expect(tree.unlinked, isEmpty);
    expect(tree.lineage('ride-xl-pet'), ['ride-xl-pet', 'ride-xl', 'ride', 'Car']);
    expect(tree.lineage('cheese'), ['cheese', 'burger', 'Food']);
  });

  test('several parents: shown under each; a loop is cut; links to nothing are unlinked', () {
    final tree = ServiceTree.build(
      [master('Car'), master('Bike')],
      [
        sub('courier', types: ['Car', 'Bike']),
        sub('a', parents: ['b']),
        sub('b', parents: ['a']),
        sub('orphan', parents: ['gone'], types: ['Boat']),
        sub('under-orphan', parents: ['orphan']),
        sub('self', parents: ['self', 'Car']),
      ],
    );
    expect(shape(tree.roots), ['Car', '  courier', '  self', 'Bike', '  courier']);
    expect(tree.unlinked.map((n) => n.id), containsAll(['orphan']));
    expect(shape(tree.unlinked).first, 'orphan');
    expect(shape(tree.unlinked)[1], '  under-orphan');
    expect(tree.unlinked.map((n) => n.id), anyOf(contains('a'), contains('b')), reason: 'a loop still shows');
    expect(tree.lineage('a').toSet(), {'a', 'b'});
  });

  test('a region switch: the most specific region that switches each decides; any off is off', () {
    const line = ['ride-xl', 'ride', 'Car'];
    expect(subServiceOn(line, const []), isTrue);
    expect(
      subServiceOn(line, const [
        {'ride': false},
      ]),
      isFalse,
    );
    expect(
      subServiceOn(line, const [
        {'ride': true},
        {'ride': false},
      ]),
      isTrue,
      reason: 'the city turns it back on',
    );
    expect(
      subServiceOn(line, const [
        {'ride': true},
        {'ride-xl': false},
      ]),
      isFalse,
    );
    expect(regionSubServiceSwitches('{"a": true, "b": false, "c": 1}'), {'a': true, 'b': false});
    expect(regionSubServiceSwitches({'a': false}), {'a': false});
    expect(regionSubServiceSwitches(null), isEmpty);
    expect(
      serviceParentIds({
        'parentServices': ['x', ' ', 'y'],
      }),
      ['x', 'y'],
    );
    expect(serviceParentIds({'parentServices': 'x'}), ['x']);
  });
}
