import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'models.dart';
import 'sms_bridge.dart';

List<ContactDraft> parseVCardContacts(String content) {
  final unfolded = content
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'\n[ \t]'), '');
  final cards = <List<String>>[];
  List<String>? current;
  for (var line in unfolded.split('\n')) {
    line = line.replaceFirst('\uFEFF', '');
    if (line.trim().toUpperCase() == 'BEGIN:VCARD') {
      current = [];
    } else if (line.trim().toUpperCase() == 'END:VCARD') {
      if (current != null) cards.add(current);
      current = null;
    } else if (current != null && line.isNotEmpty) {
      current.add(line);
    }
  }

  final contacts = <ContactDraft>[];
  final seenPhones = <String>{};
  for (final card in cards) {
    String? formattedName;
    String structuredName = '';
    final phoneValues = <String>[];
    for (final line in card) {
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      final property = line
          .substring(0, separator)
          .split(';')
          .first
          .split('.')
          .last
          .toUpperCase();
      final value = line.substring(separator + 1);
      if (property == 'FN' && formattedName == null) {
        formattedName = _unescapeVCard(value).trim();
      } else if (property == 'N' && structuredName.isEmpty) {
        final parts = _splitEscapedVCard(value).map(_unescapeVCard).toList();
        final family = parts.isNotEmpty ? parts[0] : '';
        final given = parts.length > 1 ? parts[1] : '';
        final middle = parts.length > 2 ? parts[2] : '';
        final prefix = parts.length > 3 ? parts[3] : '';
        final suffix = parts.length > 4 ? parts[4] : '';
        structuredName = [prefix, given, middle, family, suffix]
            .where((part) => part.trim().isNotEmpty)
            .join(' ')
            .trim();
      } else if (property == 'TEL') {
        phoneValues.add(
            value.replaceFirst(RegExp(r'^tel:', caseSensitive: false), ''));
      }
    }
    final name = formattedName?.isNotEmpty == true
        ? formattedName!.trim()
        : structuredName.trim();
    for (final rawPhone in phoneValues) {
      final phone = normalizeCameroonPhone(rawPhone);
      if (phone.isEmpty || !seenPhones.add(phone)) continue;
      contacts.add(ContactDraft(name.isEmpty ? 'Contact' : name, phone));
    }
  }
  return contacts;
}

List<String> _splitEscapedVCard(String value) {
  final parts = <String>[];
  final buffer = StringBuffer();
  var escaped = false;
  for (final character in value.split('')) {
    if (escaped) {
      buffer.write('\\$character');
      escaped = false;
    } else if (character == r'\') {
      escaped = true;
    } else if (character == ';') {
      parts.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(character);
    }
  }
  if (escaped) buffer.write(r'\');
  parts.add(buffer.toString());
  return parts;
}

String _unescapeVCard(String value) => value
    .replaceAll(r'\n', ' ')
    .replaceAll(r'\N', ' ')
    .replaceAll(r'\,', ',')
    .replaceAll(r'\;', ';')
    .replaceAll(r'\\', r'\')
    .trim();

class PhoneDirectoryDialog extends StatefulWidget {
  const PhoneDirectoryDialog({super.key});

  @override
  State<PhoneDirectoryDialog> createState() => _PhoneDirectoryDialogState();
}

class _PhoneDirectoryDialogState extends State<PhoneDirectoryDialog> {
  final search = TextEditingController();
  List<ContactDraft> contacts = [];
  final Set<String> selectedPhones = {};
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    try {
      final permission = await Permission.contacts.request();
      if (!permission.isGranted) {
        throw StateError('Autorisation de lecture du répertoire refusée.');
      }
      final entries = <ContactDraft>[];
      final seenPhones = <String>{};
      final phoneContacts = await SmsBridge.getPhoneContacts();
      for (final contact in phoneContacts) {
        final phone = normalizeCameroonPhone(contact.phone);
        if (phone.isEmpty || !seenPhones.add(phone)) continue;
        final name = contact.name.trim();
        entries.add(ContactDraft(name.isEmpty ? 'Contact' : name, phone));
      }
      entries
          .sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (!mounted) return;
      setState(() {
        contacts = entries;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString();
        loading = false;
      });
    }
  }

  List<ContactDraft> get visibleContacts {
    final query = normalizeContactSearch(search.text.trim());
    if (query.isEmpty) return contacts;
    return contacts
        .where((contact) =>
            normalizeContactSearch(contact.name).contains(query) ||
            contact.phone.contains(query))
        .toList();
  }

  void _toggleAllVisible() {
    final visible = visibleContacts;
    final allSelected = visible.isNotEmpty &&
        visible.every((contact) => selectedPhones.contains(contact.phone));
    setState(() {
      if (allSelected) {
        selectedPhones.removeAll(visible.map((contact) => contact.phone));
      } else {
        selectedPhones.addAll(visible.map((contact) => contact.phone));
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Importer du répertoire'),
        content: SizedBox(
          width: 520,
          height: 520,
          child: Column(children: [
            TextField(
              controller: search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Rechercher par nom ou numéro',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            if (!loading && error == null)
              Row(children: [
                Text('${visibleContacts.length} numéro(s) camerounais'),
                const Spacer(),
                TextButton(
                  onPressed: visibleContacts.isEmpty ? null : _toggleAllVisible,
                  child: const Text('Tout sélectionner'),
                ),
              ]),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : error != null
                      ? Center(
                          child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(error!, textAlign: TextAlign.center),
                            TextButton(
                              onPressed: () => openAppSettings(),
                              child: const Text('Ouvrir les réglages'),
                            ),
                          ],
                        ))
                      : contacts.isEmpty
                          ? const Center(
                              child: Text(
                                  'Aucun numéro camerounais trouvé dans le répertoire.'))
                          : ListView.builder(
                              itemCount: visibleContacts.length,
                              itemBuilder: (context, index) {
                                final contact = visibleContacts[index];
                                return CheckboxListTile(
                                  value: selectedPhones.contains(contact.phone),
                                  title: Text(contact.name),
                                  subtitle: Text(contact.phone),
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  onChanged: (selected) => setState(() {
                                    if (selected == true) {
                                      selectedPhones.add(contact.phone);
                                    } else {
                                      selectedPhones.remove(contact.phone);
                                    }
                                  }),
                                );
                              },
                            ),
            ),
            if (!loading && error == null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text('${selectedPhones.length} sélectionné(s)'),
              ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          FilledButton(
            onPressed: selectedPhones.isEmpty || loading || error != null
                ? null
                : () => Navigator.pop(
                      context,
                      contacts
                          .where((contact) =>
                              selectedPhones.contains(contact.phone))
                          .toList(),
                    ),
            child: const Text('Importer la sélection'),
          ),
        ],
      );
}
