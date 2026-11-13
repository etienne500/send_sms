// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:camsms_campaign_manager/src/contact_import.dart';
import 'package:camsms_campaign_manager/src/models.dart';

void main() {
  test('normalizes Cameroon phone numbers', () {
    expect(normalizeCameroonPhone('+237 6 70 12 34 56'), '670123456');
    expect(normalizeCameroonPhone('invalid'), isEmpty);
  });

  test('contact search ignores case and accents', () {
    expect(normalizeContactSearch('ÉLODIE'), 'elodie');
    expect(normalizeContactSearch('elodie'), 'elodie');
    expect(normalizeContactSearch('e\u0301lodie'), 'elodie');
  });

  test('imports VCF names and phone numbers without duplicate numbers', () {
    const vcf = '''BEGIN:VCARD
VERSION:3.0
N:Doe;Jane;Marie;;
FN:Jane Marie Doe
TEL;TYPE=CELL:+237 670 123 456
TEL;TYPE=HOME:00237670123456
END:VCARD
BEGIN:VCARD
VERSION:3.0
FN:John Smith
TEL;TYPE=CELL:+237 699 111 222
END:VCARD''';

    final contacts = parseVCardContacts(vcf);

    expect(contacts, hasLength(2));
    expect(contacts.first.name, 'Jane Marie Doe');
    expect(contacts.first.phone, '670123456');
    expect(contacts.last.name, 'John Smith');
    expect(contacts.last.phone, '699111222');
  });

  test('parses pasted numbers into unique normalized Cameroon numbers', () {
    final numbers = parsePastedCameroonNumbers(
      '+237 670 123 456, 699 111 222;\n00237670123456\ninvalid',
    );

    expect(numbers.map((entry) => entry.phone), ['670123456', '699111222']);
    expect(numbers.map((entry) => entry.operator), ['MTN', 'ORANGE']);
  });

  test(
      'generated random test numbers cannot be normalized or used as recipients',
      () {
    final generated = generateSyntheticTestPhones(100, Random(1));

    expect(generated, hasLength(100));
    expect(generated.toSet(), hasLength(100));
    expect(
      generated
          .every((phone) => RegExp(r'^\+237 000 \d{3} \d{3}$').hasMatch(phone)),
      isTrue,
    );
    expect(generated.every(isSyntheticTestPhone), isTrue);
    expect(generated.every((phone) => normalizeCameroonPhone(phone).isEmpty),
        isTrue);
    expect(parsePastedCameroonNumbers(generated.join(', ')), isEmpty);
    expect(isSyntheticTestPhone('00237 000 123 456'), isTrue);
  });
}
