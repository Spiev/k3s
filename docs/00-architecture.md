# Architektur-Übersicht

---

## Hardware

| Node | Rolle | RAM | NVMe | Status |
|---|---|---|---|---|
| Raspi 5 "neu" | k3s Server-Node (Control Plane) | 8 GB | 256 GB | k3s |
| Raspi 5 "alt" | k3s Agent-Node (Workloads + Storage) | 8 GB | 2 TB | Docker → k3s (nach Migration) |

Beide Nodes sind baugleich (Raspberry Pi 5, 8 GB RAM). Der alte Raspi hat dank 2 TB NVMe deutlich mehr Speicher — er wird der primäre Longhorn-Speicherknoten für große Volumes (Immich, Paperless).

---

## Gesamtbild (Zielzustand)

```
                           Internet
                               │
                        ┌──────▼──────┐
                        │   Router    │  Port 80/443
                        └──────┬──────┘
                               │
               ┌───────────────▼──────────────────────────────────────┐
               │                   k3s Cluster                        │
               │                                                      │
               │  ┌─────────────────────┐  ┌──────────────────────┐  │
               │  │  Server-Node        │  │  Agent-Node          │  │
               │  │  Raspi 5 "neu"      │  │  Raspi 5 "alt"       │  │
               │  │  256 GB NVMe        │  │  2 TB NVMe           │  │
               │  │                     │  │                      │  │
               │  │  Control Plane      │  │  [freshrss]          │  │
               │  │  Traefik (Ingress)  │  │  [seafile]           │  │
               │  │  CoreDNS            │  │  [immich]            │  │
               │  │  Longhorn Engine    │  │  [paperless]         │  │
               │  │                     │  │  [homeassistant] ←┐  │  │
               │  └─────────────────────┘  │  [mosquitto]      │  │  │
               │                           └───────────────────┼──┘  │
               │                                               │      │
               │         Longhorn repliziert Volumes           │      │
               │         zwischen beiden Nodes  ←──────────────┘      │
               │                                                      │
               └──────────────────────────────────────────────────────┘
                                                    │
                                            Zigbee USB-Dongle
                                            steckt am Agent-Node
```

---

## Netzwerk: Wie eine Anfrage durch den Cluster fließt

### Während der Migration (Übergangsphase)

nginx bleibt der externe Einstiegspunkt — er kennt die öffentliche IP, hat die Zertifikate, und alle Docker-Services laufen noch dahinter. Für k3s-Services leitet nginx einfach an den neuen Raspi weiter:

```
Browser: https://freshrss.example.com
         │
         ▼
    Router → nginx (alter Raspi, :443)
         │  TLS-Terminierung, Rate Limiting, Security Headers, Fail2ban
         │  proxy_pass → http://raspi5-ip:80
         ▼
    Traefik (neuer Raspi, :80)
         │  prüft: welche Domain? → IngressRoute-Regeln
         ▼
    Service "freshrss" (ClusterIP, cluster-intern)
         │
         ▼
    Pod "freshrss-xxxx"
         │
         ▼
    PVC → Longhorn Volume → NVMe
```

Zwei Proxy-Hops, aber saubere Aufgabenteilung: nginx = externe Sicherheitsschicht, Traefik = internes Kubernetes-Routing. Kein DNS-Wechsel nötig, beide Raspis laufen unabhängig.

### Nach vollständiger Migration (Zielzustand)

Wenn alle Services auf k3s laufen, kann nginx konsolidiert werden:

```
Browser: https://freshrss.example.com
         │
         ▼
    Router → Traefik (neuer Raspi, :443)
         │  TLS via cert-manager (Let's Encrypt)
         │  Rate Limiting + Security Headers via Traefik Middleware
         ▼
    Service → Pod → Longhorn → NVMe
```

Traefik übernimmt dann alles was nginx heute tut. Fail2ban kann als DaemonSet im Cluster laufen oder entfällt zugunsten von Traefik-nativen Rate Limits.

**Diese Entscheidung muss jetzt nicht getroffen werden.** Erst wenn alle Services migriert sind, macht ein Vergleich Sinn: nginx ist battle-tested und konfiguriert, Traefik ist k8s-nativer.

---

## Kubernetes-Objekte je Service

Jeder migrierte Service besteht aus denselben Bausteinen:

```
Namespace
  ├── Deployment          ← "Starte N Kopien dieses Containers"
  │     └── Pod(s)        ← der eigentliche Container
  ├── Service             ← stabiler interner Netzwerkendpunkt
  ├── PersistentVolumeClaim (PVC)  ← "Ich brauche X GB Storage"
  │     └── PersistentVolume (PV)  ← von Longhorn bereitgestellt
  ├── ConfigMap           ← Konfiguration (kein Secret)
  ├── SealedSecret        ← verschlüsseltes Secret (im Git speicherbar)
  └── IngressRoute        ← "Diese Domain geht zu diesem Service"
```

Beispiel FreshRSS (einfachster Fall, 1 Container):
```
Namespace: freshrss
  ├── Deployment: freshrss (1 Pod, Image: lscr.io/linuxserver/freshrss)
  ├── Service: freshrss (ClusterIP → Port 80)
  ├── PVC: freshrss-config (5Gi, Longhorn)
  └── IngressRoute: freshrss.example.com → Service freshrss
```

Beispiel Seafile (2 Container, Service-to-Service):
```
Namespace: seafile
  ├── Deployment: seafile (seafileltd/seafile-mc)
  │     └── spricht MariaDB an via: mariadb.seafile.svc.cluster.local
  ├── Deployment: mariadb
  ├── Service: seafile (ClusterIP)
  ├── Service: mariadb (ClusterIP, nur cluster-intern)
  ├── PVC: seafile-data
  ├── PVC: mariadb-data
  ├── SealedSecret: seafile-secrets (DB-Passwort, SECRET_KEY)
  └── IngressRoute: seafile.example.com → Service seafile
```

---

## Storage: Longhorn im Detail

```
Pod schreibt Daten
       │
       ▼
  PVC (Anforderung: "5Gi, ReadWriteOnce")
       │  Longhorn erfüllt die Anforderung
       ▼
  Longhorn Volume
  ┌───────────────────────────────────────────────────┐
  │  Engine (koordiniert Replicas)                    │
  │  ┌─────────────┐                                  │
  │  │  Replica 1  │ → 256 GB NVMe (Server-Node)      │  ← jetzt
  │  └─────────────┘                                  │
  │  ┌─────────────┐                                  │
  │  │  Replica 2  │ → 2 TB NVMe  (Agent-Node)        │  ← nach Migration
  │  └─────────────┘                                  │
  └───────────────────────────────────────────────────┘
```

Im Single-Node-Betrieb: `numberOfReplicas: 1` — Daten liegen einmal auf der 256 GB NVMe.
Sobald Agent-Node joined: `numberOfReplicas: 2` → automatische Replikation auf 2 TB NVMe.

**Storage-Planung mit 2 Nodes:**
Longhorn kann über Node-Tags steuern wo Volumes angelegt werden. Große Volumes (Immich-Bibliothek, Paperless-Dokumente) wandern bevorzugt auf den Agent-Node mit 2 TB. Kleine Volumes (FreshRSS, Seafile) können überall liegen.

**Backup-Strategie (Single-Node):**
```
Longhorn Volume
       │  Snapshot
       ▼
  Longhorn Backup → S3-kompatibles Ziel (z.B. Backblaze B2)
                    oder Restic → externe HDD (wie docker-runtime)
```

---

## GitOps: Wie Änderungen in den Cluster kommen

```
  Lokaler Laptop
       │  git push
       ▼
  GitHub Repository (dieses Repo)
       │
       │  Flux CD (läuft im Cluster) pollt alle 1 Minute
       ▼
  Flux erkennt Änderung → wendet Manifeste an
       │
       ▼
  k3s Cluster (Zielzustand = Git-Zustand)
```

Kein Webhook nötig. Flux pulled aktiv — funktioniert auch hinter NAT ohne öffentliche IP für den Cluster-Eingang.

**Sealed Secrets im GitOps-Flow:**
```
Laptop: kubectl create secret ... | kubeseal → SealedSecret.yaml
        git commit + push
        ↓
Flux deployed SealedSecret in den Cluster
        ↓
Sealed Secrets Controller entschlüsselt → echtes Secret im Cluster
        ↓
Pod liest Secret (Passwort, API-Key etc.)
```

---

## Aktueller Stand vs. Zielzustand

```
Heute                               Ziel (nach Migration)
──────────────────────────────      ──────────────────────────────────────
Raspi 5 "neu" (256 GB)              Raspi 5 "neu": k3s Server-Node
  └── k3s (leer)                      └── Control Plane, Traefik, CoreDNS

Raspi 5 "alt" (2 TB)                Raspi 5 "alt": k3s Agent-Node
  └── Docker                           └── FreshRSS
        └── FreshRSS                   └── Seafile
        └── Immich                     └── Immich        (2 TB NVMe)
        └── Paperless                  └── Paperless     (2 TB NVMe)
        └── Home Assistant             └── Home Assistant (hostNetwork +
        └── Teslamate                  └── Teslamate      USB nodeAffinity)
        └── Pi-hole                    └── Pi-hole
        └── Nginx Proxy                └── Mosquitto
        └── Mosquitto                  └── Matter Hub
        └── Matter Hub
```

Beide Pis sind baugleich (Raspi 5, 8 GB RAM) — eine vollständige Migration auf k3s ist realistisch. Home Assistant läuft auf dem Agent-Node mit `hostNetwork: true` und `nodeAffinity` für den Zigbee-Dongle. nginx bleibt vorerst als externer Proxy, kann später durch Traefik abgelöst werden.

---

## Komponentenübersicht

| Komponente | Typ | Zweck | Wo |
|---|---|---|---|
| k3s | Kubernetes-Distribution | Cluster-Steuerung | Raspi 5 |
| nginx | Reverse Proxy | Externer Einstieg, TLS, Fail2ban (läuft auf altem Raspi) | Docker |
| Traefik | Ingress Controller | Internes k8s-Routing (später ggf. nginx ablösen) | k3s built-in |
| CoreDNS | DNS | Cluster-internes DNS | k3s built-in |
| Flannel | CNI | Pod-Netzwerk | k3s built-in |
| Longhorn | Storage | Persistente Volumes | Installiert via kubectl |
| cert-manager | Controller | Let's Encrypt TLS — erst nötig wenn Traefik nginx ablöst | Später |
| Flux CD | GitOps | Automatisches Deployment | Installiert via flux CLI |
| Sealed Secrets | Controller | Secret-Verschlüsselung | Installiert via kubectl |
| Prometheus + Grafana | Monitoring | Metriken & Dashboards | kube-prometheus-stack |
