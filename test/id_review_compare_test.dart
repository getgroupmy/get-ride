import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/id_review_compare.dart';

void main() {
  group('idReviewRows', () {
    final profile = {
      'name': 'MUHAMAD FAIRUS BIN ISMAIL',
      'ic': '800912016837',
      'birth_date': '1980-09-12',
      'gender': 'male',
      'address': 'OLD ADDRESS',
    };

    test('a matching IC does not count as a difference despite formatting', () {
      final rows = idReviewRows(profile: profile, read: {'ic': '800912-01-6837'});
      final ic = rows.firstWhere((r) => r.key == 'ic');
      expect(ic.hasRead, isTrue);
      expect(ic.differs, isFalse); // dashes stripped → same
      expect(ic.defaultChoice, IdSource.keyed);
    });

    test('a differing address is flagged and defaults to the ID value', () {
      final rows = idReviewRows(profile: profile, read: {'address': 'LOT 7886, JALAN PIMPING, 86000 KLUANG'});
      final addr = rows.firstWhere((r) => r.key == 'address');
      expect(addr.differs, isTrue);
      expect(addr.defaultChoice, IdSource.fromId);
    });

    test('a field the ID could not read offers no choice', () {
      final rows = idReviewRows(profile: profile, read: {'name': 'MUHAMAD FAIRUS BIN ISMAIL'}); // only name read
      final gender = rows.firstWhere((r) => r.key == 'gender');
      expect(gender.hasRead, isFalse);
      expect(gender.differs, isFalse);
    });

    test('name differences ignore case and extra spaces', () {
      final rows = idReviewRows(profile: profile, read: {'name': 'muhamad   fairus bin ismail'});
      expect(rows.firstWhere((r) => r.key == 'name').differs, isFalse);
    });

    test('always returns the five fields in order', () {
      final rows = idReviewRows(profile: profile, read: const {});
      expect(rows.map((r) => r.key).toList(), ['name', 'ic', 'birth_date', 'gender', 'address']);
    });
  });

  group('idReviewChosen', () {
    final profile = {'name': 'OLD NAME', 'ic': '111', 'birth_date': null, 'gender': null, 'address': 'OLD'};
    final read = {'name': 'NEW NAME', 'birth': '1990-01-02', 'gender': 'female', 'address': 'NEW ADDRESS'};

    test('defaults: every differing read field is taken', () {
      final rows = idReviewRows(profile: profile, read: read);
      final chosen = idReviewChosen(rows, const {});
      // name differs, birth/gender/address were empty-then-read (differ), ic had no read.
      expect(chosen, {
        'name': 'NEW NAME',
        'birth_date': '1990-01-02',
        'gender': 'female',
        'address': 'NEW ADDRESS',
      });
    });

    test('an explicit "keep keyed" removes that field from the write', () {
      final rows = idReviewRows(profile: profile, read: read);
      final chosen = idReviewChosen(rows, {'name': IdSource.keyed, 'address': IdSource.keyed});
      expect(chosen.containsKey('name'), isFalse);
      expect(chosen.containsKey('address'), isFalse);
      expect(chosen['gender'], 'female');
    });

    test('nothing read → empty map (no profile write needed)', () {
      final rows = idReviewRows(profile: profile, read: const {});
      expect(idReviewChosen(rows, const {}), isEmpty);
    });
  });
}
