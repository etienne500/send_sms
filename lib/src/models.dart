import 'dart:math';

class Contact {
  final int? id;
  final String name, phone;
  const Contact({this.id, required this.name, required this.phone});
}

class ContactDraft {
  final String name, phone;
  const ContactDraft(this.name, this.phone);
}

class ContactGroup {
  final int id, count;
  final String name;
  const ContactGroup({required this.id, required this.name, this.count = 0});
}

class SmsTemplate {
  final int id;
  final String name, body;
  const SmsTemplate({required this.id, required this.name, required this.body});
}

class SimCard {
  final int subscriptionId, slot;
  final String carrier, displayName;
  const SimCard(
      {required this.subscriptionId,
      required this.slot,
      required this.carrier,
      required this.displayName});
  factory SimCard.fromMap(Map<dynamic, dynamic> m) => SimCard(
        subscriptionId: m['subscriptionId'] as int,
        slot: m['slotIndex'] as int? ?? 0,
        carrier: m['carrierName']?.toString() ?? '',
        displayName: m['displayName']?.toString() ?? '',
      );
}

class SmsCampaign {
  final int id, groupId, intervalMs, total, sent, failed, pending;
  final String name, message, signature, simMode, status, groupName;
  const SmsCampaign(
      {required this.id,
      required this.groupId,
      required this.intervalMs,
      required this.total,
      required this.sent,
      required this.failed,
      required this.pending,
      required this.name,
      required this.message,
      required this.signature,
      required this.simMode,
      required this.status,
      required this.groupName});
}

class CampaignDraft {
  final String name, message, signature;
  final int groupId, intervalMs;
  final String simMode;
  final List<ContactDraft> directRecipients;
  CampaignDraft(
    this.name,
    this.message,
    this.signature,
    this.groupId,
    this.intervalMs,
    this.simMode, {
    this.directRecipients = const [],
  });
}

class ContactNumberEntry {
  final String phone;
  final String operator;
  const ContactNumberEntry(this.phone, this.operator);
}

class GatewayHost {
  final int id;
  final String name, url, socketPath, deviceId, room;
  final bool enabled;
  const GatewayHost({
    required this.id,
    required this.name,
    required this.url,
    required this.socketPath,
    required this.deviceId,
    required this.room,
    required this.enabled,
  });
}

String normalizeCameroonPhone(String raw) {
  var phone = raw.trim().replaceAll(RegExp(r'[\s().-]'), '');
  if (phone.startsWith('+237')) phone = phone.substring(4);
  if (phone.startsWith('00237')) phone = phone.substring(5);
  if (RegExp(r'^\d{9}$').hasMatch(phone) && !phone.startsWith('000')) {
    return phone;
  }
  return '';
}

bool isSyntheticTestPhone(String raw) {
  var phone = raw.trim().replaceAll(RegExp(r'[\s().-]'), '');
  if (phone.startsWith('+237')) phone = phone.substring(4);
  if (phone.startsWith('00237')) phone = phone.substring(5);
  return RegExp(r'^000\d{6}$').hasMatch(phone);
}

String? normalizeCameroonPhoneOrNull(String raw) {
  final phone = normalizeCameroonPhone(raw);
  return phone.isEmpty ? null : phone;
}

String operatorFor(String raw) {
  final phone = normalizeCameroonPhone(raw);
  if (phone.isEmpty) return 'INCONNU';

  const mtnPrefixes = {
    '650', '651', '652', '653', '654',
    '670', '671', '672', '673', '674',
    '675', '676', '677', '678', '679',
    '680', '681', '682', '683', '684',
    '687', '688', '689',
  };
  const orangePrefixes = {
    '655', '656', '657', '658', '659',
    '685', '686',
    '690', '691', '692', '693', '694',
    '695', '696', '697', '698', '699',
  };

  final prefix = phone.substring(0, 3);
  if (mtnPrefixes.contains(prefix)) return 'MTN';
  if (orangePrefixes.contains(prefix)) return 'ORANGE';
  return 'INCONNU';
}

List<ContactNumberEntry> parsePastedCameroonNumbers(String input) {
  final entries = <ContactNumberEntry>[];
  final seen = <String>{};
  for (final item in input.split(RegExp(r'[,;\n\r]+'))) {
    final phone = normalizeCameroonPhone(item);
    if (phone.isEmpty || !seen.add(phone)) continue;
    entries.add(ContactNumberEntry(phone, operatorFor(phone)));
  }
  return entries;
}



List<String> generatePhones(
  String? operateur,
  int count,
  Random random,
) {
  if (count < 0 || count > 1000) {
    throw RangeError.range(count, 0, 1000, 'count');
  }

  const mtnPrefixes = [
    '670', '671', '672', '673', '674',
    '675', '676', '677', '678', '679',
    '650', '651', '652', '653', '654',
    '680', '681', '682', '683', '684',
    '687', '688', '689',
  ];

  const orangePrefixes = [
    '690', '691', '692', '693', '694',
    '695', '696', '697', '698', '699',
    '655', '656', '657', '658', '659',
    '685', '686',
  ];

  final List<String> prefixes;

  if (operateur?.toUpperCase() == 'MTN') {
    prefixes = mtnPrefixes;
  } else if (operateur?.toUpperCase() == 'ORANGE') {
    prefixes = orangePrefixes;
  } else {
    prefixes = [...mtnPrefixes, ...orangePrefixes];
  }

  final phones = <String>{};

  while (phones.length < count) {
    final prefix = prefixes[random.nextInt(prefixes.length)];

    final suffix = List.generate(
      6,
      (_) => random.nextInt(10),
    ).join();

    phones.add('+237 $prefix $suffix');
  }

  return phones.toList();
}



String normalizeContactSearch(String value) {
  var normalized = value.toLowerCase();
  const accentGroups = {
    'a': 'àáâãäåāăąǎ',
    'c': 'çćĉċč',
    'd': 'ďđ',
    'e': 'èéêëēĕėęě',
    'g': 'ĝğġģ',
    'h': 'ĥħ',
    'i': 'ìíîïĩīĭįı',
    'j': 'ĵ',
    'k': 'ķ',
    'l': 'ĺļľŀł',
    'n': 'ñńņň',
    'o': 'òóôõöøōŏő',
    'r': 'ŕŗř',
    's': 'śŝşš',
    't': 'ţťŧ',
    'u': 'ùúûüũūŭůűų',
    'w': 'ŵ',
    'y': 'ýÿŷ',
    'z': 'źżž',
  };
  for (final entry in accentGroups.entries) {
    normalized = normalized.replaceAll(RegExp('[${entry.value}]'), entry.key);
  }
  return normalized
      .replaceAll('æ', 'ae')
      .replaceAll('œ', 'oe')
      .replaceAll('ß', 'ss')
      .replaceAll('þ', 'th')
      .replaceAll(RegExp('[\u0300-\u036f]'), '');
}
