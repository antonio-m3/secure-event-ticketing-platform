# Lokalni razvoj

Detaljne upute za pokretanje i razumijevanje lokalnog stacka definiranog u
[`compose.yaml`](../compose.yaml).

## 1. Priprema

```bash
cp .env.example .env       # placeholder vrijednosti; uredi po potrebi
docker compose up --build -d
docker compose ps          # svi servisi trebaju biti "healthy"
```

Zamjena za Podman: `podman compose ...`.

## 2. Objašnjenje `compose.yaml`

### 2.1 Servisi i build

`frontend`, `api` i `worker` grade se iz vlastitog `Containerfile`-a s
`target: dev` — to je *hot reload* stage (nodemon, sve dev ovisnosti).
`postgres` i `redis` koriste službene upstream slike.

```yaml
build:
  context: ./api
  dockerfile: Containerfile
  target: dev
```

### 2.2 Mreže (mrežna izolacija)

Definirane su **dvije** bridge mreže:

| Mreža       | Članovi                                   | Svrha                  |
|-------------|-------------------------------------------|------------------------|
| `web-tier`  | `frontend`, `api`                         | javni / UI promet      |
| `data-tier` | `api`, `worker`, `postgres`, `redis`      | privatni podatkovni sloj |

`frontend` je **samo** na `web-tier` → ne može doprijeti do `postgres`/`redis`.
`api` je na obje mreže (most). `worker`, `postgres`, `redis` su samo na
`data-tier`. Ovo preslikava produkcijske NetworkPolicy pravila.

### 2.3 Volumeni (perzistencija)

```yaml
volumes:
  postgres-data:   # trajni podaci baze (preživi `down`, briše se s `down -v`)
  redis-data:
```

`postgres` dodatno mountira `infra/postgres/init.sql` u
`/docker-entrypoint-initdb.d/` — schema se kreira **samo pri prvoj**
inicijalizaciji praznog volumena.

### 2.4 Healthchecks

Svaki servis ima healthcheck:

- `postgres`: `pg_isready`
- `redis`: `redis-cli ping`
- `api` / `frontend`: HTTP GET na `/healthz` (Node one-liner)
- `worker`: provjera da proces `node src/worker.js` živi (`pgrep`)

Zahvaljujući `depends_on: condition: service_healthy`, `api` starta tek kad su
baza i Redis *healthy*, a `frontend` tek kad je `api` *healthy* — nema
*race conditiona* pri podizanju.

### 2.5 Hot reload

Izvorni kod je bind-mountan read-only u kontejner:

```yaml
volumes:
  - ./api/src:/app/src:ro
```

`nodemon` (iz `dev` stagea) prati promjene i restarta proces — uređuješ kod na
hostu, promjena se odmah vidi u kontejneru, bez rebuilda. `node_modules` se ne
mountira pa ostaje onaj iz image-a.

## 3. Validacija funkcionalnosti

```bash
# Health/readiness
curl http://localhost:8080/healthz
curl http://localhost:8080/readyz
curl http://localhost:3000/healthz

# Funkcionalni tok
curl http://localhost:8080/events
curl -X POST http://localhost:8080/tickets/purchase \
  -H "Content-Type: application/json" \
  -d '{"eventId":"evt-1001","customerEmail":"student@example.com","quantity":2}'
curl http://localhost:8080/tickets/orders     # narudžba se pojavi kao "processed"
```

UI: otvori http://localhost:3000, odaberi event, klikni **Purchase**.

### Provjera mrežne izolacije (dokaz da frontend ne vidi bazu)

```bash
# Iz frontenda PostgreSQL NIJE dostupan (očekuje se neuspjeh):
docker compose exec frontend node -e "require('net').connect(5432,'postgres').on('error',e=>{console.log('blokirano OK:',e.code);process.exit(0)})"

# Iz api-ja PostgreSQL JE dostupan (očekuje se uspjeh):
docker compose exec api node -e "require('net').connect(5432,'postgres').on('connect',()=>{console.log('api->postgres OK');process.exit(0)})"
```

## 4. Korisne naredbe

```bash
docker compose ps                  # status + health
docker compose logs -f api worker  # logovi uživo
docker compose exec api sh         # shell u kontejneru
docker compose restart api         # restart jednog servisa
docker compose build --no-cache    # čisti rebuild
docker compose down                # gašenje
docker compose down -v             # gašenje + brisanje podataka
```

## 5. Pokretanje bez kontejnera (opcionalno)

Svaki servis se može pokrenuti i lokalno uz Node 20 i pokrenute `postgres`/
`redis` (npr. samo te dvije usluge iz Composea):

```bash
docker compose up -d postgres redis
cd api && npm install && npm run dev    # isto za frontend i worker
```

Vidi i [production-deployment.md](production-deployment.md) za Kubernetes te
[runbook.md](runbook.md) za rješavanje incidenata.
