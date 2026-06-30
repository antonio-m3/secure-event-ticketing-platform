# Produkcijski deployment (Kubernetes / OpenShift)

Manifesti su u [`infra/k8s/`](../infra/k8s/) i numerirani redoslijedom primjene.
Mogu se primijeniti pojedinačno ili odjednom preko Kustomize.

## 1. Preduvjeti

- Klaster: kind / minikube / OpenShift / managed k8s
- `kubectl` (+ `kustomize`, ugrađen u noviji `kubectl`)
- Ingress controller (npr. NGINX) za vanjski pristup; na OpenShiftu `Route`
- CNI koji *enforce-a* NetworkPolicy (Calico/Cilium/OVN); na plain minikube
  policy je prihvaćen ali možda ne i provođen

## 1a. Brzo lokalno testiranje na `kind` (jedna naredba)

Za lokalnu provjeru cijelog Kubernetes deploya bez registryja postoje pomoćne
skripte koje grade `runtime` slike, učitaju ih u `kind` i primijene manifeste:

```bash
./scripts/kind-up.sh      # kreira kind klaster + build + load + deploy + čeka rollout
# ... testiranje ...
./scripts/kind-down.sh    # briše klaster
```

Konfiguracija klastera je u [`scripts/kind/kind-cluster.yaml`](../scripts/kind/kind-cluster.yaml).

> **WSL2 napomena:** na WSL2 (ext4 na vhdx) etcd-ov intenzivan `fsync` zna
> preopteretiti virtualni disk i izazvati `errors=remount-ro` (API server padne).
> Zato `kind-cluster.yaml` postavlja etcd `unsafe-no-fsync: true` — sigurno samo
> za jednokratne lokalne/dev klastere. Ovaj projekt je ovako uspješno deployan i
> testiran end-to-end (svih 5 deploymenata Running, kupnja karte prošla kroz
> Redis→worker→PostgreSQL).

## 2. Pregled manifesta

| Datoteka                 | Objekt(i)                                    |
|--------------------------|----------------------------------------------|
| `00-namespace.yaml`      | Namespace `ticketing` (+ Pod Security: restricted) |
| `01-resourcequota.yaml`  | ResourceQuota (CPU/mem/objekti)              |
| `02-limitrange.yaml`     | LimitRange (default + max po kontejneru)     |
| `03-configmap.yaml`      | ConfigMap (ne-tajna konfiguracija)           |
| `04-secret.example.yaml` | **Predložak** Secreta (placeholderi)         |
| `05-rbac.yaml`           | ServiceAccount + Role + RoleBinding          |
| `06-postgres.yaml`       | PVC + initdb ConfigMap + Deployment + Service|
| `07-redis.yaml`          | Deployment + Service                         |
| `08-api.yaml`            | Deployment (2 replike) + Service             |
| `09-worker.yaml`         | Deployment                                   |
| `10-frontend.yaml`       | Deployment (2 replike) + Service             |
| `11-ingress.yaml`        | Ingress (`/` → frontend, `/api` → api)       |
| `12-networkpolicy.yaml`  | default-deny + eksplicitne dozvole + DNS     |
| `kustomization.yaml`     | povezuje sve + image tag override            |

## 3. Namespace, ConfigMap, Secret

```bash
# 1) Namespace prvo (ostalo je u njega)
kubectl apply -f infra/k8s/00-namespace.yaml

# 2) Secret se NE uzima iz repozitorija s placeholderima — kreiraj ga sigurno:
kubectl -n ticketing create secret generic ticketing-secret \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=DATABASE_URL="postgresql://ticketing_user:CHANGE_ME@postgres:5432/ticketing"
```

> `04-secret.example.yaml` namjerno **nije** uključen u `kustomization.yaml`
> automatski — služi samo kao dokumentacija strukture.

## 4. Deploy cijelog stacka

```bash
# Postavi prave image tagove (CI to radi automatski; ručno primjer):
cd infra/k8s
kustomize edit set image \
  ghcr.io/antonio-m3/secure-event-ticketing-platform-api=ghcr.io/antonio-m3/secure-event-ticketing-platform-api:<sha> \
  ghcr.io/antonio-m3/secure-event-ticketing-platform-worker=ghcr.io/antonio-m3/secure-event-ticketing-platform-worker:<sha> \
  ghcr.io/antonio-m3/secure-event-ticketing-platform-frontend=ghcr.io/antonio-m3/secure-event-ticketing-platform-frontend:<sha>
cd ../..

kubectl apply -k infra/k8s
```

### OpenShift napomene

- Umjesto Ingressa: `oc expose service/frontend` i `oc expose service/api`
  (Route), ili definiraj `Route` objekt.
- `restricted-v2` SCC je kompatibilan s ovim manifestima (non-root, drop ALL,
  bez privilegija). Ne treba dodjeljivati `anyuid`.

## 5. Probe (liveness / readiness)

| Servis    | Liveness                    | Readiness                          |
|-----------|-----------------------------|------------------------------------|
| api       | HTTP `/healthz`             | HTTP `/readyz` (provjerava DB+Redis)|
| frontend  | HTTP `/healthz`             | HTTP `/healthz`                    |
| worker    | `pgrep node src/worker.js`  | `pgrep node src/worker.js`         |
| postgres  | `pg_isready`                | `pg_isready`                       |
| redis     | `redis-cli ping`            | `redis-cli ping`                   |

Readiness kontrolira ulazak u Service rotaciju; liveness restart kontejnera.

## 6. Resource requests / limits

Svaki kontejner ima `requests` (zajamčeno) i `limits` (gornja granica) —
nužno za rad ResourceQuote i za pošteno raspoređivanje. Vrijednosti su skromne
(npr. api `100m/128Mi` request, `500m/256Mi` limit) i lako se podešavaju.

## 7. Rolling update

Aplikacijski Deploymenti koriste `RollingUpdate` s `maxUnavailable: 0` i
`maxSurge: 1` → nova replika se digne i postane *ready* prije nego stara ode →
**zero-downtime**.

```bash
# Primjer: ažuriranje api-ja na novi SHA tag
kubectl -n ticketing set image deployment/api \
  api=ghcr.io/antonio-m3/secure-event-ticketing-platform-api:<novi-sha>
kubectl -n ticketing rollout status deployment/api
```

## 8. Rollback

```bash
# Pregled povijesti revizija
kubectl -n ticketing rollout history deployment/api

# Vrati na prethodnu reviziju
kubectl -n ticketing rollout undo deployment/api

# Ili na točno određenu reviziju / SHA tag
kubectl -n ticketing rollout undo deployment/api --to-revision=3
kubectl -n ticketing set image deployment/api \
  api=ghcr.io/antonio-m3/secure-event-ticketing-platform-api:<stari-sha>
```

Budući da su tagovi nepromjenjivi (git SHA), rollback je deterministički.

## 9. Validacija deploymenta

```bash
kubectl -n ticketing get pods,svc,ingress
kubectl -n ticketing get pods -w                 # čekaj Running + READY
kubectl -n ticketing rollout status deployment/api
kubectl -n ticketing rollout status deployment/frontend
kubectl -n ticketing rollout status deployment/worker

# Funkcionalna provjera kroz port-forward (bez Ingressa)
kubectl -n ticketing port-forward svc/api 8080:8080 &
curl http://localhost:8080/readyz
curl http://localhost:8080/events

# Preko Ingressa (dodaj host u /etc/hosts -> ticketing.local)
curl -H "Host: ticketing.local" http://<ingress-ip>/api/healthz
```

## 10. Čišćenje

```bash
kubectl delete -k infra/k8s
# ili cijeli namespace (uključuje sve, ali NE i ručno kreirani Secret PVC podatke ovisno o reclaim policy):
kubectl delete namespace ticketing
```

Za incidente i oporavak vidi [runbook.md](runbook.md).
