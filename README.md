# CamSMS Campaigns — projet Flutter Android

Projet source d'un gestionnaire local de contacts, groupes, modèles et campagnes SMS à double SIM.

## Fonctionnalités livrées dans cette version

- Contacts individuels avec nom et numéro, édition et suppression.
- Consultation du répertoire Android et sélection des contacts à importer dans l’application.
- Import de contacts depuis CSV, TXT, Excel XLSX et vCard VCF (dont les exports Google Contacts).
- Détection des doublons par numéro sans remplacer les contacts locaux ni casser leurs associations aux groupes/campagnes.
- Groupes distincts des contacts : un groupe n'est jamais interprété comme un numéro.
- Un contact peut appartenir à plusieurs groupes.
- Modèles SMS et variables `{first_name}`, `{last_name}`, `{phone}`.
- Signature personnalisée par campagne et signature par défaut configurable.
- Campagnes enregistrées localement dans SQLite.
- Délai configurable entre SMS.
- Sélection automatique MTN/Orange par préfixe ou forçage d'une SIM.
- Lancement de plusieurs campagnes depuis l'écran Campagnes.
- Files d'envoi indépendantes par campagne et sérialisation des SMS sur une même SIM.
- Pause, reprise, arrêt, réessai des destinataires en échec et rapport par destinataire.
- Export CSV des rapports de campagne.
- Thème clair/sombre.
- Passerelle SMS Socket.IO configurable par host, avec jeton protégé par le stockage sécurisé Android.
- Recherche et sélection multiple de contacts, avec ajout ou retrait groupé dans un groupe.
- Génération aléatoire de numéros fictifs de test `+237 000 xxx xxx`, copiables et explicitement bloqués à l’import et à l’envoi SMS.
- Création de groupes en collant une liste de numéros séparés par virgules, points-virgules ou retours à la ligne.
- Création et lancement immédiat d’une campagne directement depuis une liste de numéros collés, sans créer de groupe.
- Commandes SMS distantes, routage explicite MTN/ORANGE, déduplication des requestId et plafonds locaux de 100 demandes/heure et 1000/24 h par host.

## Passerelle Socket.IO

L’écran **Passerelle** permet d’ajouter un host (URL, chemin Socket.IO, chambre et jeton), d’afficher son état et d’activer ou désactiver la connexion. L’activation demande les autorisations SMS et téléphone. Les jetons sont chiffrés avec une clé conservée dans Android Keystore et les données chiffrées sont stockées dans les préférences privées de l’application, séparément de la base SQLite.

### Contrat Socket.IO exact

- Authentification Socket.IO via `handshake.auth.token` et `handshake.auth.deviceId`.
- À la connexion, le mobile émet `gateway:register` avec `deviceId` et `room`. Le serveur doit valider l’association jeton/appareil avant d’ajouter la socket à la chambre, puis peut émettre `gateway:ready`.
- Dans la chambre autorisée, le serveur émet `sms:send` avec `requestId`, `phone`, `operator` (`MTN` ou `ORANGE`) et `message`.
- Le mobile répond par `sms:result` avec `requestId`, `deviceId`, `status` (`accepted` ou `failed`) et `detail`.

Exemple minimal copiable côté serveur Node.js avec Socket.IO :

```js
import { Server } from "socket.io";
import { randomUUID } from "node:crypto";

const io = new Server(httpServer, {
  path: "/socket.io",
  cors: { origin: ["https://votre-plateforme.example"] },
});

io.use(async (socket, next) => {
  try {
    const { token, deviceId } = socket.handshake.auth ?? {};
    const gateway = await findGatewayByToken(token);
    if (!gateway || gateway.deviceId !== deviceId || !gateway.enabled) {
      return next(new Error("unauthorized"));
    }
    socket.data.gateway = gateway;
    next();
  } catch (error) {
    next(new Error("unauthorized"));
  }
});

io.on("connection", (socket) => {
  const gateway = socket.data.gateway;
  const authorizedRoom = `sms-gateway:${gateway.deviceId}`;

  socket.on("gateway:register", ({ deviceId, room } = {}) => {
    if (deviceId !== gateway.deviceId || room !== authorizedRoom) return;
    socket.join(authorizedRoom);
    socket.emit("gateway:ready", { deviceId: gateway.deviceId });
  });

  socket.on("sms:result", async (result) => {
    if (result?.deviceId !== gateway.deviceId) return;
    await saveSmsGatewayResult({
      deviceId: gateway.deviceId,
      requestId: result.requestId,
      status: result.status,
      detail: result.detail,
    });
  });
});

function requestSms(deviceId, phone, operator, message) {
  if (!["MTN", "ORANGE"].includes(operator)) {
    throw new Error("operator must be MTN or ORANGE");
  }
  const requestId = randomUUID();
  io.to(`sms-gateway:${deviceId}`).emit("sms:send", {
    requestId,
    phone,       // ex. +237670123456
    operator,    // MTN ou ORANGE
    message,
  });
  return requestId; // conserver pour rapprocher sms:result
}
```

Le serveur doit associer chaque jeton à un appareil et à un host autorisés, authentifier avant `socket.join`, conserver un `requestId` unique, et enregistrer les résultats. En production, utiliser TLS, un jeton révocable par appareil, une origine CORS limitée à la plateforme et des permissions minimales.

| Événement | Direction | Données |
|---|---|---|
| Authentification | Mobile → serveur | `handshake.auth = { token, deviceId }` |
| `gateway:register` | Mobile → serveur | `{ deviceId, room: "sms-gateway:<deviceId>" }` |
| `gateway:ready` | Serveur → mobile | `{ deviceId }` (confirmation facultative d’inscription) |
| `sms:send` | Serveur → chambre mobile | `{ requestId, phone, operator, message }` |
| `sms:result` | Mobile → serveur | `{ requestId, deviceId, status, detail }` |

`phone` doit être un numéro camerounais à 9 chiffres, avec ou sans `+237`; `operator` vaut exactement `MTN` ou `ORANGE`. `status: "accepted"` signifie qu’Android a accepté la demande, pas que le destinataire a reçu le SMS. Les `requestId` déjà traités ne provoquent pas un deuxième envoi. Le mobile n’envoie que sur une SIM dont le nom d’opérateur correspond à la demande ; il ne bascule pas silencieusement vers une autre SIM. Les limites locales sont de 100 demandes par heure glissante et 1000 par période glissante de 24 heures, par host.

L’écran **Passerelle** de l’application contient aussi un guide développeur. La connexion doit être activée explicitement sur le téléphone. Elle ne garantit pas l’exécution lorsque l’application est fermée ou suspendue par Android.

### Flux développeur pour une plateforme web

1. Enregistrer un appareil passerelle sur le backend et générer un jeton secret révocable qui lui est propre.
2. Dans l’application mobile, ajouter l’URL HTTPS du serveur, le chemin Socket.IO (`/socket.io` par défaut), le jeton et la chambre `sms-gateway:<deviceId>`, puis activer le host et accorder les permissions SMS/téléphone.
3. Le backend authentifie le `handshake.auth`, vérifie l’appareil correspondant, puis lui envoie `sms:send` dans sa chambre; ne jamais accepter un nom de chambre choisi librement par un client.
4. Le mobile renvoie `sms:result`. Le backend rapproche `requestId`, met à jour son interface/statut, et traite un délai d’expiration comme « résultat inconnu » plutôt que de réémettre aveuglément le même SMS.
5. Pour déclencher l’envoi depuis une notification ou un événement web, faire passer cette demande par le backend authentifié et ce même contrat Socket.IO; ne jamais exposer le jeton du mobile au navigateur.

Prompt de référence à transmettre à une IA pour intégrer le backend :

```text
Intègre notre backend à l’application CamSMS Android via Socket.IO. Respecte ce contrat sans inventer d’autres événements :
- URL HTTPS et path /socket.io (ou la valeur configurée sur le mobile).
- Le mobile s’authentifie avec handshake.auth = { token, deviceId }.
- Vérifie le jeton côté serveur, son association à deviceId et son état actif AVANT d’autoriser une chambre.
- Le mobile émet gateway:register { deviceId, room: "sms-gateway:<deviceId>" }.
- Le serveur vérifie deviceId et room contre l’appareil authentifié, rejoint la room et peut répondre gateway:ready { deviceId }.
- Pour commander un SMS, le serveur émet sms:send DANS cette room avec
  { requestId: "<UUID unique>", phone: "+237670123456",
    operator: "MTN" | "ORANGE", message: "..." }.
- Le mobile répond sms:result { requestId, deviceId,
  status: "accepted" | "failed", detail }.
- Persiste chaque requestId et son résultat côté backend. Un timeout est
  indéterminé : ne renvoie pas automatiquement la demande, car Android a pu
  accepter le SMS avant la coupure socket.
- N’expose jamais le jeton au navigateur. Les notifications web appellent le
  backend authentifié, qui relaie ensuite au mobile par Socket.IO.
- Limites mobiles : 100 demandes/heure et 1000/24 h par host.
- "accepted" confirme uniquement que la demande a été transmise au service
  SMS Android, pas que le destinataire a reçu le message.
Produis le code serveur, la validation des entrées, la persistance des
requestId/résultats, la gestion des appareils hors ligne et des tests.
```

Les limites sont appliquées localement par host : 100 demandes par heure glissante et 1000 par période glissante de 24 heures. Le statut `accepted` indique qu’Android a accepté la demande d’envoi, pas que le destinataire a reçu le SMS. Les appels provenant des campagnes et de la passerelle sont sérialisés par SIM.

Dans **Contacts**, utilisez le champ de recherche pour filtrer les fiches par nom ou numéro. Activez la sélection multiple et choisissez les contacts, ou sélectionnez tous les résultats visibles. Les actions groupées permettent d’ajouter ou de retirer toute la sélection d’un groupe sans modifier les autres appartenances.

Le générateur dans **Contacts** crée des valeurs aléatoires de test sous la forme `+237 000 xxx xxx`. Le préfixe `000` est volontairement invalide/réservé aux tests : ces valeurs ne correspondent ni à MTN ni à Orange, ne sont pas acceptées par les imports, les groupes ou les campagnes, et les envois sont bloqués à la fois dans Flutter et dans le code natif Android. Elles peuvent être copiées, séparées par des virgules, pour des tests d’interface ou de parsing uniquement; elles ne représentent pas des numéros d’abonnés.

À la création d’un groupe, collez éventuellement des numéros séparés par des virgules, points-virgules ou retours à la ligne. Les numéros camerounais valides sont normalisés et ajoutés au groupe; les doublons sont ignorés. Depuis **Campagnes**, choisissez « Depuis des numéros collés » pour coller une liste, composer le message et lancer immédiatement une campagne sans groupe. Cette campagne directe garde ses destinataires, résultats, erreurs, délais et contrôles pause/arrêt/réessai dans le même suivi que les campagnes par groupe. La campagne utilise toujours les autorisations Android et une SIM correspondante.

Les campagnes directes enregistrent une copie du nom et du numéro de chaque destinataire dans le rapport. La migration SQLite vers la version 3 conserve les destinataires, statuts et détails des campagnes existantes.

Utilisez HTTPS en production, un jeton distinct par appareil et des chambres non accessibles à des clients non autorisés. HTTP n’est accepté que pour les adresses locales de test. L’envoi distant n’est disponible qu’après activation explicite sur le téléphone. Comme pour les campagnes, cette connexion ne garantit pas l’exécution lorsque l’application est fermée ou suspendue par Android ; un service de premier plan reste nécessaire pour une passerelle persistante.

## Contacts du téléphone et fichiers

Dans **Contacts**, utilisez **Répertoire** pour consulter les numéros camerounais présents sur le téléphone, les rechercher, sélectionner un ou plusieurs numéros, puis les importer dans la base locale de l’application. Android demande l’autorisation `READ_CONTACTS` au moment de cette action. La lecture passe par l’API native Android existante du projet ; les contacts du téléphone ne sont pas modifiés, seuls les numéros sélectionnés sont copiés dans CamSMS.

Le bouton d’import de fichier accepte `.csv`, `.txt`, `.xlsx` et `.vcf`. Pour Google Contacts, exportez les contacts au format vCard (`.vcf`) ou CSV. Le lecteur VCF prend en charge les cartes vCard usuelles, les lignes pliées et les champs `FN`/`N`/`TEL`; chaque numéro camerounais valide devient une entrée de contact. Les numéros sont normalisés sur 9 chiffres, et les doublons déjà présents dans l’application sont ignorés sans remplacer la fiche existante.

## Important : état réel de l'envoi

Cette version transmet les SMS au service Android et enregistre le résultat de la demande d'envoi. Le statut « envoyé » signifie que la demande a été acceptée par Android, pas que le téléphone du destinataire l'a reçue. Les accusés de livraison ne sont pas encore intégrés.

Le moteur de campagne tourne tant que le processus de l'application reste actif. Une fermeture forcée, un arrêt du processus ou certaines optimisations de batterie peuvent interrompre le travail. Pour un fonctionnement garanti écran éteint / application fermée, il faut ajouter un service Android de premier plan avec notification persistante, ainsi que des receivers de résultats SMS et une politique de reprise après redémarrage. Ne pas considérer cette version comme un service d'envoi garanti en arrière-plan.

Les campagnes simultanées sont gérées logiquement. Les demandes d'envoi vers une même SIM sont mises en file afin d'éviter de solliciter simultanément le modem avec plusieurs envois. MTN et Orange peuvent avoir chacune leur file.

## Compilation

1. Installer Flutter stable et Android Studio.
2. Décompresser le ZIP.
3. Ouvrir un terminal dans le dossier du projet.
4. Générer les fichiers Android standards si besoin :
   `flutter create --platforms=android .`
5. Vérifier que le package Android correspond à `com.example.camsms_campaign_manager` et que le fichier Kotlin fourni est placé dans :
   `android/app/src/main/kotlin/com/example/camsms_campaign_manager/MainActivity.kt`
6. Exécuter :
   `flutter pub get`
   `flutter analyze`
   `flutter run`
7. Générer un APK :
   `flutter build apk --release`

APK attendu :
`build/app/outputs/flutter-apk/app-release.apk`

## Précautions

- Android demande les autorisations READ_CONTACTS pour consulter le répertoire, SEND_SMS et READ_PHONE_STATE pour la passerelle SMS.
- La publication sur Google Play est soumise à des règles strictes concernant les permissions SMS ; une installation privée peut être nécessaire.
- Les préfixes camerounais sont seulement indicatifs : la portabilité peut rendre l'opérateur estimé incorrect. Vérifier les SIM et faire un essai avec quelques numéros consentants.
- Les numéros d'opérateurs non identifiés sont dirigés vers Orange par défaut, conformément au cahier des charges, mais le numéro peut ne pas être joignable par cette SIM.
- Les SMS sont facturés selon les forfaits et tarifs des SIM.
- N'envoyer que des messages sollicités, à des destinataires ayant donné leur accord. Prévoir un mécanisme de désinscription adapté aux campagnes commerciales.
- La base SQLite est locale. Une sauvegarde/export de base et une restauration guidée restent à développer.
