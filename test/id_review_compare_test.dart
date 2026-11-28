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

    test('always returns the six fields in order', () {
      final rows = idReviewRows(profile: profile, read: const {});
      expect(rows.map((r) => r.key).toList(), ['name', 'ic', 'birth_date', 'gender', 'address', 'nationality']);
    });
  });

  group('nationality', () {
    test('a code read off the card matches the stored adjective', () {
      final rows = idReviewRows(profile: {'nationality': 'Malaysian'}, read: {'nationality': 'MYS'});
      final nat = rows.firstWhere((r) => r.key == 'nationality');
      expect(nat.read, 'Malaysian'); // shown as the adjective, not the code
      expect(nat.differs, isFalse); // MYS == Malaysian
      expect(nat.defaultChoice, IdSource.keyed);
    });

    test('a different nationality is flagged and shown as an adjective', () {
      final rows = idReviewRows(profile: {'nationality': 'Malaysian'}, read: {'nationality': 'IDN'});
      final nat = rows.firstWhere((r) => r.key == 'nationality');
      expect(nat.read, 'Indonesian');
      expect(nat.differs, isTrue);
      expect(nat.defaultChoice, IdSource.fromId);
      // "Use ID" writes the adjective the profile stores, not the raw code.
      expect(idReviewChosen(rows, const {})['nationality'], 'Indonesian');
    });

    test('an unknown code is kept as read and compared case-insensitively', () {
      final rows = idReviewRows(profile: {'nationality': 'zzz'}, read: {'nationality': 'ZZZ'});
      final nat = rows.firstWhere((r) => r.key == 'nationality');
      expect(nat.read, 'ZZZ');
      expect(nat.differs, isFalse);
    });
  });

  group('idReadType', () {
    test('returns the scan doc_type, trimmed, or null', () {
      expect(idReadType({'doc_type': 'mykad'}), 'mykad');
      expect(idReadType({'doc_type': ' passport '}), 'passport');
      expect(idReadType({'doc_type': ''}), isNull);
      expect(idReadType(const {}), isNull);
    });
  });

  group('idTypeLabel', () {
    test('maps a known key to its label, keeps an unknown, dashes an empty one', () {
      expect(idTypeLabel('mykad'), 'MyKad');
      expect(idTypeLabel('passport'), 'Passport');
      expect(idTypeLabel('licence'), 'Licence');
      expect(idTypeLabel('id_card'), 'id_card'); // not an IdDocType key → as stored
      expect(idTypeLabel(null), '—');
      expect(idTypeLabel(''), '—');
    });
  });

  group('idDocumentsOk', () {
    final profile = {'name': 'SITI BINTI YUSOF', 'ic': '900101145678'};

    test('OK when the type is recognised and name + IC match the keyed', () {
      final read = {'doc_type': 'mykad', 'name': 'SITI BINTI YUSOF', 'ic': '900101-14-5678'};
      expect(idDocumentsOk(idReviewRows(profile: profile, read: read), read), isTrue);
    });

    test('not OK when the name does not match', () {
      final read = {'doc_type': 'mykad', 'name': 'SOMEONE ELSE', 'ic': '900101-14-5678'};
      expect(idDocumentsOk(idReviewRows(profile: profile, read: read), read), isFalse);
    });

    test('not OK when the IC was not read', () {
      final read = {'doc_type': 'mykad', 'name': 'SITI BINTI YUSOF'};
      expect(idDocumentsOk(idReviewRows(profile: profile, read: read), read), isFalse);
    });

    test('not OK when the document type was not identified', () {
      final read = {'name': 'SITI BINTI YUSOF', 'ic': '900101-14-5678'};
      expect(idDocumentsOk(idReviewRows(profile: profile, read: read), read), isFalse);
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

  group('idReadReasonText', () {
    test('each reader reason names what the reviewer should fix', () {
      expect(idReadReasonText('ocr_off'), contains('GET.ocr'));
      expect(idReadReasonText('vision_off'), contains('API Keys'));
      expect(idReadReasonText('too_big'), contains('too large'));
      expect(idReadReasonText('no_text'), contains('no text'));
      expect(idReadReasonText('nothing_found'), contains('no text'));
      expect(idReadReasonText('no_image'), contains('No ID image'));
    });

    test('an empty or null reason is the generic fallback', () {
      final generic = idReadReasonText(null);
      expect(generic, contains('check the reader keys'));
      expect(idReadReasonText(''), generic);
    });

    test("a reader's own message is passed through as-is", () {
      const vision = "The Cloud Vision API isn't enabled for the key's project";
      expect(idReadReasonText(vision), vision);
    });
  });
}
