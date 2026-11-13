import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:socket_io_client/socket_io_client.dart' as socket_io;

import 'database.dart';
import 'models.dart';
import 'sms_bridge.dart';

class GatewayHostDraft {
  final String name, url, socketPath, room, token;
  const GatewayHostDraft({
    required this.name,
    required this.url,
    required this.socketPath,
    required this.room,
    required this.token,
  });
}

class SmsGatewayService extends ChangeNotifier {
  final Map<int, socket_io.Socket> _sockets = {};
  final Map<int, String> _statuses = {};
  bool _disposed = false;
  String? initializationError;

  String statusFor(int id) => _statuses[id] ?? 'Déconnecté';

  Future<void> initialize() async {
    try {
      initializationError = null;
      await _syncConnections(reconnectAll: true);
    } catch (e) {
      initializationError = e.toString();
      _notify();
    }
  }

  Future<void> saveHost(GatewayHostDraft draft, {GatewayHost? existing}) async {
    final name = draft.name.trim();
    final url = _validateUrl(draft.url);
    final socketPath = _validateSocketPath(draft.socketPath);
    final token = draft.token.trim();
    final room = draft.room.trim();
    if (name.isEmpty) throw const FormatException('Le nom du host est obligatoire.');
    if (room.isNotEmpty && !RegExp(r'^[A-Za-z0-9:_-]{1,128}$').hasMatch(room)) {
      throw const FormatException('La chambre ne peut contenir que lettres, chiffres, :, _ et - (128 caractères maximum).');
    }
    if (existing == null && token.isEmpty) {
      throw const FormatException('Le jeton d’authentification est obligatoire.');
    }

    if (existing == null) {
      final deviceId = _newDeviceId();
      await SmsBridge.storeGatewayToken(deviceId, token);
      try {
        await AppDatabase.instance.addGatewayHost(
          name: name,
          url: url,
          socketPath: socketPath,
          deviceId: deviceId,
          room: room.isEmpty ? 'sms-gateway:$deviceId' : room,
        );
      } catch (_) {
        await SmsBridge.deleteGatewayToken(deviceId);
        rethrow;
      }
    } else {
      if (token.isNotEmpty) {
        await SmsBridge.storeGatewayToken(existing.deviceId, token);
      }
      await AppDatabase.instance.updateGatewayHost(
        existing.id,
        name: name,
        url: url,
        socketPath: socketPath,
        room: room.isEmpty ? 'sms-gateway:${existing.deviceId}' : room,
      );
    }
    await _syncConnections(reconnectAll: true);
  }

  Future<void> setEnabled(GatewayHost host, bool enabled) async {
    if (enabled) {
      final token = await SmsBridge.readGatewayToken(host.deviceId);
      if (token == null || token.isEmpty) {
        throw const FormatException('Ajoutez un jeton d’authentification avant d’activer ce host.');
      }
    }
    await AppDatabase.instance.setGatewayHostEnabled(host.id, enabled);
    await _syncConnections();
  }

  Future<void> deleteHost(GatewayHost host) async {
    await _disconnect(host.id);
    await SmsBridge.deleteGatewayToken(host.deviceId);
    await AppDatabase.instance.deleteGatewayHost(host.id);
    _statuses.remove(host.id);
    _notify();
  }

  Future<void> _syncConnections({bool reconnectAll = false}) async {
    final hosts = await AppDatabase.instance.getGatewayHosts();
    final activeIds = hosts.where((host) => host.enabled).map((host) => host.id).toSet();
    for (final id in _sockets.keys.toList()) {
      if (reconnectAll || !activeIds.contains(id)) await _disconnect(id);
    }
    for (final host in hosts.where((host) => host.enabled)) {
      if (!_sockets.containsKey(host.id)) await _connect(host);
    }
  }

  Future<void> _connect(GatewayHost host) async {
    final token = await SmsBridge.readGatewayToken(host.deviceId);
    if (token == null || token.isEmpty) {
      _statuses[host.id] = 'Jeton manquant';
      _notify();
      return;
    }
    _statuses[host.id] = 'Connexion…';
    _notify();
    final uri = Uri.parse(host.url);
    final socket = socket_io.io(uri.origin, {
      'transports': ['websocket'],
      'autoConnect': false,
      'reconnection': true,
      'path': host.socketPath,
      'auth': {'token': token, 'deviceId': host.deviceId},
    });
    _sockets[host.id] = socket;
    socket.on('connect', (_) {
      _statuses[host.id] = 'Connecté — inscription à la chambre…';
      socket.emit('gateway:register', {'deviceId': host.deviceId, 'room': host.room});
      _notify();
    });
    socket.on('gateway:ready', (_) {
      _statuses[host.id] = 'Prêt';
      _notify();
    });
    socket.on('disconnect', (reason) {
      _statuses[host.id] = 'Déconnecté${reason == null ? '' : ' : $reason'}';
      _notify();
    });
    socket.on('connect_error', (error) {
      _statuses[host.id] = 'Erreur de connexion : $error';
      _notify();
    });
    socket.on('sms:send', (data) => unawaited(_handleSmsRequest(host, socket, data)));
    socket.connect();
  }

  Future<void> _handleSmsRequest(GatewayHost host, socket_io.Socket socket, dynamic data) async {
    String? requestId;
    var status = 'failed';
    var detail = 'Requête invalide';
    try {
      if (data is! Map) throw const FormatException('Le contenu de la requête doit être un objet JSON.');
      final payload = Map<String, dynamic>.from(data);
      requestId = payload['requestId']?.toString().trim();
      final rawPhone = payload['phone']?.toString().trim() ?? '';
      final phone = normalizeCameroonPhone(rawPhone);
      final operator = payload['operator']?.toString().trim().toUpperCase() ?? '';
      final message = payload['message']?.toString() ?? '';
      if (requestId == null || requestId.isEmpty || requestId.length > 128) {
        throw const FormatException('requestId est obligatoire (128 caractères maximum).');
      }
      if (phone.isEmpty) throw const FormatException('Numéro camerounais invalide.');
      if (operator != 'MTN' && operator != 'ORANGE') {
        throw const FormatException('operator doit être MTN ou ORANGE.');
      }
      if (message.trim().isEmpty || message.length > 1600) {
        throw const FormatException('Le message doit contenir de 1 à 1600 caractères.');
      }

      final reservation = await AppDatabase.instance.reserveGatewayRequest(
        hostId: host.id,
        requestId: requestId,
        phone: phone,
        operator: operator,
        now: DateTime.now(),
      );
      if (reservation['result'] == 'duplicate') {
        status = reservation['status'] == 'accepted' ? 'accepted' : 'failed';
        detail = reservation['status'] == 'pending'
            ? 'Doublon : requête déjà en cours, aucun nouvel envoi'
            : 'Doublon : aucun nouvel envoi';
        _emitResult(socket, host, requestId, status, detail);
        return;
      }
      if (reservation['result'] == 'rate_limited') {
        detail = 'Plafond atteint : maximum 100 SMS par heure et 1000 par 24 heures.';
        _emitResult(socket, host, requestId, status, detail);
        return;
      }

      final enabledHosts = await AppDatabase.instance.getGatewayHosts();
      if (!enabledHosts.any((item) => item.id == host.id && item.enabled)) {
        throw const FormatException('La passerelle a été désactivée.');
      }
      if (!await Permission.sms.isGranted || !await Permission.phone.isGranted) {
        throw const FormatException('Les autorisations SMS et téléphone doivent être accordées.');
      }
      final sims = await SmsBridge.getSims();
      final sim = _simForOperator(sims, operator);
      if (sim == null) throw FormatException('Aucune SIM $operator disponible sur cet appareil.');

      await SmsBridge.sendSms(sim.subscriptionId, phone, message);
      status = 'accepted';
      detail = 'Demande transmise à Android via ${sim.carrier}.';
      await AppDatabase.instance.updateGatewayRequest(host.id, requestId, status, detail);
    } on PlatformException catch (e) {
      detail = e.message ?? 'Android a refusé la demande d’envoi.';
      if (requestId != null && requestId.isNotEmpty) {
        await _recordFailure(host.id, requestId, detail);
      }
    } catch (e) {
      detail = e is FormatException ? e.message : e.toString();
      if (requestId != null && requestId.isNotEmpty) {
        await _recordFailure(host.id, requestId, detail);
      }
    }
    _emitResult(socket, host, requestId, status, detail);
  }

  Future<void> _recordFailure(int hostId, String requestId, String detail) async {
    try {
      await AppDatabase.instance.updateGatewayRequest(hostId, requestId, 'failed', detail);
    } catch (e) {
      _statuses[hostId] = 'Erreur d’enregistrement du résultat : $e';
      _notify();
    }
  }

  void _emitResult(socket_io.Socket socket, GatewayHost host, String? requestId, String status, String detail) {
    socket.emit('sms:result', {
      'requestId': requestId ?? '',
      'deviceId': host.deviceId,
      'status': status,
      'detail': detail.length > 240 ? detail.substring(0, 240) : detail,
    });
  }

  SimCard? _simForOperator(List<SimCard> sims, String operator) {
    for (final sim in sims) {
      final name = '${sim.carrier} ${sim.displayName}'.toLowerCase();
      if (name.contains(operator.toLowerCase())) return sim;
    }
    return null;
  }

  String _validateUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !uri.hasAuthority || uri.userInfo.isNotEmpty || uri.query.isNotEmpty || uri.fragment.isNotEmpty) {
      throw const FormatException('Saisissez une URL de host valide, sans identifiant ni paramètres.');
    }
    if (uri.path.isNotEmpty && uri.path != '/') {
      throw const FormatException('Saisissez uniquement l’origine du host ici ; le chemin Socket.IO se règle séparément.');
    }
    if (uri.scheme == 'https' && uri.host.isNotEmpty) return uri.origin;
    if (uri.scheme == 'http' && _isLocalHost(uri.host)) return uri.origin;
    throw const FormatException('Utilisez HTTPS. HTTP est accepté uniquement sur une adresse du réseau local.');
  }

  bool _isLocalHost(String host) {
    final normalized = host.toLowerCase();
    if (normalized == 'localhost' || normalized.endsWith('.local')) return true;
    final address = InternetAddress.tryParse(normalized);
    if (address == null) return false;
    if (address.isLoopback || address.isLinkLocal) return true;
    if (address.type == InternetAddressType.IPv4) {
      final octets = address.rawAddress;
      return octets[0] == 10 ||
          (octets[0] == 192 && octets[1] == 168) ||
          (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31);
    }
    return false;
  }

  String _validateSocketPath(String raw) {
    final path = raw.trim();
    if (!path.startsWith('/') || path.contains(' ') || path.contains('?') || path.contains('#')) {
      throw const FormatException('Le chemin Socket.IO doit commencer par /, par exemple /socket.io.');
    }
    return path;
  }

  String _newDeviceId() {
    final random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<void> _disconnect(int id) async {
    _sockets.remove(id)?.dispose();
    _statuses[id] = 'Déconnecté';
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final socket in _sockets.values) {
      socket.dispose();
    }
    _sockets.clear();
    super.dispose();
  }
}

class GatewayPage extends StatefulWidget {
  final SmsGatewayService service;
  const GatewayPage({super.key, required this.service});

  @override
  State<GatewayPage> createState() => _GatewayPageState();
}

class _GatewayPageState extends State<GatewayPage> {
  List<GatewayHost> hosts = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_refresh);
    _load();
  }

  @override
  void dispose() {
    widget.service.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _load() async {
    final values = await AppDatabase.instance.getGatewayHosts();
    if (!mounted) return;
    setState(() {
      hosts = values;
      loading = false;
    });
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _editHost([GatewayHost? host]) async {
    final draft = await showDialog<GatewayHostDraft>(
      context: context,
      builder: (_) => GatewayHostDialog(host: host),
    );
    if (draft == null) return;
    try {
      await widget.service.saveHost(draft, existing: host);
      await _load();
      _snack('Host enregistré. L’activation de l’envoi reste à faire.');
    } catch (e) {
      _snack('Enregistrement impossible : $e');
    }
  }

  Future<void> _toggleHost(GatewayHost host, bool enabled) async {
    try {
      if (enabled) {
        final sms = await Permission.sms.request();
        final phone = await Permission.phone.request();
        if (!sms.isGranted || !phone.isGranted) {
          _snack('Accordez les autorisations SMS et téléphone pour activer la passerelle.');
          return;
        }
      }
      await widget.service.setEnabled(host, enabled);
      await _load();
    } catch (e) {
      _snack('Modification impossible : $e');
    }
  }

  Future<void> _deleteHost(GatewayHost host) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer ce host ?'),
        content: const Text('La connexion sera coupée et son jeton supprimé de l’appareil.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Supprimer')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.service.deleteHost(host);
      await _load();
    } catch (e) {
      _snack('Suppression impossible : $e');
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.service,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          Expanded(child: Text('Passerelle SMS', style: Theme.of(context).textTheme.headlineSmall)),
          IconButton(
            tooltip: 'Documentation serveur',
            onPressed: () => showDialog<void>(context: context, builder: (_) => const GatewayDocumentation()),
            icon: const Icon(Icons.menu_book_outlined),
          ),
        ]),
        const Text('Connectez ce téléphone à votre serveur Socket.IO. Chaque host doit être activé explicitement sur le mobile.'),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => _editHost(),
          icon: const Icon(Icons.add_link),
          label: const Text('Ajouter un host'),
        ),
        const SizedBox(height: 8),
        if (loading) const Center(child: CircularProgressIndicator())
        else if (hosts.isEmpty)
          const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('Aucun host configuré. Ajoutez l’URL, le jeton et la chambre fournis par votre serveur.')))
        else
          ...hosts.map((host) => Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(children: [
                SwitchListTile(
                  title: Text(host.name),
                  subtitle: Text(widget.service.statusFor(host.id)),
                  value: host.enabled,
                  onChanged: (value) => _toggleHost(host, value),
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(host.url),
                  subtitle: Text('Chambre : ${host.room}\nID appareil : ${host.deviceId}'),
                ),
                OverflowBar(children: [
                  TextButton.icon(onPressed: () => _editHost(host), icon: const Icon(Icons.edit), label: const Text('Modifier')),
                  TextButton.icon(onPressed: () => _deleteHost(host), icon: const Icon(Icons.delete_outline), label: const Text('Supprimer')),
                ]),
              ]),
            ),
          )),
        if (widget.service.initializationError != null)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Erreur de démarrage de la passerelle : ${widget.service.initializationError}'),
            ),
          ),
        const SizedBox(height: 12),
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Padding(
            padding: EdgeInsets.all(14),
            child: Text('Limites locales : 100 demandes par heure et 1000 par période glissante de 24 h, par host. Le statut « accepted » signifie que la demande a été transmise au service SMS Android, pas que le destinataire l’a reçue. Gardez l’application ouverte : Android peut interrompre une connexion en arrière-plan.'),
          ),
        ),
        TextButton.icon(
          onPressed: () => showDialog<void>(context: context, builder: (_) => const GatewayDocumentation()),
          icon: const Icon(Icons.code),
          label: const Text('Voir le guide d’intégration Socket.IO'),
        ),
      ],
    ),
  );
}

class GatewayHostDialog extends StatefulWidget {
  final GatewayHost? host;
  const GatewayHostDialog({super.key, this.host});

  @override
  State<GatewayHostDialog> createState() => _GatewayHostDialogState();
}

class _GatewayHostDialogState extends State<GatewayHostDialog> {
  final formKey = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.host?.name ?? '');
  late final url = TextEditingController(text: widget.host?.url ?? 'https://');
  late final socketPath = TextEditingController(text: widget.host?.socketPath ?? '/socket.io');
  late final room = TextEditingController(text: widget.host?.room ?? '');
  final token = TextEditingController();

  @override
  void dispose() {
    name.dispose();
    url.dispose();
    socketPath.dispose();
    room.dispose();
    token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.host == null ? 'Ajouter un host' : 'Modifier le host'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Nom du host'), validator: (v) => v == null || v.trim().isEmpty ? 'Champ obligatoire' : null),
            TextFormField(controller: url, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'URL du serveur (HTTPS)'), validator: (v) => v == null || v.trim().isEmpty ? 'Champ obligatoire' : null),
            TextFormField(controller: socketPath, decoration: const InputDecoration(labelText: 'Chemin Socket.IO', hintText: '/socket.io')),
            TextFormField(controller: room, decoration: InputDecoration(labelText: 'Chambre', hintText: widget.host == null ? 'Générée automatiquement si vide' : 'sms-gateway:${widget.host?.deviceId}')),
            TextFormField(
              controller: token,
              obscureText: true,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: widget.host == null ? 'Jeton d’authentification' : 'Remplacer le jeton (facultatif)',
                helperText: 'Conservé dans le stockage sécurisé Android, jamais affiché.',
              ),
            ),
          ]),
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
      FilledButton(
        onPressed: () {
          if (formKey.currentState?.validate() != true) return;
          Navigator.pop(context, GatewayHostDraft(
            name: name.text,
            url: url.text,
            socketPath: socketPath.text,
            room: room.text,
            token: token.text,
          ));
        },
        child: const Text('Enregistrer'),
      ),
    ],
  );
}

class GatewayDocumentation extends StatelessWidget {
  const GatewayDocumentation({super.key});

  static const _serverExample = '''// Exemple Node.js avec socket.io
io.use(async (socket, next) => {
  const token = socket.handshake.auth?.token;
  const device = await findAuthorizedGateway(token);
  if (!device) return next(new Error("unauthorized"));
  socket.data.deviceId = device.id;
  next();
});

io.on("connection", (socket) => {
  socket.on("gateway:register", ({ deviceId, room }) => {
    if (deviceId !== socket.data.deviceId ||
        room !== `sms-gateway:\${deviceId}`) return;
    socket.join(room);
    socket.emit("gateway:ready", { deviceId });
  });
  socket.on("sms:result", (result) => {
    saveGatewayResult(socket.data.deviceId, result);
  });
});

// Envoyer une demande à un appareil autorisé
function sendSmsToGateway(deviceId, phone, operator, message) {
  io.to(`sms-gateway:\${deviceId}`).emit("sms:send", {
    requestId: crypto.randomUUID(),
    phone, operator, message
  });
}

// status: "accepted" ou "failed"
// accepted = Android a accepté la demande, pas une preuve de livraison
// Le résultat est reçu dans le gestionnaire "connection" ci-dessus.''';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Intégrer votre serveur web'),
    content: const SizedBox(
      width: 600,
      child: SingleChildScrollView(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('1. Dans l’application mobile, ajoutez le host avec son URL HTTPS, son chemin Socket.IO (par défaut /socket.io) et un jeton propre à cet appareil. Activez ensuite le host sur le téléphone.'),
          SizedBox(height: 10),
          Text('2. Authentifiez le jeton dans le middleware Socket.IO. L’application envoie le jeton dans handshake.auth et demande à rejoindre sms-gateway:<deviceId>. Le serveur doit vérifier que le jeton autorise cet appareil et cette chambre avant socket.join, puis répondre gateway:ready. Ne faites jamais confiance au nom de chambre reçu sans cette vérification.'),
          SizedBox(height: 10),
          Text('3. Émettez sms:send dans la chambre autorisée avec un requestId unique, le numéro camerounais, operator (MTN ou ORANGE) et message. Écoutez sms:result pour enregistrer le résultat. Un requestId dupliqué ne déclenche jamais un deuxième SMS.'),
          SizedBox(height: 10),
          Text('Exemple côté serveur :', style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 6),
          SelectableText(_serverExample, style: TextStyle(fontFamily: 'monospace', fontSize: 12)),
          SizedBox(height: 10),
          Text('Envoi uniquement après activation explicite sur le téléphone. Plafonds : 100 SMS/heure et 1000/24 h par host. Utilisez TLS, gardez les jetons secrets et n’envoyez que des messages sollicités. L’application doit rester ouverte ; l’envoi garanti en arrière-plan nécessiterait un service Android dédié.'),
        ],
      )),
    ),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer'))],
  );
}
