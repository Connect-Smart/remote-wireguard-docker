## 1.5.15

- Foutmeldingen bij mislukte backup worden nu als notificatie naar de portal gestuurd via `POST /api/notifications/push` (levels: `error`, `warning`, `info`).
- Succesvolle uploads sturen ook een bevestigingsnotificatie naar de portal.

## 1.5.11

- Backup upload gebruikt nu de ingestelde `portal_url` in plaats van het hardgecodeerde `10.8.0.1`.
- Logregel gecorrigeerd zodat de daadwerkelijke upload-URL wordt getoond.

## 1.5.10

- Automatische HA backup toegevoegd: maakt periodiek een volledige backup aan via de Supervisor API en uploadt deze naar de portal (`POST /api/backup/upload`).
- Portal stuurt de backup door naar Google Storage.
- Nieuwe configuratie-opties: `advanced.backup_enabled`, `advanced.backup_interval_hours`, `advanced.backup_retain`.
- `backup` map gemount zodat het add-on toegang heeft tot backup bestanden.
- Service herstart niet meer elke 5 minuten bij een mislukte backup upload.
- `portal_url` werd niet correct opgepikt uit `advanced.portal_url`; dit is gecorrigeerd in `config.sh`.
- HA status monitor rapporteert nu ook repairs/issues en unhealthy-meldingen vanuit de Supervisor resolution API.

## 1.4.12

- `enrollment_token` is nu verplicht in het schema zodat de UI het veld afdwingt.
- Standaardwaarden teruggezet voor `portal_url` (`https://remote.connect-smart.nl`) en `verify_ssl`.

## 1.4.11

- Vertaalteksten voor `portal_url` gecorrigeerd naar de juiste standaard-URL `https://remote.connect-smart.nl`.
- Standaardwaarden voor `portal_url` en `verify_ssl` verwijderd uit `options` zodat ze optioneel blijven.

## 1.4.1

- Standaard `portal_url` ingesteld op `https://remote.connect-smart.nl`.
- Vertalingen toegevoegd (NL/EN) voor alle configuratievelden.

## 1.4.0

- `log_level` verwijderd uit de standaard `options`, maar blijft beschikbaar als optionele schema-instelling.

## 1.3.9

- `10-log-level.sh` krijgt uitvoerrechten; Dockerfile zet deze permissies zodat log-level configuratie wordt toegepast.

## 1.3.8

- Toegevoegde `log_level`-optie waarmee het add-on logniveau rechtstreeks via de configuratie kan worden ingesteld.
- Statusservice wacht nu net zo lang als `monitor_interval` voordat hij `wg show cswg0` uitvoert, zodat logging gesynchroniseerd blijft met de watchdog.

## 1.3.7

- Statusservice vraagt nu expliciet `wg show cswg0` op zodat de logging alleen de add-oninterface toont en geen andere WireGuard-configuraties uitleest.

## 1.3.6

- WireGuard-interface hernoemd naar `cswg0` met bijbehorend configuratiebestand zodat bestaande `wg0`-configuraties op het systeem niet worden overschreven.
- Documentatie bijgewerkt om de nieuwe bestandsnaam en interface duidelijk te maken.

## 1.3.5

- Watchdog telt nu mislukte pings; na 5 opeenvolgende fouten stopt de add-on zichzelf zodat de Home Assistant Supervisor automatisch een herstart afhandelt.
- Documentatie verduidelijkt dit gedrag.

## 1.3.4

- `monitor_target` en `monitor_interval` zitten nu onder *Ongebruikte optionele configuratieopties tonen* zodat standaardgebruikers ze niet zien, maar ze wel eenvoudig bereikbaar blijven.

## 1.3.3

- `monitor_target` en `monitor_interval` zijn nu verborgen opties zodat de standaardwaarden intact blijven terwijl geavanceerde gebruikers ze nog via `options.json` kunnen tweaken.
- Documentatie verduidelijkt hoe deze instellingen nu worden beheerd.

## 1.3.2

- Watchdog staat nu altijd aan; de optie `monitor_enabled` is verwijderd om onbedoeld uitschakelen te voorkomen.
- Configuratie bevat alleen nog het doel en interval, documentatie bijgewerkt om dit te weerspiegelen.

## 1.3.1

- Beschrijving en metadata geüpdatet zodat de add-on duidelijk als Connect-Smart Remote Portal-client wordt aangeduid.
- Nieuwe Connect-Smart logo- en icoonbestanden opgenomen voor de Home Assistant store.

## 1.3.0

- Watchdog haalt nu bij connectiviteitsverlies de WireGuard-configuratie opnieuw op bij de portal en past wijzigingen live toe via `wg syncconf`, zonder de interface te herstarten.
- Documentatie uitgewerkt voor de benodigde `trusted_proxies`-instelling in Home Assistant.

## 1.2.3

- Watchdog stuurt nu pings via de WireGuard-interface, voert direct na een herstart meerdere probes uit en wacht kort voordat de volgende controle plaatsvindt zodat de tunnel opnieuw verkeer kan verzenden.

## 1.2.2

- Watchdog herstart nu eerst de `wireguard_client` s6-service; alleen wanneer dat faalt wordt teruggevallen op `wg-quick` zodat een volledige tunnel-reset wordt afgedwongen.

## 1.2.1

- WireGuard-watchdog gebruikt nu dezelfde userspace-implementatie als de hoofdservice, zodat een herstart ook daadwerkelijk de tunnel opnieuw kan opbouwen.

## 1.2.0

- WireGuard-watchdog toegevoegd die standaard `10.8.0.1` elke 30 seconden pingt en de tunnel automatisch herstart wanneer het doel onbereikbaar is.
- Nieuwe configuratie-opties (`monitor_enabled`, `monitor_target`, `monitor_interval`) om de watchdog te sturen.

## 1.1.3

- Voegt automatisch `PersistentKeepalive = 25` toe aan de WireGuard-peerconfiguratie zodat de client na een serverherstart vanzelf opnieuw verbindt.

## 1.1.0

- Ondersteuning voor Remote Portal installatietokens toegevoegd.
- WireGuard-configuratie wordt nu automatisch opgehaald via het publieke enrollment-endpoint.
- Nieuwe configuratie-opties: `portal_url`, `enrollment_token` en `verify_ssl`.
