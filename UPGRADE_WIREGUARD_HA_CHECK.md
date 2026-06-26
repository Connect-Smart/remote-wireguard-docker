# WireGuard Add-on: Home Assistant Updates Integratie

Deze guide legt uit hoe je het WireGuard add-on kunt uitbreiden om add-on updates op te halen en naar de Remote Portal te sturen.

## Probleem

Add-on updates zijn **NIET** beschikbaar via de normale Home Assistant REST API (`/api/*`), maar **WEL** via:
- Supervisor API (`/supervisor/*`)
- Het `ha` CLI commando

## Oplossing

Het WireGuard add-on krijgt Supervisor toegang en haalt periodiek de volledige HA status op (Core, OS, Supervisor, Add-ons) en stuurt deze naar de portal.

---

## Stap 1: Update `config.yaml`

Voeg de volgende regels toe aan je `config.yaml`:

```yaml
name: Connect-Smart WG Client
version: 1.5.0  # ← Verhoog versie
slug: cs_wg_client
description: Connect-Smart WireGuard client for Remote Portal
url: https://github.com/Connect-Smart/remote-wireguard/
arch:
  - aarch64
  - amd64
  - armv7
apparmor: true
host_network: true
init: false
hassio_role: manager          # ← NIEUW: Toegang tot ha commando
hassio_api: true              # ← NIEUW: Supervisor API toegang
homeassistant_api: true       # ← NIEUW: HA Core API toegang
privileged:
  - NET_ADMIN
  - SYS_MODULE
devices:
  - /dev/net/tun
map:
  - type: config
    read_only: false
options:
  enrollment_token: ""
  advanced:
    portal_url: "https://remote.connect-smart.nl"
    verify_ssl: true
schema:
  enrollment_token: str
  advanced:
    portal_url: str?
    verify_ssl: bool?
  log_level: list(trace|debug|info|notice|warning|error|critical)?
  monitor_target: str?
  monitor_interval: int?
```

**Belangrijke toevoegingen:**
- `hassio_role: manager` - Geeft toegang tot het `ha` CLI commando
- `hassio_api: true` - Toegang tot Supervisor API
- `homeassistant_api: true` - Toegang tot Home Assistant Core API

---

## Stap 2: Maak een status check script

Maak een nieuw bestand `check_ha_status_api.sh`:

```bash
#!/usr/bin/with-contenv bashio

# Configuratie ophalen
PORTAL_URL=$(bashio::config 'advanced.portal_url' 'https://remote.connect-smart.nl')
ENROLLMENT_TOKEN=$(bashio::config 'enrollment_token')
VERIFY_SSL=$(bashio::config 'advanced.verify_ssl' 'true')

# Het enrollment_token wordt automatisch meegegeven bij de initiële setup van het add-on
# Dit token is uniek per client en geeft toegang tot de portal API

# SSL verificatie instelling
if [ "$VERIFY_SSL" = "false" ]; then
    CURL_OPTS="-k"
else
    CURL_OPTS=""
fi

bashio::log.info "Ophalen Home Assistant status..."

# Haal alle status informatie op
CORE_INFO=$(ha core info --raw-json 2>/dev/null || echo '{}')
OS_INFO=$(ha os info --raw-json 2>/dev/null || echo '{}')
SUPERVISOR_INFO=$(ha supervisor info --raw-json 2>/dev/null || echo '{}')

# Gebruik 'ha apps' (nieuwere versie) of fallback naar 'ha addons' (oudere versie)
ADDONS_INFO=$(ha apps --raw-json 2>/dev/null || ha addons --raw-json 2>/dev/null || echo '{"data":{"addons":[],"apps":[]}}')

# Parse updates
CORE_UPDATE=$(echo "$CORE_INFO" | jq -r '.data.update_available // false')
CORE_VERSION=$(echo "$CORE_INFO" | jq -r '.data.version // "unknown"')
CORE_LATEST=$(echo "$CORE_INFO" | jq -r '.data.version_latest // "unknown"')

OS_UPDATE=$(echo "$OS_INFO" | jq -r '.data.update_available // false')
OS_VERSION=$(echo "$OS_INFO" | jq -r '.data.version // "unknown"')
OS_LATEST=$(echo "$OS_INFO" | jq -r '.data.version_latest // "unknown"')

SUPERVISOR_UPDATE=$(echo "$SUPERVISOR_INFO" | jq -r '.data.update_available // false')
SUPERVISOR_VERSION=$(echo "$SUPERVISOR_INFO" | jq -r '.data.version // "unknown"')
SUPERVISOR_LATEST=$(echo "$SUPERVISOR_INFO" | jq -r '.data.version_latest // "unknown"')

# Parse add-on updates (support both 'apps' and 'addons' for compatibility)
ADDON_UPDATES=$(echo "$ADDONS_INFO" | jq '
  [
    (.data.apps // .data.addons // [])[]
    | select(.update_available == true)
    | {
        name: .name,
        slug: .slug,
        current: .version,
        latest: .version_latest,
        installed: .installed,
        icon: .icon
      }
  ]')

# Bouw JSON payload
PAYLOAD=$(jq -n \
  --argjson core_update "$CORE_UPDATE" \
  --arg core_version "$CORE_VERSION" \
  --arg core_latest "$CORE_LATEST" \
  --argjson os_update "$OS_UPDATE" \
  --arg os_version "$OS_VERSION" \
  --arg os_latest "$OS_LATEST" \
  --argjson supervisor_update "$SUPERVISOR_UPDATE" \
  --arg supervisor_version "$SUPERVISOR_VERSION" \
  --arg supervisor_latest "$SUPERVISOR_LATEST" \
  --argjson addon_updates "$ADDON_UPDATES" \
  '{
    updates: {
      core: (if $core_update then {current: $core_version, latest: $core_latest} else null end),
      os: (if $os_update then {current: $os_version, latest: $os_latest} else null end),
      supervisor: (if $supervisor_update then {current: $supervisor_version, latest: $supervisor_latest} else null end),
      addons: $addon_updates
    },
    timestamp: now
  }')

bashio::log.info "Sturen status naar portal..."

# Stuur naar portal
RESPONSE=$(curl -s -w "\n%{http_code}" $CURL_OPTS -X POST \
  "${PORTAL_URL}/api/ha-status/push" \
  -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n-1)

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    bashio::log.info "Status succesvol verstuurd naar portal"
else
    bashio::log.warning "Fout bij versturen status: HTTP $HTTP_CODE"
    bashio::log.warning "Response: $RESPONSE_BODY"
fi
```

Maak het script uitvoerbaar:
```bash
chmod +x check_ha_status_api.sh
```

---

## Stap 3: Integreer in je run.sh

Voeg aan het einde van je `run.sh` een achtergrond taak toe die periodiek de status checked:

```bash
#!/usr/bin/with-contenv bashio

# ... je bestaande WireGuard setup code ...

# Start status check in achtergrond (elke 5 minuten)
bashio::log.info "Starting HA status monitor..."
(
  while true; do
    sleep 300  # 5 minuten
    /check_ha_status_api.sh
  done
) &

# ... rest van je code ...
```

**Of** voeg het toe aan je bestaande monitor loop als je die al hebt.

---

## Stap 4: Update je Dockerfile

Zorg dat het check_ha_status_api.sh script wordt gekopieerd:

```dockerfile
FROM homeassistant/amd64-base:latest

# Installeer dependencies
RUN apk add --no-cache \
    wireguard-tools \
    iptables \
    ip6tables \
    curl \
    jq \
    bash

# Kopieer scripts
COPY run.sh /
COPY check_ha_status_api.sh /

# Maak uitvoerbaar
RUN chmod +x /run.sh /check_ha_status_api.sh

CMD ["/run.sh"]
```

---

## Stap 5: Data formaat naar Portal

De data die naar de portal wordt gestuurd heeft dit formaat:

```json
{
  "updates": {
    "core": {
      "current": "2024.1.0",
      "latest": "2024.1.5"
    },
    "os": {
      "current": "11.0",
      "latest": "11.2"
    },
    "supervisor": {
      "current": "2024.01.0",
      "latest": "2024.01.1"
    },
    "addons": [
      {
        "name": "Zigbee2MQTT",
        "slug": "zigbee2mqtt",
        "current": "1.40.1",
        "latest": "1.40.2",
        "installed": true,
        "icon": "zigbee2mqtt/icon.png"
      }
    ]
  },
  "timestamp": 1234567890
}
```

---

## Portal Wijzigingen

✅ **De portal is al bijgewerkt en klaar!**

**Geïmplementeerd endpoint: `POST /api/ha-status/push`**
- ✅ Accepteert de status data van het add-on
- ✅ Slaat op in de `ha_status` tabel
- ✅ Authenticeert via enrollment_token of ha_token
- ✅ UI toont add-on updates automatisch in de HA Status modal

**Authenticatie:**
Het endpoint accepteert zowel de `enrollment_token` als de `ha_token` van de client via de `Authorization: Bearer <token>` header.

---

## Testen

### Stap 1: Test het script handmatig

Voor je het add-on opnieuw bouwt, test eerst het script handmatig in een draaiend add-on:

```bash
# SSH naar het add-on
docker exec -it addon_xxxx_cs_wg_client /bin/bash

# Voer het script handmatig uit
/check_ha_status_api.sh
```

Je zou output moeten zien zoals:
```
[INFO] Ophalen Home Assistant status...
[INFO] Sturen status naar portal...
[INFO] Status succesvol verstuurd naar portal
```

### Stap 2: Controleer in de portal

1. Log in op de Remote Portal
2. Klik op het **HA Status** icoon bij je client (als er updates zijn)
3. Je zou de add-on updates moeten zien in de "Beschikbare Updates" sectie

### Stap 3: Bouw en deploy het add-on

1. **Build** het add-on opnieuw
2. **Update** de add-on in Home Assistant
3. **Check logs** van het add-on:
   ```
   ha addons logs cs_wg_client
   ```
4. **Kijk of** de status na 5 minuten wordt verstuurd
5. **Bekijk** in de portal of de add-on updates verschijnen

### Stap 4: Test met curl (optioneel)

Je kunt ook direct het portal endpoint testen:

```bash
curl -X POST "https://remote.connect-smart.nl/api/ha-status/push" \
  -H "Authorization: Bearer YOUR_ENROLLMENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "updates": {
      "core": {"current": "2024.1.0", "latest": "2024.1.5"},
      "addons": [
        {
          "name": "Test Addon",
          "slug": "test-addon",
          "current": "1.0.0",
          "latest": "1.0.1"
        }
      ]
    },
    "timestamp": 1234567890
  }'
```

Als het succesvol is, krijg je een response:
```json
{
  "status": "success",
  "message": "HA status updated for ClientName",
  "update_count": 2
}
```

---

## Troubleshooting

### "ha: command not found"
- Controleer of `hassio_role: manager` in config.yaml staat
- Rebuild het add-on

### "Permission denied"
- Controleer of `hassio_api: true` in config.yaml staat
- Controleer of script uitvoerbaar is (`chmod +x`)

### "Cannot connect to supervisor"
- Controleer of `SUPERVISOR_TOKEN` environment variabele beschikbaar is
- Check add-on logs voor errors

### HTTP 401/403 van portal
- Controleer of enrollment_token correct is
- Check portal logs voor authenticatie errors

### Lege addons array (0 updates terwijl er wel updates zijn)
- **Oorzaak**: In nieuwere HA versies is `ha addons` deprecated en vervangen door `ha apps`
- **Oplossing**: Het script probeert automatisch beide commando's
- **Debug**: Test handmatig:
  ```bash
  ha apps --raw-json | jq '.data.apps[] | select(.update_available == true)'
  ```
- Als `ha apps` niet werkt, probeer:
  ```bash
  ha addons --raw-json | jq '.data.addons[] | select(.update_available == true)'
  ```

---

## Beveiliging

⚠️ **Let op:**
- `hassio_role: manager` geeft veel privileges (kan add-ons installeren/verwijderen)
- Dit script **leest alleen**, maar de rol geeft ook schrijftoegang
- Zorg dat je enrollment_token veilig is

---

---

## HA Backup naar Remote Portal (Google Storage)

### Hoe het werkt

Het add-on maakt periodiek een volledige Home Assistant backup aan en uploadt deze via de WireGuard tunnel naar de Remote Portal server (10.8.0.1). De portal stuurt de backup vervolgens door naar Google Storage.

```
[Home Assistant Add-on]
        |
        | 1. POST /supervisor/backups/new/full
        v
[Supervisor API]  →  /backup/<slug>.tar
        |
        | 2. curl multipart POST
        v
[Portal server: http://10.8.0.1/api/backup/upload]
        |
        | 3. upload
        v
[Google Cloud Storage]
```

### Configuratie-opties

Voeg de volgende opties toe aan de add-on configuratie:

```yaml
advanced:
  backup_enabled: true          # Backup aan/uit (standaard: true)
  backup_interval_hours: 24     # Interval in uren (standaard: 24)
  backup_retain: 3              # Aantal lokale backups bewaren (standaard: 3)
```

### Bestanden

| Bestand | Beschrijving |
|---|---|
| `services.d/ha-backup/run` | Service loop, start 5 min na boot |
| `services.d/ha-backup/create_backup.sh` | Maakt backup en uploadt naar portal |
| `services.d/ha-backup/log/run` | Logging service |

### Upload formaat

Het script uploadt via multipart form-data:

```
POST {portal_url}/api/backup/upload
Authorization: Bearer <enrollment_token>
Content-Type: multipart/form-data

backup=<bestand.tar>
slug=<backup-slug>
```

### Lokale opruiming

Na een succesvolle upload worden oude lokale backups met de naam `remote-portal-backup` automatisch opgeruimd. Alleen de laatste N backups (instelbaar via `backup_retain`) worden bewaard.

### Testen

Trigger handmatig een backup via de add-on container:

```bash
docker exec -it addon_xxxx_cs_wg_client /bin/bash
/etc/services.d/ha-backup/create_backup.sh
```

### Vereiste portal endpoint

De portal server moet het volgende endpoint implementeren:

```
POST /api/backup/upload
Authorization: Bearer <enrollment_token>
Body: multipart/form-data  (velden: backup, slug)
```

Response bij succes:
```json
{ "status": "ok" }
```

---

## Changelog

### Portal Side (Remote Portal)
- ✅ Nieuw endpoint: `POST /api/ha-status/push` geïmplementeerd
- ✅ Authenticatie via enrollment_token of ha_token
- ✅ Add-on updates worden automatisch getoond in HA Status modal
- ✅ Support voor Core, OS, Supervisor en Add-on updates
- ✅ Nieuw endpoint: `POST /api/backup/upload` vereist voor backup ontvangst + Google Storage upload

### WireGuard Add-on v1.5.10
- ✨ Supervisor API toegang toegevoegd
- ✨ Add-on updates monitoring
- ✨ Periodieke status push naar portal (elke 5 minuten)
- ✨ Automatische HA backup naar Remote Portal / Google Storage
- ✨ Instelbaar backup interval, retentie en aan/uit schakelaar
- ✅ `backup` map gemount voor toegang tot backup bestanden
- 🔒 Hassio role manager voor `ha` commando toegang
- 📊 Volledige HA status reporting (Core, OS, Supervisor, Add-ons, Repairs)
