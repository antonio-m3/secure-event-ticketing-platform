# Secure Event Ticketing Platform

Referentni projekt za kolegij **Uvod u DevOps – DevSecOps**. Demonstrira cijeli
DevOps/DevSecOps ciklus na maloj, ali realnoj aplikaciji: lokalni razvoj kroz
Docker/Podman Compose, kontejnerizaciju, CI/CD s sigurnosnim *quality gateom* i
produkcijski deployment na Kubernetes/OpenShift.

> Sve lozinke i tajne u repozitoriju su **placeholderi** (`.env.example`,
> `04-secret.example.yaml`). Stvarne tajne nikad se ne commitaju.

---

## 1. Opis projekta

Aplikacija je pojednostavljena platforma za prodaju ulaznica za evente.
Korisnik u web sučelju odabere event i kupi kartu; narudžba se asinkrono stavlja
u Redis red, a pozadinski *worker* je trajno zapisuje u PostgreSQL.

## 2. Servisi

| Servis     | Tehnologija          | Uloga                                                | Port |
|------------|----------------------|------------------------------------------------------|------|
| `frontend` | Node.js / Express    | Web UI, servira statiku i `/config`                  | 3000 |
| `api`      | Node.js / Express    | REST API: eventi, kupnja, health/readiness           | 8080 |
| `worker`   | Node.js              | Troši Redis red i upisuje narudžbe u PostgreSQL      |  –   |
| `postgres` | PostgreSQL 16        | Trajna pohrana narudžbi                              | 5432 |
| `redis`    | Redis 7              | Red poruka (queue) / cache                            | 6379 |

**Tok podataka:** korisnik → frontend → API → Redis → worker → PostgreSQL.
Detaljnije: [docs/architecture.md](docs/architecture.md).

## 3. Preduvjeti

- Docker 24+ **ili** Podman 4+ s Compose podrškom
- (opcionalno) Node.js 20+ za pokretanje servisa izvan kontejnera
- (opcionalno) `kubectl` + `kustomize` i klaster (kind/minikube/OpenShift) za produkcijski dio
- (opcionalno) `trivy` za lokalno sigurnosno skeniranje

## 4. Lokalno pokretanje (korak po korak)

```bash
# 1) Kloniraj/uđi u projekt
cd secure-event-ticketing-platform

# 2) Pripremi varijable okoline (NE commitati .env)
cp .env.example .env
#    po želji uredi lozinke/portove u .env

# 3) Build + pokretanje cijelog stacka u pozadini
docker compose up --build -d

# 4) Provjeri status servisa (svi trebaju biti "healthy")
docker compose ps
```

Otvori UI na **http://localhost:3000**, API je na **http://localhost:8080**.

### Gašenje stacka

```bash
docker compose down            # zaustavi i ukloni kontejnere/mreže
docker compose down -v         # + obriši volumene (postgres/redis podatke)
```

### Rebuild (nakon promjene koda/Containerfilea)

```bash
docker compose build --no-cache
docker compose up -d
# ili u jednom koraku:
docker compose up --build -d
```

### Pregled logova

```bash
docker compose logs -f                 # svi servisi, prati uživo
docker compose logs -f api worker      # samo odabrani servisi
docker compose logs --tail=100 postgres
```

> Podizanje s Podmanom: zamijeni `docker compose` s `podman compose`.

## 5. Provjera health endpointa

```bash
curl http://localhost:8080/healthz   # {"status":"ok","service":"api"}
curl http://localhost:8080/readyz    # provjerava PostgreSQL + Redis
curl http://localhost:3000/healthz   # {"status":"ok","service":"frontend"}
```

## 6. Validacija kupnje karte (osnovni workflow)

```bash
# 1) Dohvati dostupne evente
curl http://localhost:8080/events

# 2) Kupi kartu (narudžba ide u Redis red -> HTTP 202)
curl -X POST http://localhost:8080/tickets/purchase \
  -H "Content-Type: application/json" \
  -d '{"eventId":"evt-1001","customerEmail":"student@example.com","quantity":2}'

# 3) Worker obradi red i upiše u PostgreSQL; provjeri obrađene narudžbe
curl http://localhost:8080/tickets/orders
```

Očekivano: korak 2 vraća `{"message":"Order queued","orderId":"..."}`, a nakon
sekunde-dvije ista narudžba pojavi se u koraku 3 sa statusom `processed`.
U UI-ju isti tok napraviš klikom na **Purchase**.

## 7. Troubleshooting (lokalni Compose)

| Simptom | Vjerojatni uzrok | Rješenje |
|---------|------------------|----------|
| `api` stalno *restarting* / `readyz` 503 | Baza ili Redis još nisu spremni | `docker compose ps`; pričekaj health, `docker compose logs postgres redis` |
| Port 3000/8080 zauzet | Drugi proces koristi port | Promijeni `FRONTEND_PORT`/`API_PORT` u `.env` pa `up -d` |
| `tickets/orders` prazan nakon kupnje | Worker ne radi | `docker compose logs worker`; provjeri Redis vezu |
| Promjena u `.env` ne djeluje | Compose koristi staru vrijednost | `docker compose up -d` (ponovo učita env), po potrebi `down && up` |
| Stari podaci u bazi | Stari volume | `docker compose down -v` pa ponovo `up` |

Detaljni runbook s incidentima: [docs/runbook.md](docs/runbook.md).

## 8. Sigurnosni elementi

- Multi-stage build + **non-root** runtime korisnik u svim slikama
- Razdvojen `ConfigMap` (ne-tajno) i `Secret` (tajno)
- Liveness/Readiness probe, resource requests/limits
- `ResourceQuota` + `LimitRange`, `ServiceAccount` + RBAC
- **NetworkPolicy** segmentacija (default-deny + eksplicitne dozvole)
- Trivy skeniranje slika i IaC-a u CI-u s *quality gateom* (HIGH/CRITICAL)

Detalji: [docs/devsecops.md](docs/devsecops.md),
[docs/security/image-scan-report.md](docs/security/image-scan-report.md).

## 9. Produkcijski deployment (sažetak)

```bash
# Tajna se kreira izvan repozitorija (placeholderi se NE primjenjuju automatski)
kubectl apply -f infra/k8s/00-namespace.yaml
kubectl -n ticketing create secret generic ticketing-secret \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=DATABASE_URL="postgresql://ticketing_user:REPLACE@postgres:5432/ticketing"

kubectl apply -k infra/k8s        # cijeli stack
kubectl -n ticketing get pods -w
```

Detaljno (probe, rolling update, rollback, validacija):
[docs/production-deployment.md](docs/production-deployment.md).

## 10. Struktura repozitorija

```
secure-event-ticketing-platform/
├── api/                  # REST API servis
│   ├── src/server.js
│   ├── package.json
│   ├── Containerfile     # multi-stage, non-root
│   └── .dockerignore
├── frontend/             # web UI servis
│   ├── src/{server.js,public/index.html}
│   ├── Containerfile
│   └── .dockerignore
├── worker/               # pozadinski queue consumer
│   ├── src/worker.js
│   ├── Containerfile
│   └── .dockerignore
├── infra/
│   ├── postgres/init.sql # schema bootstrap
│   └── k8s/              # Kubernetes/OpenShift manifesti (00..12 + kustomization)
├── docs/                 # arhitektura, dev, devsecops, deployment, runbook, security
│   └── security/
├── scripts/
│   ├── trivy-scan.sh     # lokalno sigurnosno skeniranje
│   ├── kind-up.sh        # podigni lokalni Kubernetes (kind) + deploy
│   ├── kind-down.sh      # ugasi lokalni kind klaster
│   └── kind/kind-cluster.yaml
├── .github/workflows/ci-cd.yaml
├── compose.yaml          # lokalni dev stack (2 mreže, healthcheck, volumeni)
├── .env.example          # placeholder varijable okoline
├── .dockerignore
└── README.md
```

## Mapiranje na ishode (I1–I6)

Vidi [docs/outcomes-mapping.md](docs/outcomes-mapping.md) za tablicu ishoda i
pripadnih artefakata.
