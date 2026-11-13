import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'models.dart';

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();
  late Database db;

  Future<void> init() async {
    final path = p.join(await getDatabasesPath(), 'camsms_campaigns.db');
    db = await openDatabase(path, version: 3, onCreate: (d, v) async {
      await d.execute(
          'CREATE TABLE contacts(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, phone TEXT NOT NULL UNIQUE)');
      await d.execute(
          'CREATE TABLE groups_tbl(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE)');
      await d.execute(
          'CREATE TABLE group_members(group_id INTEGER NOT NULL, contact_id INTEGER NOT NULL, PRIMARY KEY(group_id, contact_id), FOREIGN KEY(group_id) REFERENCES groups_tbl(id) ON DELETE CASCADE, FOREIGN KEY(contact_id) REFERENCES contacts(id) ON DELETE CASCADE)');
      await d.execute(
          'CREATE TABLE templates(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, body TEXT NOT NULL)');
      await d.execute(
          'CREATE TABLE campaigns(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, group_id INTEGER NOT NULL, message TEXT NOT NULL, signature TEXT NOT NULL, sim_mode TEXT NOT NULL, interval_ms INTEGER NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL)');
      await _createCampaignRecipientsTable(d);
      await d
          .execute('CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)');
      await _createGatewayTables(d);
    }, onUpgrade: (d, oldVersion, newVersion) async {
      if (oldVersion < 2) await _createGatewayTables(d);
      if (oldVersion < 3) await _upgradeCampaignRecipients(d);
    }, onConfigure: (d) async {
      await d.execute('PRAGMA foreign_keys = ON');
    });
  }

  Future<void> _createGatewayTables(DatabaseExecutor d) async {
    await d.execute(
        'CREATE TABLE gateway_hosts(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, url TEXT NOT NULL, socket_path TEXT NOT NULL, device_id TEXT NOT NULL UNIQUE, room TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 0)');
    await d.execute(
        'CREATE TABLE gateway_requests(id INTEGER PRIMARY KEY AUTOINCREMENT, host_id INTEGER NOT NULL, request_id TEXT NOT NULL, created_at TEXT NOT NULL, status TEXT NOT NULL, detail TEXT NOT NULL, phone TEXT NOT NULL, operator TEXT NOT NULL, UNIQUE(host_id, request_id))');
    await d.execute(
        'CREATE INDEX gateway_requests_host_time ON gateway_requests(host_id, created_at)');
  }

  Future<void> _createCampaignRecipientsTable(DatabaseExecutor d) async {
    await d.execute(
        'CREATE TABLE campaign_recipients(id INTEGER PRIMARY KEY AUTOINCREMENT, campaign_id INTEGER NOT NULL, contact_id INTEGER, name TEXT NOT NULL, phone TEXT NOT NULL, status TEXT NOT NULL DEFAULT "pending", detail TEXT, FOREIGN KEY(campaign_id) REFERENCES campaigns(id) ON DELETE CASCADE, FOREIGN KEY(contact_id) REFERENCES contacts(id) ON DELETE SET NULL)');
  }

  Future<void> _upgradeCampaignRecipients(DatabaseExecutor d) async {
    await d.execute(
        'CREATE TABLE campaign_recipients_new(id INTEGER PRIMARY KEY AUTOINCREMENT, campaign_id INTEGER NOT NULL, contact_id INTEGER, name TEXT NOT NULL, phone TEXT NOT NULL, status TEXT NOT NULL DEFAULT "pending", detail TEXT, FOREIGN KEY(campaign_id) REFERENCES campaigns(id) ON DELETE CASCADE, FOREIGN KEY(contact_id) REFERENCES contacts(id) ON DELETE SET NULL)');
    await d.execute(
        'INSERT INTO campaign_recipients_new(campaign_id,contact_id,name,phone,status,detail) SELECT r.campaign_id,r.contact_id,c.name,c.phone,r.status,COALESCE(r.detail, "") FROM campaign_recipients r JOIN contacts c ON c.id=r.contact_id');
    await d.execute('DROP TABLE campaign_recipients');
    await d.execute(
        'ALTER TABLE campaign_recipients_new RENAME TO campaign_recipients');
  }

  Future<bool> addContact(String name, String phone) async {
    final id = await db.insert(
      'contacts',
      {'name': name, 'phone': phone},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return id != -1;
  }

  Future<void> updateContact(int id, String name, String phone) async {
    await db.update('contacts', {'name': name, 'phone': phone},
        where: 'id=?', whereArgs: [id]);
  }

  Future<void> deleteContact(int id) async {
    await db.delete('contacts', where: 'id=?', whereArgs: [id]);
  }

  Future<List<Contact>> getContacts() async =>
      (await db.query('contacts', orderBy: 'name'))
          .map((r) => Contact(
              id: r['id'] as int,
              name: r['name'] as String,
              phone: r['phone'] as String))
          .toList();

  Future<bool> addGroup(String name) async {
    final id = await db.insert(
      'groups_tbl',
      {'name': name},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return id != -1;
  }

  Future<int?> createGroupWithNumbers(String name, List<String> phones) async {
    return db.transaction((txn) async {
      final groupId = await txn.insert(
        'groups_tbl',
        {'name': name},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      if (groupId == -1) return null;
      for (final phone in phones.toSet()) {
        if (normalizeCameroonPhone(phone) != phone) {
          throw const FormatException(
              'Le groupe ne peut contenir que des numéros camerounais valides.');
        }
        await txn.insert(
          'contacts',
          {'name': 'Contact', 'phone': phone},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        final rows = await txn.query(
          'contacts',
          columns: ['id'],
          where: 'phone=?',
          whereArgs: [phone],
          limit: 1,
        );
        if (rows.isEmpty) {
          throw StateError(
              'Contact inserted or already stored but not found: $phone');
        }
        await txn.insert(
          'group_members',
          {'group_id': groupId, 'contact_id': rows.first['id']},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      return groupId;
    });
  }

  Future<void> renameGroup(int id, String name) async {
    await db.update('groups_tbl', {'name': name},
        where: 'id=?', whereArgs: [id]);
  }

  Future<void> deleteGroup(int id) async {
    await db.delete('groups_tbl', where: 'id=?', whereArgs: [id]);
  }

  Future<List<ContactGroup>> getGroups() async {
    final rows = await db.rawQuery(
        'SELECT g.id,g.name,COUNT(m.contact_id) AS count FROM groups_tbl g LEFT JOIN group_members m ON m.group_id=g.id GROUP BY g.id ORDER BY g.name');
    return rows
        .map((r) => ContactGroup(
            id: r['id'] as int,
            name: r['name'] as String,
            count: (r['count'] as int?) ?? 0))
        .toList();
  }

  Future<List<Contact>> getGroupContacts(int groupId) async =>
      (await db.rawQuery(
              'SELECT c.* FROM contacts c INNER JOIN group_members m ON c.id=m.contact_id WHERE m.group_id=? ORDER BY c.name',
              [
            groupId
          ]))
          .map((r) => Contact(
              id: r['id'] as int,
              name: r['name'] as String,
              phone: r['phone'] as String))
          .toList();
  Future<void> setGroupMembers(int groupId, List<int> ids) async {
    await db.transaction((txn) async {
      await txn
          .delete('group_members', where: 'group_id=?', whereArgs: [groupId]);
      for (final id in ids) {
        await txn.insert(
            'group_members', {'group_id': groupId, 'contact_id': id},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  Future<void> addContactsToGroup(int groupId, List<int> contactIds) async {
    await db.transaction((txn) async {
      for (final contactId in contactIds) {
        await txn.insert(
          'group_members',
          {'group_id': groupId, 'contact_id': contactId},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  Future<void> removeContactsFromGroup(
      int groupId, List<int> contactIds) async {
    for (var start = 0; start < contactIds.length; start += 900) {
      final batch = contactIds.skip(start).take(900).toList();
      final placeholders = List.filled(batch.length, '?').join(',');
      await db.delete(
        'group_members',
        where: 'group_id=? AND contact_id IN ($placeholders)',
        whereArgs: [groupId, ...batch],
      );
    }
  }

  Future<void> addTemplate(String name, String body) async {
    await db.insert('templates', {'name': name, 'body': body});
  }

  Future<void> updateTemplate(int id, String name, String body) async {
    await db.update('templates', {'name': name, 'body': body},
        where: 'id=?', whereArgs: [id]);
  }

  Future<void> deleteTemplate(int id) async {
    await db.delete('templates', where: 'id=?', whereArgs: [id]);
  }

  Future<List<SmsTemplate>> getTemplates() async =>
      (await db.query('templates', orderBy: 'name'))
          .map((r) => SmsTemplate(
              id: r['id'] as int,
              name: r['name'] as String,
              body: r['body'] as String))
          .toList();

  Future<int> createCampaign(CampaignDraft draft) async {
    return db.transaction((txn) async {
      final id = await txn.insert('campaigns', {
        'name': draft.name,
        'group_id': draft.groupId,
        'message': draft.message,
        'signature': draft.signature,
        'sim_mode': draft.simMode,
        'interval_ms': draft.intervalMs,
        'status': 'draft',
        'created_at': DateTime.now().toIso8601String(),
      });
      if (draft.directRecipients.isNotEmpty) {
        for (final recipient in draft.directRecipients) {
          await txn.insert('campaign_recipients', {
            'campaign_id': id,
            'contact_id': null,
            'name': recipient.name,
            'phone': recipient.phone,
            'status': 'pending',
          });
        }
      } else {
        final members = await txn.rawQuery(
          'SELECT c.id contact_id,c.name,c.phone FROM contacts c INNER JOIN group_members m ON c.id=m.contact_id WHERE m.group_id=?',
          [draft.groupId],
        );
        for (final row in members) {
          await txn.insert('campaign_recipients', {
            'campaign_id': id,
            'contact_id': row['contact_id'],
            'name': row['name'],
            'phone': row['phone'],
            'status': 'pending',
          });
        }
      }
      return id;
    });
  }

  Future<List<SmsCampaign>> getCampaigns() async {
    final rows = await db.rawQuery('''
      SELECT c.*, COALESCE(g.name, CASE WHEN c.group_id=0 THEN 'Numéros directs' ELSE 'Groupe supprimé' END) group_name,
      COUNT(r.id) total,
      SUM(CASE WHEN r.status='sent' THEN 1 ELSE 0 END) sent,
      SUM(CASE WHEN r.status='failed' THEN 1 ELSE 0 END) failed,
      SUM(CASE WHEN r.status='pending' THEN 1 ELSE 0 END) pending
      FROM campaigns c LEFT JOIN groups_tbl g ON c.group_id=g.id
      LEFT JOIN campaign_recipients r ON c.id=r.campaign_id
      GROUP BY c.id ORDER BY c.id DESC
    ''');
    return rows.map(_campaignFromRow).toList();
  }

  Future<SmsCampaign?> getCampaignById(int id) async {
    final rows = await db.rawQuery(
        'SELECT c.*,COALESCE(g.name, CASE WHEN c.group_id=0 THEN "Numéros directs" ELSE "Groupe supprimé" END) group_name,(SELECT COUNT(*) FROM campaign_recipients r WHERE r.campaign_id=c.id) total,(SELECT COUNT(*) FROM campaign_recipients r WHERE r.campaign_id=c.id AND r.status="sent") sent,(SELECT COUNT(*) FROM campaign_recipients r WHERE r.campaign_id=c.id AND r.status="failed") failed,(SELECT COUNT(*) FROM campaign_recipients r WHERE r.campaign_id=c.id AND r.status="pending") pending FROM campaigns c LEFT JOIN groups_tbl g ON g.id=c.group_id WHERE c.id=?',
        [id]);
    return rows.isEmpty ? null : _campaignFromRow(rows.first);
  }

  SmsCampaign _campaignFromRow(Map<String, Object?> r) => SmsCampaign(
        id: r['id'] as int,
        groupId: r['group_id'] as int,
        intervalMs: r['interval_ms'] as int,
        total: (r['total'] as int?) ?? 0,
        sent: (r['sent'] as int?) ?? 0,
        failed: (r['failed'] as int?) ?? 0,
        pending: (r['pending'] as int?) ?? 0,
        name: r['name'] as String,
        message: r['message'] as String,
        signature: r['signature'] as String,
        simMode: r['sim_mode'] as String,
        status: r['status'] as String,
        groupName: (r['group_name'] ?? 'Groupe') as String,
      );
  Future<void> setCampaignStatus(int id, String status) async {
    await db.update('campaigns', {'status': status},
        where: 'id=?', whereArgs: [id]);
  }

  Future<String?> getCampaignStatus(int id) async {
    final r = await db.query('campaigns',
        columns: ['status'], where: 'id=?', whereArgs: [id], limit: 1);
    return r.isEmpty ? null : r.first['status'] as String;
  }

  Future<Map<String, Object?>?> nextPendingRecipient(int campaignId) async {
    final rows = await db.rawQuery(
        'SELECT r.id recipient_id,r.contact_id,r.name,r.phone FROM campaign_recipients r WHERE r.campaign_id=? AND r.status="pending" ORDER BY r.id LIMIT 1',
        [campaignId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> updateRecipient(
      int campaignId, int recipientId, String status, String detail) async {
    await db.update('campaign_recipients', {'status': status, 'detail': detail},
        where: 'campaign_id=? AND id=?', whereArgs: [campaignId, recipientId]);
  }

  Future<void> resetFailedRecipients(int campaignId) async {
    await db.update(
        'campaign_recipients', {'status': 'pending', 'detail': null},
        where: 'campaign_id=? AND status=?', whereArgs: [campaignId, 'failed']);
    await setCampaignStatus(campaignId, 'paused');
  }

  Future<List<Map<String, Object?>>> getCampaignRecipients(
          int campaignId) async =>
      db.rawQuery(
          'SELECT r.name,r.phone,r.status,r.detail FROM campaign_recipients r WHERE r.campaign_id=? ORDER BY r.name',
          [campaignId]);
  Future<String?> getSetting(String key) async {
    final r = await db.query('settings',
        columns: ['value'], where: 'key=?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) async {
    await db.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<GatewayHost>> getGatewayHosts() async {
    final rows = await db.query('gateway_hosts', orderBy: 'id');
    return rows
        .map((r) => GatewayHost(
              id: r['id'] as int,
              name: r['name'] as String,
              url: r['url'] as String,
              socketPath: r['socket_path'] as String,
              deviceId: r['device_id'] as String,
              room: r['room'] as String,
              enabled: r['enabled'] == 1,
            ))
        .toList();
  }

  Future<int> addGatewayHost({
    required String name,
    required String url,
    required String socketPath,
    required String deviceId,
    required String room,
  }) =>
      db.insert('gateway_hosts', {
        'name': name,
        'url': url,
        'socket_path': socketPath,
        'device_id': deviceId,
        'room': room,
        'enabled': 0,
      });
  Future<void> updateGatewayHost(
    int id, {
    required String name,
    required String url,
    required String socketPath,
    required String room,
  }) async {
    await db.update(
        'gateway_hosts',
        {
          'name': name,
          'url': url,
          'socket_path': socketPath,
          'room': room,
        },
        where: 'id=?',
        whereArgs: [id]);
  }

  Future<void> setGatewayHostEnabled(int id, bool enabled) async {
    await db.update('gateway_hosts', {'enabled': enabled ? 1 : 0},
        where: 'id=?', whereArgs: [id]);
  }

  Future<void> deleteGatewayHost(int id) async {
    await db.transaction((txn) async {
      await txn.delete('gateway_requests', where: 'host_id=?', whereArgs: [id]);
      await txn.delete('gateway_hosts', where: 'id=?', whereArgs: [id]);
    });
  }

  Future<Map<String, Object?>> reserveGatewayRequest({
    required int hostId,
    required String requestId,
    required String phone,
    required String operator,
    required DateTime now,
  }) async {
    return db.transaction((txn) async {
      final existing = await txn.query(
        'gateway_requests',
        columns: ['status', 'detail'],
        where: 'host_id=? AND request_id=?',
        whereArgs: [hostId, requestId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        return {
          'result': 'duplicate',
          'status': existing.first['status'],
          'detail': existing.first['detail']
        };
      }

      final hourStart =
          now.toUtc().subtract(const Duration(hours: 1)).toIso8601String();
      final dayStart =
          now.toUtc().subtract(const Duration(days: 1)).toIso8601String();
      final hourRows = await txn.rawQuery(
        'SELECT COUNT(*) AS count FROM gateway_requests WHERE host_id=? AND created_at>=?',
        [hostId, hourStart],
      );
      final dayRows = await txn.rawQuery(
        'SELECT COUNT(*) AS count FROM gateway_requests WHERE host_id=? AND created_at>=?',
        [hostId, dayStart],
      );
      if ((hourRows.first['count'] as int) >= 100 ||
          (dayRows.first['count'] as int) >= 1000) {
        return {
          'result': 'rate_limited',
          'status': 'failed',
          'detail': 'Plafond local atteint'
        };
      }

      await txn.insert('gateway_requests', {
        'host_id': hostId,
        'request_id': requestId,
        'created_at': now.toUtc().toIso8601String(),
        'status': 'pending',
        'detail': '',
        'phone': phone,
        'operator': operator,
      });
      return {'result': 'reserved', 'status': 'pending', 'detail': ''};
    });
  }

  Future<void> updateGatewayRequest(
      int hostId, String requestId, String status, String detail) async {
    await db.update('gateway_requests', {'status': status, 'detail': detail},
        where: 'host_id=? AND request_id=?', whereArgs: [hostId, requestId]);
  }
}
