import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'src/database.dart';
import 'src/contact_import.dart';
import 'src/gateway.dart';
import 'src/models.dart';
import 'src/sms_bridge.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppDatabase.instance.init();
  runApp(const CamSmsApp());
}

class CamSmsApp extends StatefulWidget {
  const CamSmsApp({super.key});
  @override
  State<CamSmsApp> createState() => _CamSmsAppState();
}

class _CamSmsAppState extends State<CamSmsApp> {
  ThemeMode mode = ThemeMode.system;
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'CamSMS Campaigns',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: ThemeData(
            colorScheme:
                ColorScheme.fromSeed(seedColor: const Color(0xff1769aa)),
            useMaterial3: true),
        darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xff90caf9),
                brightness: Brightness.dark),
            useMaterial3: true),
        home: HomePage(onThemeChanged: (v) => setState(() => mode = v)),
      );
}

class HomePage extends StatefulWidget {
  final ValueChanged<ThemeMode> onThemeChanged;
  const HomePage({super.key, required this.onThemeChanged});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int tab = 0;
  List<Contact> contacts = [];
  List<ContactGroup> groups = [];
  List<SmsCampaign> campaigns = [];
  List<SmsTemplate> templates = [];
  List<SimCard> sims = [];
  bool loading = true;
  final TextEditingController contactSearch = TextEditingController();
  final Set<int> selectedContactIds = {};
  bool selectingContacts = false;
  final CampaignEngine engine = CampaignEngine();
  final SmsGatewayService gateway = SmsGatewayService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refreshAll();
    engine.addListener(_refreshCampaigns);
    unawaited(gateway.initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    engine.removeListener(_refreshCampaigns);
    engine.dispose();
    gateway.dispose();
    contactSearch.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refreshAll();
  }

  void _refreshCampaigns() async {
    campaigns = await AppDatabase.instance.getCampaigns();
    if (mounted) setState(() {});
  }

  Future<void> refreshAll() async {
    final db = AppDatabase.instance;
    final c = await db.getContacts();
    final g = await db.getGroups();
    final p = await db.getCampaigns();
    final t = await db.getTemplates();
    List<SimCard> s = [];
    try {
      s = await SmsBridge.getSims();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      contacts = c;
      groups = g;
      campaigns = p;
      templates = t;
      sims = s;
      loading = false;
      selectedContactIds
          .removeWhere((id) => !c.any((contact) => contact.id == id));
    });
  }

  Future<void> addContact() async {
    final result = await showDialog<ContactDraft>(
        context: context, builder: (_) => const ContactDialog());
    if (result == null) return;
    final added =
        await AppDatabase.instance.addContact(result.name, result.phone);
    if (!added) _snack('Ce numéro existe déjà dans vos contacts.');
    await refreshAll();
  }

  Future<void> importContacts() async {
    final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'txt', 'xlsx', 'vcf'],
        withData: true);
    if (picked == null) return;
    final file = picked.files.single;
    try {
      final ext = (file.extension ?? '').toLowerCase();
      final bytes = file.bytes ?? await File(file.path!).readAsBytes();
      int count = 0;
      int skipped = 0;
      if (ext == 'vcf') {
        final content = utf8.decode(bytes, allowMalformed: true);
        for (final contact in parseVCardContacts(content)) {
          if (await AppDatabase.instance
              .addContact(contact.name, contact.phone)) {
            count++;
          } else {
            skipped++;
          }
        }
      } else {
        List<List<dynamic>> rows;
        if (ext == 'xlsx') {
          final excel = Excel.decodeBytes(bytes);
          final sheet = excel.tables.values.first;
          rows = sheet.rows
              .map((r) => r.map((c) => c?.value ?? '').toList())
              .toList();
        } else {
          final content = utf8.decode(bytes, allowMalformed: true);
          rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
              .convert(content);
        }
        for (final row in rows) {
          if (row.isEmpty) continue;
          final cells = row.map((e) => e.toString().trim()).toList();
          final joined = cells.join(' ').toLowerCase();
          if (joined.contains('phone') ||
              joined.contains('téléphone') ||
              joined.contains('numero') ||
              joined.contains('numéro')) {
            continue;
          }
          final phoneCell = cells.firstWhere(
              (e) => RegExp(r'(\+?237)?[0-9\s().-]{9,}').hasMatch(e),
              orElse: () => '');
          if (phoneCell.isEmpty) continue;
          final phone = normalizeCameroonPhoneOrNull(phoneCell);
          if (phone == null) continue;
          final name = cells.firstWhere((e) => e.isNotEmpty && e != phoneCell,
              orElse: () => 'Contact');
          if (await AppDatabase.instance.addContact(name, phone)) {
            count++;
          } else {
            skipped++;
          }
        }
      }
      await refreshAll();
      if (mounted) {
        _snack('$count contact(s) importé(s), $skipped doublon(s) ignoré(s).');
      }
    } catch (e) {
      if (mounted) _snack('Import impossible : $e');
    }
  }

  Future<void> importPhoneContacts() async {
    final selected = await showDialog<List<ContactDraft>>(
      context: context,
      builder: (_) => const PhoneDirectoryDialog(),
    );
    if (selected == null || selected.isEmpty) return;
    var imported = 0;
    var skipped = 0;
    for (final contact in selected) {
      if (await AppDatabase.instance.addContact(contact.name, contact.phone)) {
        imported++;
      } else {
        skipped++;
      }
    }
    await refreshAll();
    if (mounted) {
      _snack('$imported contact(s) importé(s), $skipped doublon(s) ignoré(s).');
    }
  }

  Future<void> createGroup() async {
    final draft = await showDialog<GroupDraft>(
      context: context,
      builder: (_) => const CreateGroupDialog(),
    );
    if (draft == null || draft.name.trim().isEmpty) return;
    final parsed = parsePastedCameroonNumbers(draft.numbers);
    if (draft.numbers.trim().isNotEmpty && parsed.isEmpty) {
      _snack('Aucun numéro camerounais valide dans la liste.');
      return;
    }
    final groupId = await AppDatabase.instance.createGroupWithNumbers(
      draft.name.trim(),
      parsed.map((entry) => entry.phone).toList(),
    );
    if (groupId == null) {
      _snack('Un groupe porte déjà ce nom.');
      return;
    }
    await refreshAll();
    if (mounted && parsed.isNotEmpty) {
      _snack('${parsed.length} numéro(s) ajouté(s) au groupe.');
    }
  }

  Future<void> createCampaign() async {
    if (groups.isEmpty) {
      _snack('Crée d’abord un groupe et ajoute des contacts.');
      return;
    }
    final draft = await showDialog<CampaignDraft>(
      context: context,
      builder: (_) =>
          CampaignDialog(groups: groups, sims: sims, templates: templates),
    );
    if (draft == null) return;
    await AppDatabase.instance.createCampaign(draft);
    await refreshAll();
    setState(() => tab = 2);
  }

  Future<void> _chooseCampaignType() async {
    final type = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Créer une campagne'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'group'),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.folder_outlined),
              title: Text('Depuis un groupe'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'direct'),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.phone_android),
              title: Text('Depuis des numéros collés'),
            ),
          ),
        ],
      ),
    );
    if (type == 'group') {
      await createCampaign();
    } else if (type == 'direct') {
      await createDirectCampaign();
    }
  }

  Future<void> createDirectCampaign() async {
    final draft = await showDialog<CampaignDraft>(
      context: context,
      builder: (_) => DirectCampaignDialog(sims: sims, templates: templates),
    );
    if (draft == null) return;
    final campaignId = await AppDatabase.instance.createCampaign(draft);
    await refreshAll();
    if (!mounted) return;
    setState(() => tab = 3);
    await engine.start(campaignId);
    await refreshAll();
  }

  Future<void> _generateNumbers() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const ContactNumberGeneratorDialog(),
    );
  }

  Future<void> createGroupFromNumbers(String numbers) async {
    final draft = await showDialog<GroupDraft>(
      context: context,
      builder: (_) => CreateGroupDialog(initialNumbers: numbers),
    );
    if (draft == null || draft.name.trim().isEmpty) return;
    final parsed = parsePastedCameroonNumbers(draft.numbers);
    if (parsed.isEmpty) {
      _snack('Aucun numéro camerounais valide dans la liste.');
      return;
    }
    final groupId = await AppDatabase.instance.createGroupWithNumbers(
      draft.name.trim(),
      parsed.map((entry) => entry.phone).toList(),
    );
    if (groupId == null) {
      _snack('Un groupe porte déjà ce nom.');
      return;
    }
    await refreshAll();
    if (mounted) {
      _snack(
          '${parsed.length} numéro(s) ajouté(s) au groupe « ${draft.name.trim()} ».');
    }
  }

  Future<void> editContact(Contact c) async {
    final result = await showDialog<ContactDraft>(
        context: context, builder: (_) => ContactDialog(contact: c));
    if (result == null) return;
    await AppDatabase.instance.updateContact(c.id!, result.name, result.phone);
    await refreshAll();
  }

  List<Contact> get filteredContacts {
    final query = normalizeContactSearch(contactSearch.text.trim());
    if (query.isEmpty) return contacts;
    return contacts
        .where((contact) =>
            normalizeContactSearch(contact.name).contains(query) ||
            contact.phone.toLowerCase().contains(query))
        .toList();
  }

  void _toggleContactSelection(Contact contact) {
    final id = contact.id;
    if (id == null) return;
    setState(() {
      selectingContacts = true;
      if (!selectedContactIds.add(id)) selectedContactIds.remove(id);
      if (selectedContactIds.isEmpty) selectingContacts = false;
    });
  }

  void _selectVisibleContacts() {
    final visibleIds =
        filteredContacts.map((contact) => contact.id).whereType<int>().toSet();
    final allSelected =
        visibleIds.isNotEmpty && visibleIds.every(selectedContactIds.contains);
    setState(() {
      if (allSelected) {
        selectedContactIds.removeAll(visibleIds);
      } else {
        selectedContactIds.addAll(visibleIds);
        selectingContacts = true;
      }
      if (selectedContactIds.isEmpty) selectingContacts = false;
    });
  }

  Future<void> _changeSelectedGroup({required bool add}) async {
    if (selectedContactIds.isEmpty) return;
    if (groups.isEmpty) {
      _snack('Créez d’abord un groupe avant cette action.');
      return;
    }
    final group = await showDialog<ContactGroup>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(add ? 'Ajouter à un groupe' : 'Retirer d’un groupe'),
        children: groups
            .map((group) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, group),
                  child: Text('${group.name} (${group.count})'),
                ))
            .toList(),
      ),
    );
    if (group == null) return;
    final ids = selectedContactIds.toList();
    if (add) {
      await AppDatabase.instance.addContactsToGroup(group.id, ids);
    } else {
      await AppDatabase.instance.removeContactsFromGroup(group.id, ids);
    }
    if (!mounted) return;
    setState(() {
      selectedContactIds.clear();
      selectingContacts = false;
    });
    await refreshAll();
    if (mounted) {
      _snack(
          '${ids.length} contact(s) ${add ? 'ajouté(s) au' : 'retiré(s) du'} groupe « ${group.name} ».');
    }
  }

  Future<void> _textDialogAction(
      String title, String hint, Future<void> Function(String) action) async {
    final value = await _textDialog(title, hint);
    if (value != null && value.trim().isNotEmpty) {
      await action(value.trim());
      await refreshAll();
    }
  }

  Future<String?> _textDialog(String title, String hint) async {
    final controller = TextEditingController();
    return showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(title),
              content: TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(labelText: hint)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Annuler')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, controller.text),
                    child: const Text('Enregistrer'))
              ],
            ));
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final pages = [
      _dashboard(),
      _contactsPage(),
      _groupsPage(),
      _campaignsPage(),
      _templatesPage(),
      _settingsPage(),
      GatewayPage(service: gateway),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('CamSMS Campaigns'), actions: [
        IconButton(
            tooltip: 'Actualiser',
            onPressed: refreshAll,
            icon: const Icon(Icons.refresh)),
      ]),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(index: tab, children: pages),
      floatingActionButton: switch (tab) {
        1 => FloatingActionButton(
            onPressed: addContact, child: const Icon(Icons.person_add)),
        2 => FloatingActionButton(
            onPressed: createGroup, child: const Icon(Icons.create_new_folder)),
        3 => FloatingActionButton.extended(
            onPressed: _chooseCampaignType,
            icon: const Icon(Icons.add),
            label: const Text('Campagne')),
        4 => FloatingActionButton(
            onPressed: () => _textDialogAction(
                    'Nouveau modèle', 'Nom du modèle', (name) async {
                  final body = await _textDialog('Contenu du modèle',
                      'Message avec {first_name} et {last_name}');
                  if (body != null) {
                    await AppDatabase.instance.addTemplate(name, body);
                  }
                }),
            child: const Icon(Icons.add)),
        _ => null,
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() => tab = v),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Accueil'),
          NavigationDestination(
              icon: Icon(Icons.people_outline),
              selectedIcon: Icon(Icons.people),
              label: 'Contacts'),
          NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder),
              label: 'Groupes'),
          NavigationDestination(
              icon: Icon(Icons.campaign_outlined),
              selectedIcon: Icon(Icons.campaign),
              label: 'Campagnes'),
          NavigationDestination(
              icon: Icon(Icons.text_snippet_outlined),
              selectedIcon: Icon(Icons.text_snippet),
              label: 'Modèles'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Réglages'),
          NavigationDestination(
              icon: Icon(Icons.router_outlined),
              selectedIcon: Icon(Icons.router),
              label: 'Passerelle'),
        ],
      ),
    );
  }

  Widget _dashboard() {
    final total = campaigns.fold<int>(0, (a, c) => a + c.total);
    final sent = campaigns.fold<int>(0, (a, c) => a + c.sent);
    final failed = campaigns.fold<int>(0, (a, c) => a + c.failed);
    return RefreshIndicator(
        onRefresh: refreshAll,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('Vue d’ensemble',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              childAspectRatio: 1.55,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              children: [
                _stat('Contacts', '${contacts.length}', Icons.people),
                _stat('Groupes', '${groups.length}', Icons.folder),
                _stat('SMS envoyés', '$sent', Icons.send),
                _stat('Échecs', '$failed', Icons.error_outline),
              ]),
          const SizedBox(height: 12),
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Cartes SIM détectées',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        if (sims.isEmpty)
                          const Text(
                              'Aucune SIM détectée ou permission non accordée.'),
                        ...sims.map((s) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: const Icon(Icons.sim_card),
                            title: Text('${s.carrier} — SIM ${s.slot + 1}'))),
                      ]))),
          const SizedBox(height: 12),
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Activité des campagnes',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Text(
                            '$sent SMS envoyés sur $total destinataires • $failed échec(s)'),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                            value: total == 0 ? 0 : sent / total),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                            onPressed: _chooseCampaignType,
                            icon: const Icon(Icons.add),
                            label: const Text('Créer une campagne')),
                      ]))),
          const SizedBox(height: 8),
          const Text(
              'Les campagnes sont conservées localement sur cet appareil. Autorisation SMS requise.',
              style: TextStyle(color: Colors.grey)),
        ]));
  }

  Widget _stat(String label, String value, IconData icon) => Card(
      child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                Text(value, style: Theme.of(context).textTheme.headlineMedium),
                Text(label, style: Theme.of(context).textTheme.bodySmall),
              ])));

  Widget _contactsPage() {
    final visibleContacts = filteredContacts;
    final visibleIds =
        visibleContacts.map((contact) => contact.id).whereType<int>().toSet();
    final allVisibleSelected =
        visibleIds.isNotEmpty && visibleIds.every(selectedContactIds.contains);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          Expanded(
              child: Text(
            selectingContacts
                ? '${selectedContactIds.length} sélectionné(s)'
                : '${contacts.length} contact(s)',
            style: Theme.of(context).textTheme.titleMedium,
          )),
          IconButton(
            tooltip: selectingContacts
                ? 'Annuler la sélection'
                : 'Sélection multiple',
            onPressed: () => setState(() {
              selectingContacts = !selectingContacts;
              if (!selectingContacts) selectedContactIds.clear();
            }),
            icon: Icon(selectingContacts ? Icons.close : Icons.checklist),
          ),
          IconButton(
            tooltip: 'Générer des numéros fictifs réservés aux tests',
            onPressed: _generateNumbers,
            icon: const Icon(Icons.casino_outlined),
          ),
          IconButton(
            tooltip: 'Importer un fichier CSV ou VCF',
            onPressed: importContacts,
            icon: const Icon(Icons.file_upload),
          ),
          FilledButton.tonalIcon(
            onPressed: importPhoneContacts,
            icon: const Icon(Icons.contacts),
            label: const Text('Répertoire'),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: TextField(
          controller: contactSearch,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'Filtrer par nom ou numéro',
            suffixIcon: contactSearch.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Effacer la recherche',
                    onPressed: () {
                      contactSearch.clear();
                      setState(() {});
                    },
                    icon: const Icon(Icons.clear),
                  ),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
      if (selectingContacts)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 4,
            alignment: WrapAlignment.center,
            children: [
              TextButton.icon(
                onPressed:
                    visibleContacts.isEmpty ? null : _selectVisibleContacts,
                icon: Icon(
                    allVisibleSelected ? Icons.deselect : Icons.select_all),
                label: Text(allVisibleSelected
                    ? 'Désélectionner les résultats'
                    : 'Sélectionner les résultats'),
              ),
              TextButton.icon(
                onPressed: selectedContactIds.isEmpty
                    ? null
                    : () => _changeSelectedGroup(add: true),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Ajouter au groupe'),
              ),
              TextButton.icon(
                onPressed: selectedContactIds.isEmpty
                    ? null
                    : () => _changeSelectedGroup(add: false),
                icon: const Icon(Icons.folder_off_outlined),
                label: const Text('Retirer du groupe'),
              ),
            ],
          ),
        ),
      Expanded(
        child: contacts.isEmpty
            ? const Center(
                child: Text(
                    'Aucun contact local. Importe des contacts du répertoire ou un fichier CSV/VCF.'))
            : visibleContacts.isEmpty
                ? const Center(
                    child:
                        Text('Aucun contact ne correspond à cette recherche.'))
                : ListView.builder(
                    itemCount: visibleContacts.length,
                    itemBuilder: (_, i) {
                      final contact = visibleContacts[i];
                      final selected = contact.id != null &&
                          selectedContactIds.contains(contact.id);
                      if (selectingContacts) {
                        return CheckboxListTile(
                          value: selected,
                          controlAffinity: ListTileControlAffinity.leading,
                          secondary: CircleAvatar(
                            child: Text(contact.name.isEmpty
                                ? '?'
                                : contact.name[0].toUpperCase()),
                          ),
                          title: Text(contact.name),
                          subtitle: Text(
                              '${contact.phone} • ${operatorFor(contact.phone)}'),
                          onChanged: (_) => _toggleContactSelection(contact),
                        );
                      }
                      return ListTile(
                        leading: CircleAvatar(
                          child: Text(contact.name.isEmpty
                              ? '?'
                              : contact.name[0].toUpperCase()),
                        ),
                        title: Text(contact.name),
                        subtitle: Text(
                            '${contact.phone} • ${operatorFor(contact.phone)}'),
                        onTap: () => editContact(contact),
                        onLongPress: () => _toggleContactSelection(contact),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) async {
                            if (value == 'edit') await editContact(contact);
                            if (value == 'delete') {
                              await AppDatabase.instance
                                  .deleteContact(contact.id!);
                              await refreshAll();
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                                value: 'edit', child: Text('Modifier')),
                            PopupMenuItem(
                                value: 'delete', child: Text('Supprimer')),
                          ],
                        ),
                      );
                    },
                  ),
      ),
    ]);
  }

  Widget _groupsPage() =>
      ListView(padding: const EdgeInsets.all(12), children: [
        if (groups.isEmpty)
          const Padding(
              padding: EdgeInsets.all(30),
              child: Center(child: Text('Aucun groupe créé.'))),
        ...groups.map((g) => Card(
            child: ListTile(
                leading: const Icon(Icons.folder),
                title: Text(g.name),
                subtitle: Text('${g.count} contact(s)'),
                onTap: () async {
                  final members =
                      await AppDatabase.instance.getGroupContacts(g.id);
                  if (!mounted) return;
                  await showDialog<void>(
                      context: context,
                      builder: (_) => GroupMembersDialog(
                          group: g,
                          contacts: contacts,
                          members: members,
                          onChanged: refreshAll));
                },
                trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'rename') {
                        await _textDialogAction(
                            'Renommer le groupe',
                            'Nom du groupe',
                            (name) =>
                                AppDatabase.instance.renameGroup(g.id, name));
                      }
                      if (v == 'delete') {
                        await AppDatabase.instance.deleteGroup(g.id);
                      }
                      await refreshAll();
                    },
                    itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'rename', child: Text('Renommer')),
                          PopupMenuItem(
                              value: 'delete', child: Text('Supprimer'))
                        ])))),
      ]);

  Widget _campaignsPage() =>
      ListView(padding: const EdgeInsets.all(12), children: [
        if (campaigns.isEmpty)
          const Padding(
              padding: EdgeInsets.all(30),
              child: Center(
                  child:
                      Text('Aucune campagne. Appuie sur + pour commencer.'))),
        ...campaigns.map((c) =>
            CampaignCard(campaign: c, engine: engine, onChanged: refreshAll)),
      ]);

  Widget _templatesPage() =>
      ListView(padding: const EdgeInsets.all(12), children: [
        const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
                'Variables disponibles : {first_name}, {last_name}, {phone}. La signature est ajoutée à la fin du message.')),
        if (templates.isEmpty)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Aucun modèle enregistré.'))),
        ...templates.map((t) => Card(
            child: ListTile(
                title: Text(t.name),
                subtitle:
                    Text(t.body, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'delete') {
                        await AppDatabase.instance.deleteTemplate(t.id);
                      }
                      if (v == 'edit') {
                        final body = await _textDialog(
                            'Modifier le modèle', 'Contenu du SMS');
                        if (body != null) {
                          await AppDatabase.instance
                              .updateTemplate(t.id, t.name, body);
                        }
                      }
                      await refreshAll();
                    },
                    itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Modifier')),
                          PopupMenuItem(
                              value: 'delete', child: Text('Supprimer'))
                        ])))),
      ]);

  Widget _settingsPage() => SettingsPage(
      sims: sims, onThemeChanged: widget.onThemeChanged, onChanged: refreshAll);
}

class GroupDraft {
  final String name;
  final String numbers;
  const GroupDraft(this.name, this.numbers);
}

class CreateGroupDialog extends StatefulWidget {
  final String initialNumbers;
  const CreateGroupDialog({super.key, this.initialNumbers = ''});

  @override
  State<CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<CreateGroupDialog> {
  final name = TextEditingController();
  late final numbers = TextEditingController(text: widget.initialNumbers);

  @override
  void dispose() {
    name.dispose();
    numbers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final parsed = parsePastedCameroonNumbers(numbers.text);
    return AlertDialog(
      title: const Text('Créer un groupe'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Nom du groupe'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: numbers,
              minLines: 4,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                labelText: 'Numéros à ajouter (facultatif)',
                hintText: '+237 670 123 456, 699 111 222\n680 123 456',
                helperText:
                    'Séparez les numéros par une virgule, un point-virgule ou un retour à la ligne.',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('${parsed.length} numéro(s) camerounais valide(s)'),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler')),
        FilledButton(
          onPressed: name.text.trim().isEmpty ||
                  (numbers.text.trim().isNotEmpty && parsed.isEmpty)
              ? null
              : () => Navigator.pop(
                  context, GroupDraft(name.text.trim(), numbers.text)),
          child: const Text('Créer le groupe'),
        ),
      ],
    );
  }
}

class ContactNumberGeneratorDialog extends StatefulWidget {
  const ContactNumberGeneratorDialog({super.key});

  @override
  State<ContactNumberGeneratorDialog> createState() =>
      _ContactNumberGeneratorDialogState();
}

class _ContactNumberGeneratorDialogState
    extends State<ContactNumberGeneratorDialog> {
  final quantity = TextEditingController(text: '10');
  List<String> generated = [];

  @override
  void dispose() {
    quantity.dispose();
    super.dispose();
  }

  void _generate() {
    final count = int.tryParse(quantity.text.trim());
    if (count == null || count < 1 || count > 1000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Entrez une quantité comprise entre 1 et 1000.')),
      );
      return;
    }
    setState(() {
      generated = generateSyntheticTestPhones(count, Random.secure());
    });
  }

  String get csvNumbers => generated.join(', ');

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: csvNumbers));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              '${generated.length} numéro(s) copiés, séparés par des virgules.')),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Générer des numéros de test'),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
                'Ces valeurs aléatoires utilisent le bloc invalide 000 xxx xxx. Elles sont fictives, ne correspondent à aucun opérateur et ne peuvent pas être importées ni utilisées pour envoyer un SMS.'),
            TextField(
              controller: quantity,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Nombre de numéros (1 à 1000)'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _generate,
              icon: const Icon(Icons.casino),
              label: const Text('Générer'),
            ),
            if (generated.isNotEmpty) ...[
              Text(
                  '${generated.length} numéro(s) fictif(s) • séparés par des virgules'),
              const SizedBox(height: 6),
              SizedBox(
                height: 140,
                child: SingleChildScrollView(
                  child: SelectableText(csvNumbers),
                ),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fermer')),
          if (generated.isNotEmpty)
            TextButton.icon(
              onPressed: _copy,
              icon: const Icon(Icons.copy),
              label: const Text('Copier'),
            ),
        ],
      );
}

class DirectCampaignDialog extends StatefulWidget {
  final List<SimCard> sims;
  final List<SmsTemplate> templates;
  const DirectCampaignDialog(
      {super.key, required this.sims, required this.templates});

  @override
  State<DirectCampaignDialog> createState() => _DirectCampaignDialogState();
}

class _DirectCampaignDialogState extends State<DirectCampaignDialog> {
  final name = TextEditingController(text: 'Campagne directe');
  final numbers = TextEditingController();
  final message = TextEditingController();
  final signature = TextEditingController();
  int seconds = 5;
  String simMode = 'AUTO';

  @override
  void initState() {
    super.initState();
    AppDatabase.instance.getSetting('default_signature').then((value) {
      if (mounted && signature.text.isEmpty && value != null) {
        signature.text = value;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    name.dispose();
    numbers.dispose();
    message.dispose();
    signature.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recipients = parsePastedCameroonNumbers(numbers.text);
    return AlertDialog(
      title: const Text('Campagne vers des numéros collés'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: name,
              decoration:
                  const InputDecoration(labelText: 'Nom de la campagne'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: numbers,
              minLines: 3,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                labelText: 'Numéros destinataires',
                hintText: '+237 670 123 456, 699 111 222',
                helperText:
                    'Numéros camerounais séparés par des virgules, points-virgules ou retours à la ligne.',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            Align(
                alignment: Alignment.centerLeft,
                child: Text('${recipients.length} numéro(s) valide(s)')),
            if (widget.templates.isNotEmpty)
              DropdownButtonFormField<int?>(
                decoration: const InputDecoration(
                    labelText: 'Charger un modèle (facultatif)'),
                items: [
                  const DropdownMenuItem<int?>(
                      value: null, child: Text('Aucun modèle')),
                  ...widget.templates.map((template) => DropdownMenuItem<int?>(
                      value: template.id, child: Text(template.name))),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  message.text = widget.templates
                      .firstWhere((template) => template.id == value)
                      .body;
                  setState(() {});
                },
              ),
            TextField(
              controller: message,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Message SMS'),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
                controller: signature,
                decoration: const InputDecoration(
                    labelText: 'Signature (facultative)')),
            DropdownButtonFormField<int>(
              value: seconds,
              decoration:
                  const InputDecoration(labelText: 'Intervalle entre SMS'),
              items: [1, 2, 3, 5, 10, 15, 30, 60, 120]
                  .map((value) => DropdownMenuItem(
                      value: value, child: Text('$value seconde(s)')))
                  .toList(),
              onChanged: (value) => setState(() => seconds = value ?? 5),
            ),
            DropdownButtonFormField<String>(
              value: simMode,
              decoration: const InputDecoration(labelText: 'SIM'),
              items: const [
                DropdownMenuItem(
                    value: 'AUTO', child: Text('Automatique selon le numéro')),
                DropdownMenuItem(value: 'MTN', child: Text('Forcer MTN')),
                DropdownMenuItem(value: 'ORANGE', child: Text('Forcer Orange')),
              ],
              onChanged: (value) => setState(() => simMode = value ?? 'AUTO'),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler')),
        FilledButton.icon(
          onPressed: recipients.isEmpty ||
                  message.text.trim().isEmpty ||
                  name.text.trim().isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  CampaignDraft(
                    name.text.trim(),
                    message.text.trim(),
                    signature.text.trim(),
                    0,
                    seconds * 1000,
                    simMode,
                    directRecipients: recipients
                        .map((entry) => ContactDraft('Contact', entry.phone))
                        .toList(),
                  )),
          icon: const Icon(Icons.send),
          label: const Text('Créer et envoyer'),
        ),
      ],
    );
  }
}

class ContactDialog extends StatefulWidget {
  final Contact? contact;
  const ContactDialog({super.key, this.contact});
  @override
  State<ContactDialog> createState() => _ContactDialogState();
}

class _ContactDialogState extends State<ContactDialog> {
  late final name = TextEditingController(text: widget.contact?.name ?? '');
  late final phone = TextEditingController(text: widget.contact?.phone ?? '');
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(
            widget.contact == null ? 'Nouveau contact' : 'Modifier le contact'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Nom')),
          TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Téléphone')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () {
                final normalized = normalizeCameroonPhoneOrNull(phone.text);
                if (normalized == null) return;
                Navigator.pop(
                    context,
                    ContactDraft(
                        name.text.trim().isEmpty ? 'Contact' : name.text.trim(),
                        normalized));
              },
              child: const Text('Enregistrer'))
        ],
      );
}

class GroupMembersDialog extends StatefulWidget {
  final ContactGroup group;
  final List<Contact> contacts, members;
  final Future<void> Function() onChanged;
  const GroupMembersDialog(
      {super.key,
      required this.group,
      required this.contacts,
      required this.members,
      required this.onChanged});
  @override
  State<GroupMembersDialog> createState() => _GroupMembersDialogState();
}

class _GroupMembersDialogState extends State<GroupMembersDialog> {
  late Set<int> selected = widget.members.map((e) => e.id!).toSet();
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('${widget.group.name} — membres'),
        content: SizedBox(
            width: double.maxFinite,
            height: 420,
            child: widget.contacts.isEmpty
                ? const Text(
                    'Ajoute des contacts avant de les affecter à un groupe.')
                : ListView(
                    children: widget.contacts
                        .map((c) => CheckboxListTile(
                              value: selected.contains(c.id),
                              title: Text(c.name),
                              subtitle: Text(c.phone),
                              onChanged: (v) => setState(() {
                                if (v == true) {
                                  selected.add(c.id!);
                                } else {
                                  selected.remove(c.id);
                                }
                              }),
                            ))
                        .toList())),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fermer')),
          FilledButton(
              onPressed: () async {
                await AppDatabase.instance
                    .setGroupMembers(widget.group.id, selected.toList());
                await widget.onChanged();
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Enregistrer'))
        ],
      );
}

class CampaignDialog extends StatefulWidget {
  final List<ContactGroup> groups;
  final List<SimCard> sims;
  final List<SmsTemplate> templates;
  const CampaignDialog(
      {super.key,
      required this.groups,
      required this.sims,
      required this.templates});
  @override
  State<CampaignDialog> createState() => _CampaignDialogState();
}

class _CampaignDialogState extends State<CampaignDialog> {
  final name = TextEditingController();
  final message = TextEditingController();
  final signature = TextEditingController();
  int? groupId;
  int seconds = 5;
  String simMode = 'AUTO';
  @override
  void initState() {
    super.initState();
    groupId = widget.groups.first.id;
    AppDatabase.instance.getSetting('default_signature').then((v) {
      if (mounted && signature.text.isEmpty && v != null) {
        signature.text = v;
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Créer une campagne SMS'),
        content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  decoration:
                      const InputDecoration(labelText: 'Nom de la campagne')),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                  value: groupId,
                  decoration:
                      const InputDecoration(labelText: 'Groupe destinataire'),
                  items: widget.groups
                      .map((g) => DropdownMenuItem(
                          value: g.id, child: Text('${g.name} (${g.count})')))
                      .toList(),
                  onChanged: (v) => setState(() => groupId = v)),
              if (widget.templates.isNotEmpty)
                DropdownButtonFormField<int?>(
                    decoration: const InputDecoration(
                        labelText: 'Charger un modèle (facultatif)'),
                    items: [
                      const DropdownMenuItem<int?>(
                          value: null, child: Text('Aucun modèle')),
                      ...widget.templates.map((t) => DropdownMenuItem<int?>(
                          value: t.id, child: Text(t.name)))
                    ],
                    onChanged: (v) async {
                      if (v != null) {
                        final t = widget.templates.firstWhere((x) => x.id == v);
                        message.text = t.body;
                        setState(() {});
                      }
                    }),
              TextField(
                  controller: message,
                  minLines: 3,
                  maxLines: 5,
                  decoration: const InputDecoration(
                      labelText: 'Message',
                      hintText: 'Bonjour {first_name}, ...')),
              TextField(
                  controller: signature,
                  decoration: const InputDecoration(
                      labelText: 'Signature (facultative)')),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                  value: seconds,
                  decoration:
                      const InputDecoration(labelText: 'Intervalle entre SMS'),
                  items: [1, 2, 3, 5, 10, 15, 30, 60, 120]
                      .map((v) => DropdownMenuItem(
                          value: v, child: Text('$v seconde(s)')))
                      .toList(),
                  onChanged: (v) => setState(() => seconds = v ?? 5)),
              DropdownButtonFormField<String>(
                  value: simMode,
                  decoration: const InputDecoration(labelText: 'SIM'),
                  items: const [
                    DropdownMenuItem(
                        value: 'AUTO',
                        child: Text('Automatique selon le numéro')),
                    DropdownMenuItem(value: 'MTN', child: Text('Forcer MTN')),
                    DropdownMenuItem(
                        value: 'ORANGE', child: Text('Forcer Orange')),
                  ],
                  onChanged: (v) => setState(() => simMode = v ?? 'AUTO')),
              const SizedBox(height: 6),
              const Text(
                  'Les variables de personnalisation sont remplacées pour chaque contact.',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty ||
                    message.text.trim().isEmpty ||
                    groupId == null) {
                  return;
                }
                Navigator.pop(
                    context,
                    CampaignDraft(
                        name.text.trim(),
                        message.text.trim(),
                        signature.text.trim(),
                        groupId!,
                        seconds * 1000,
                        simMode));
              },
              child: const Text('Créer'))
        ],
      );
}

class CampaignCard extends StatelessWidget {
  final SmsCampaign campaign;
  final CampaignEngine engine;
  final Future<void> Function() onChanged;
  const CampaignCard(
      {super.key,
      required this.campaign,
      required this.engine,
      required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final pct = campaign.total == 0
        ? 0.0
        : (campaign.sent + campaign.failed) / campaign.total;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(14),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Text(campaign.name,
                        style: Theme.of(context).textTheme.titleMedium)),
                _status(campaign.status)
              ]),
              const SizedBox(height: 4),
              Text('${campaign.groupName} • ${campaign.total} destinataire(s)',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: pct),
              const SizedBox(height: 8),
              Wrap(spacing: 12, children: [
                Text('Envoyés : ${campaign.sent}'),
                Text('Échecs : ${campaign.failed}'),
                Text('En attente : ${campaign.pending}'),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                if (campaign.status == 'draft' ||
                    campaign.status == 'paused' ||
                    campaign.status == 'failed')
                  FilledButton.tonalIcon(
                      onPressed: () async {
                        await engine.start(campaign.id);
                        await onChanged();
                      },
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Lancer / Reprendre')),
                if (campaign.status == 'running')
                  OutlinedButton.icon(
                      onPressed: () async {
                        await engine.pause(campaign.id);
                        await onChanged();
                      },
                      icon: const Icon(Icons.pause),
                      label: const Text('Pause')),
                if (campaign.status == 'running' || campaign.status == 'paused')
                  OutlinedButton.icon(
                      onPressed: () async {
                        await engine.stop(campaign.id);
                        await onChanged();
                      },
                      icon: const Icon(Icons.stop),
                      label: const Text('Arrêter')),
                if (campaign.failed > 0 && campaign.status != 'running')
                  OutlinedButton.icon(
                      onPressed: () async {
                        await AppDatabase.instance
                            .resetFailedRecipients(campaign.id);
                        await engine.start(campaign.id);
                        await onChanged();
                      },
                      icon: const Icon(Icons.replay),
                      label: const Text('Réessayer les échecs')),
                OutlinedButton.icon(
                    onPressed: () async {
                      final details = await AppDatabase.instance
                          .getCampaignRecipients(campaign.id);
                      if (context.mounted) {
                        await showDialog<void>(
                            context: context,
                            builder: (_) => CampaignReportDialog(
                                campaign: campaign, rows: details));
                      }
                    },
                    icon: const Icon(Icons.receipt_long),
                    label: const Text('Rapport')),
              ]),
              const SizedBox(height: 4),
              Text(
                  'Intervalle : ${(campaign.intervalMs / 1000).toStringAsFixed(0)} s • SIM : ${campaign.simMode}',
                  style: Theme.of(context).textTheme.bodySmall),
            ])));
  }

  Widget _status(String s) {
    final label = {
          'draft': 'Brouillon',
          'running': 'En cours',
          'paused': 'En pause',
          'completed': 'Terminée',
          'stopped': 'Arrêtée',
          'failed': 'Erreur'
        }[s] ??
        s;
    return Chip(label: Text(label), visualDensity: VisualDensity.compact);
  }
}

class CampaignReportDialog extends StatelessWidget {
  final SmsCampaign campaign;
  final List<Map<String, Object?>> rows;
  const CampaignReportDialog(
      {super.key, required this.campaign, required this.rows});
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Rapport — ${campaign.name}'),
        content: SizedBox(
            width: 420,
            height: 420,
            child: ListView(
                children: rows
                    .map((r) => ListTile(
                          dense: true,
                          title: Text('${r['name']} • ${r['phone']}'),
                          subtitle: Text('${r['status']} ${r['detail'] ?? ''}'),
                          trailing: Icon(
                              r['status'] == 'sent'
                                  ? Icons.check_circle
                                  : r['status'] == 'failed'
                                      ? Icons.error
                                      : Icons.schedule,
                              size: 18),
                        ))
                    .toList())),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fermer')),
          FilledButton.tonalIcon(
              onPressed: () async {
                final rowsOut = <List<dynamic>>[
                  ['Nom', 'Téléphone', 'Statut', 'Détail'],
                  ...rows.map((r) =>
                      [r['name'], r['phone'], r['status'], r['detail'] ?? '']),
                ];
                final csvText = const ListToCsvConverter().convert(rowsOut);
                final bytes = Uint8List.fromList(
                    [0xEF, 0xBB, 0xBF, ...utf8.encode(csvText)]);
                final path = await FilePicker.platform.saveFile(
                  fileName: 'rapport_campagne_${campaign.id}.csv',
                  bytes: bytes,
                );
                if (context.mounted && path != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Rapport exporté.')));
                }
              },
              icon: const Icon(Icons.download),
              label: const Text('Exporter CSV')),
        ],
      );
}

class SettingsPage extends StatefulWidget {
  final List<SimCard> sims;
  final ValueChanged<ThemeMode> onThemeChanged;
  final Future<void> Function() onChanged;
  const SettingsPage(
      {super.key,
      required this.sims,
      required this.onThemeChanged,
      required this.onChanged});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final signature = TextEditingController();
  bool dark = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    signature.text =
        await AppDatabase.instance.getSetting('default_signature') ?? '';
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(16), children: [
        Text('Réglages', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Cartes SIM Android',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      if (widget.sims.isEmpty)
                        const Text(
                            'Aucune SIM lisible. Vérifie les permissions et les cartes installées.'),
                      ...widget.sims.map((s) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.sim_card),
                          title: Text(s.carrier),
                          subtitle: Text(
                              'Emplacement SIM ${s.slot + 1} • ID abonnement ${s.subscriptionId}'))),
                      const Text(
                          'Le téléphone doit identifier correctement le nom de l’opérateur (MTN / Orange).',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ]))),
        const SizedBox(height: 10),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Signature par défaut',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      TextField(
                          controller: signature,
                          decoration: const InputDecoration(
                              hintText: 'Ex. CamSchool — Service client')),
                      const SizedBox(height: 8),
                      FilledButton(
                          onPressed: () async {
                            await AppDatabase.instance.setSetting(
                                'default_signature', signature.text);
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Signature enregistrée.')));
                          },
                          child: const Text('Enregistrer la signature')),
                    ]))),
        SwitchListTile(
            title: const Text('Mode sombre'),
            value: dark,
            onChanged: (v) {
              setState(() => dark = v);
              widget.onThemeChanged(v ? ThemeMode.dark : ThemeMode.light);
            }),
        const SizedBox(height: 8),
        OutlinedButton.icon(
            onPressed: () async {
              final permission = await Permission.sms.request();
              final phone = await Permission.phone.request();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(
                      'SMS : ${permission.isGranted ? "autorisé" : "refusé"} • Téléphone : ${phone.isGranted ? "autorisé" : "refusé"}')));
              await widget.onChanged();
            },
            icon: const Icon(Icons.security),
            label: const Text('Vérifier les autorisations')),
        const SizedBox(height: 16),
        const Text(
            'Données locales : contacts, groupes, modèles, campagnes et rapports restent dans la base SQLite de ce téléphone. Prévois une sauvegarde avant de réinitialiser ou désinstaller l’application.',
            style: TextStyle(color: Colors.grey)),
      ]);
}

class CampaignEngine extends ChangeNotifier {
  final Set<int> _active = {};
  final Map<String, Future<void>> _simTails = {};
  bool _disposed = false;

  Future<void> start(int campaignId) async {
    if (_active.contains(campaignId)) return;
    final phonePermission = await Permission.phone.request();
    final smsPermission = await Permission.sms.request();
    if (!phonePermission.isGranted || !smsPermission.isGranted) {
      await AppDatabase.instance.setCampaignStatus(campaignId, 'failed');
      notifyListeners();
      return;
    }
    _active.add(campaignId);
    await AppDatabase.instance.setCampaignStatus(campaignId, 'running');
    notifyListeners();
    unawaited(_run(campaignId));
  }

  Future<void> pause(int id) async {
    await AppDatabase.instance.setCampaignStatus(id, 'paused');
    notifyListeners();
  }

  Future<void> stop(int id) async {
    await AppDatabase.instance.setCampaignStatus(id, 'stopped');
    notifyListeners();
  }

  Future<void> _run(int id) async {
    try {
      final campaign = await AppDatabase.instance.getCampaignById(id);
      if (campaign == null) return;
      while (true) {
        final state = await AppDatabase.instance.getCampaignStatus(id);
        if (state != 'running') break;
        final next = await AppDatabase.instance.nextPendingRecipient(id);
        if (next == null) {
          await AppDatabase.instance.setCampaignStatus(id, 'completed');
          break;
        }
        final sim = await _chooseSim(campaign.simMode, next['phone'] as String);
        if (sim == null) {
          await AppDatabase.instance.updateRecipient(
              id,
              next['recipient_id'] as int,
              'failed',
              'SIM correspondante indisponible');
          notifyListeners();
          continue;
        }
        final key = 'sub_${sim.subscriptionId}';
        final previous = _simTails[key] ?? Future<void>.value();
        final completer = Completer<void>();
        _simTails[key] = completer.future;
        await previous;
        try {
          final current = await AppDatabase.instance.getCampaignStatus(id);
          if (current != 'running') break;
          final message =
              personalize(campaign.message, next, campaign.signature);
          try {
            await SmsBridge.sendSms(
                sim.subscriptionId, next['phone'] as String, message);
            await AppDatabase.instance.updateRecipient(
                id,
                next['recipient_id'] as int,
                'sent',
                'Demande transmise via ${sim.carrier}');
          } catch (e) {
            await AppDatabase.instance.updateRecipient(
                id, next['recipient_id'] as int, 'failed', e.toString());
          }
        } finally {
          completer.complete();
        }
        notifyListeners();
        await Future.delayed(Duration(milliseconds: campaign.intervalMs));
      }
    } catch (e) {
      await AppDatabase.instance.setCampaignStatus(id, 'failed');
    } finally {
      _active.remove(id);
      if (!_disposed) notifyListeners();
    }
  }

  Future<SimCard?> _chooseSim(String mode, String phone) async {
    final sims = await SmsBridge.getSims();
    if (sims.isEmpty) return null;
    final op = mode == 'AUTO' ? operatorFor(phone) : mode;
    for (final s in sims) {
      final n = '${s.carrier} ${s.displayName}'.toLowerCase();
      if (op == 'MTN' && n.contains('mtn')) return s;
      if (op == 'ORANGE' && n.contains('orange')) return s;
    }
    return mode == 'AUTO' ? null : null;
  }

  String personalize(
      String template, Map<String, Object?> contact, String signature) {
    var result = template
        .replaceAll(
            '{first_name}', (contact['name'] ?? '').toString().split(' ').first)
        .replaceAll('{last_name}',
            (contact['name'] ?? '').toString().split(' ').skip(1).join(' '))
        .replaceAll('{phone}', (contact['phone'] ?? '').toString());
    if (signature.trim().isNotEmpty) result = '$result\n${signature.trim()}';
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
