# GrokPatrol mobile

La console web di `../grokdog` in Flutter, per iOS e Android: dashboard con la mappa 3D, automazioni, missioni, report e impostazioni.

```bash
flutter pub get
flutter run                 # sul telefono o simulatore collegato
flutter test                # unit e widget test
flutter test integration_test/app_tour_test.dart -d <simulatore>   # giro completo con la mappa vera
```

## La mappa 3D

È la stessa scena three.js della web app e gira in una WebView (`assets/map/`). Dart le passa dati e comandi, lei risponde con i tocchi:
vedi `lib/features/dashboard/map_view.dart` (lato Dart) e `map_src/scene.ts` (lato scena).

`assets/map/scene.js` è generato e va ricostruito quando cambia `map_src/scene.ts` o la pianta in `../grokdog/src/lib/floorplan.ts`, che la scena importa da lì:

```bash
cd map_src
npm install
npm run check    # controllo dei tipi
npm run build    # scrive ../assets/map/scene.js
```

## La barra in basso

Da iOS 26 è il `UITabBar` di sistema con il Liquid Glass vero (`ios/Runner/GlassTabBar.swift`, `lib/shared/glass_tab_bar.dart`): Flutter non ce l'ha e un'imitazione non rifrangerebbe la mappa. Le pagine scorrono sotto la barra, quindi nelle liste a scorrimento il margine in fondo viene da `pagePadding()`. Su Android e sulle versioni precedenti di iOS resta la barra opaca di Flutter.

## Dati

L'app ha due modi, e la barra in alto dice sempre in quale è (`Demo data`, `Live`, `Offline`).

- **Demo**: dati finti, gli stessi della web app. `lib/data/mock_data.dart` ha gli stessi valori di `../grokdog/src/lib/mock.ts`. Le automazioni create dall'operatore restano sul telefono (`shared_preferences`).
- **Live**: l'app parla con `../admin/backend` dall'avatar → Server. Tutte le pagine leggono da `ConsoleStore` (`lib/data/console_store.dart`), che in live si riempie da HTTP e dal websocket `/ws/console`; se il websocket cade passa a `/api/poll` e si ricollega da solo.

L'indirizzo si scrive in app, oppure si precompila in compilazione (l'IP del Mac cambia da una rete all'altra):

```bash
flutter run --dart-define=RONDA_URL=http://192.168.5.55:8000
```

Sulla rete locale o da `localhost` il server non chiede nulla; attraverso un tunnel chiede il PIN (`RONDA_PIN`), che l'app conserva nel portachiavi del telefono.

Il mapping dal server alla console è in `lib/data/ronda/live_view.dart`, compresa la conversione fra metri del sito e pixel della pianta (`SiteTransform`).

### Video e telecamere

Il video arriva da `/api/cameras/<id>/stream` (MJPEG, `lib/data/ronda/mjpeg.dart`). La telecamera manda fotogrammi veloci solo finché qualcuno guarda; altrimenti un'anteprima piccola al secondo.

Un telefono diventa una telecamera da avatar → Settings → Cameras → **Add a phone**: la pagina si apre nel browser, su https, e il telefono entra con un canale tutto suo (`phone-xxxx`), separato da quelli del simulatore.

### Prove con il backend vero

```bash
cd .. && DOG=mujoco ./admin/run.sh   # in un terminale
cd .. && ./sim.sh                    # in un altro: il cane in MuJoCo
flutter test integration_test/live_server_test.dart -d <simulatore> --dart-define=RONDA_URL=http://localhost:8000
```

Con `XAI_API_KEY` in `../secrets/.env` la prova chiama Grok davvero e consuma credito.

`integration_test/live_reconnect_test.dart` prova la caduta del server: stampa `SERVER:OFF` e `SERVER:ON`, e uno script esterno deve spegnerlo e riaccenderlo in quei momenti.

## Links from Telegram

Gli alert su Telegram hanno un bottone che apre una pagina https del backend; la pagina rimanda allo schema dell'app:

- `grokpatrol://open/mission/<missionId>` (es. `grokpatrol://open/mission/m-348f5`): apre il dettaglio della missione.
- `grokpatrol://open/event/<eventId>` (es. `grokpatrol://open/event/ev-1f3da`): apre la missione partita da quell'evento; se non ce n'è una, la dashboard con le notifiche.

Lo schema è registrato in `ios/Runner/Info.plist` (`CFBundleURLTypes`, `FlutterDeepLinkingEnabled`) e in `android/app/src/main/AndroidManifest.xml` (intent-filter `VIEW`/`BROWSABLE` con `scheme="grokpatrol"`, `host="open"`). Flutter toglie schema e host e passa al Navigator la rotta `/mission/<id>`: a freddo diventa la pila `[schede, missione]` (`onGenerateInitialRoutes` in `lib/app.dart`), con l'app aperta un push sopra le schede (`onGenerateRoute`). Il parsing è in `lib/core/deep_link.dart` (test in `test/deep_link_test.dart`), la pagina che cerca la missione in `lib/features/missions/deep_link_page.dart`.

La missione si cerca nei dati del server: se il collegamento è ancora in corso si aspetta, se non si trova si va in Missions con un messaggio. In modalità Demo il link dice che serve il server live.

Per provarlo, con l'app collegata al server:

```bash
# simulatore iOS
xcrun simctl openurl booted "grokpatrol://open/mission/m-xxxxx"
# Android (emulatore o telefono via adb)
adb shell am start -a android.intent.action.VIEW -d "grokpatrol://open/mission/m-xxxxx"
```

Provarlo sia con l'app chiusa (avvio a freddo) sia con l'app aperta.

## Differenze dalla web app

Pensate per il telefono:

- La sidebar è la barra in basso, in Liquid Glass su iOS 26+; profilo, card GrokBot e impostazioni si aprono dall'avatar in alto.
- Le tabelle di missioni, automazioni e attività sono card o liste; i menu a tendina sono fogli dal basso.
- Sulla dashboard si vede una cosa alla volta: seguire un cane o aprire una telecamera chiude il pannello dei bot, perché le card non ci starebbero insieme.
- Il controllo manuale si fa con i tasti a schermo, non c'è la sezione Shortcuts della tastiera.
- Export: apre la condivisione del telefono. Il report del giorno è un file HTML da aprire e stampare o salvare in PDF, non si apre la stampa da solo.

Solo in app, perché `admin/web` è collegata al backend solo per cane e telecamere:

- `E-stop`, attivo in live anche durante la guida.
- Stato del collegamento, allarmi in arrivo con la foto, rapporto di fine turno, comandi di allarme e ronda da `Controls`.

Non portati: input vocale. I percorsi del sito e la calibrazione si gestiscono dalla console sul Mac. Senza app aperta non arrivano notifiche.
