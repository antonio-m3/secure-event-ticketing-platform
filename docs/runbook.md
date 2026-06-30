# Runbook — incidenti i troubleshooting

Operativni priručnik za dijagnostiku i oporavak. Naredbe su dane za Kubernetes
(`kubectl -n ticketing ...`); ekvivalent za lokalni Compose naveden je gdje je
relevantno.

## Opći troubleshooting workflow

1. **Promatraj (Observe)** — koji je simptom? Koji servis? Otkad?
   ```bash
   kubectl -n ticketing get pods                 # status, restart count, READY
   kubectl -n ticketing get events --sort-by=.lastTimestamp | tail -20
   ```
2. **Lokaliziraj (Isolate)** — koji pod/kontejner?
   ```bash
   kubectl -n ticketing describe pod <pod>       # Events, probe, Last State
   kubectl -n ticketing logs <pod> --previous    # logovi prethodne instance
   ```
3. **Analiziraj uzrok (Diagnose)** — log/event/exit code → korijenski uzrok.
4. **Popravi (Remediate)** — primijeni najmanju sigurnu izmjenu.
5. **Validiraj (Verify)** — potvrdi da je simptom nestao (probe, funkcionalni test).
6. **Spriječi (Prevent)** — trajna mjera da se ne ponovi.

---

## Incident 1 — PostgreSQL crash / pad baze

### Simptomi
- `api` `/readyz` vraća `503` (`SELECT 1` ne prolazi).
- `worker` logovi: `Worker loop error` / greške pri `INSERT`.
- Pod `postgres` u stanju `CrashLoopBackOff` ili `Error`, raste `RESTARTS`.
- Nove narudžbe se gomilaju u Redisu, ne pojavljuju se u `/tickets/orders`.

### Dijagnostičke naredbe
```bash
kubectl -n ticketing get pods -l app.kubernetes.io/name=postgres
kubectl -n ticketing describe pod -l app.kubernetes.io/name=postgres
kubectl -n ticketing logs -l app.kubernetes.io/name=postgres --previous
kubectl -n ticketing get pvc postgres-pvc
# Lokalno (Compose):
docker compose ps postgres && docker compose logs --tail=100 postgres
```

### Analiza uzroka
- **OOMKilled** — premali memory limit (`describe` → `Last State: OOMKilled`).
- **Pun ili nedostupan PVC** — `describe pvc` / storage problemi.
- **Korumpirani data dir** ili neuspjeli initdb (npr. promijenjen `PGDATA`).
- **Pogrešne env varijable** (vidi Incident 3).

### Korektivne mjere
```bash
# Ako je OOMKilled — povećaj limit memorije i ponovo primijeni
#   uredi infra/k8s/06-postgres.yaml (resources.limits.memory) pa:
kubectl -n ticketing apply -f infra/k8s/06-postgres.yaml

# Ako je pod zaglavio — kontrolirani restart
kubectl -n ticketing rollout restart deployment/postgres

# Provjeri da PVC postoji i da je Bound
kubectl -n ticketing get pvc postgres-pvc -o wide
```
> Redis red djeluje kao *buffer*: dok je baza dolje narudžbe čekaju u redu i
> worker ih obradi čim se baza vrati — podaci se u pravilu ne gube.

### Validacija nakon popravka
```bash
kubectl -n ticketing get pods -l app.kubernetes.io/name=postgres   # Running, READY 1/1
kubectl -n ticketing exec deploy/postgres -- pg_isready
kubectl -n ticketing port-forward svc/api 8080:8080 &
curl http://localhost:8080/readyz       # očekuj {"status":"ready"}
curl http://localhost:8080/tickets/orders
```

### Preventivne mjere
- Realni `requests`/`limits` za memoriju + alarm na OOMKilled.
- Backup/`pg_dump` raspored i provjera reclaim policy PVC-a.
- Monitoring `pg_isready` i dubine Redis reda (rano upozorenje).

---

## Incident 2 — Loš image tag / `ImagePullBackOff`

### Simptomi
- Pod zapne u `ImagePullBackOff` ili `ErrImagePull`, nikad ne postane `Running`.
- Novi rollout „visi"; `rollout status` ne završava.

### Dijagnostičke naredbe
```bash
kubectl -n ticketing get pods
kubectl -n ticketing describe pod <pod>     # Events: "Failed to pull image ... not found / unauthorized"
kubectl -n ticketing get deploy api -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

### Analiza uzroka
- **Pogrešan/nepostojeći tag** (npr. tipfeler u SHA, image još nije pushan).
- **Nedostaje pull secret / nema autorizacije** za privatni GHCR.
- **Krivo ime registryja/repozitorija** (npr. velika slova — GHCR traži mala).

### Korektivne mjere
```bash
# Postavi ispravan, postojeći nepromjenjivi tag
kubectl -n ticketing set image deployment/api \
  api=ghcr.io/antonio-m3/secure-event-ticketing-platform-api:<ispravan-sha>

# Za privatni registry — kreiraj i poveži pull secret
kubectl -n ticketing create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=<user> --docker-password=<token>
kubectl -n ticketing patch serviceaccount ticketing-sa \
  -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}'

# Ako je rollout loš — vrati na prethodnu zdravu reviziju
kubectl -n ticketing rollout undo deployment/api
```

### Validacija nakon popravka
```bash
kubectl -n ticketing rollout status deployment/api
kubectl -n ticketing get pods -l app.kubernetes.io/name=api    # Running, READY
```

### Preventivne mjere
- CI gradi i **pusha prije** deploya; deploy koristi isti SHA (vidi `ci-cd.yaml`).
- Nikad `latest` u produkciji — samo nepromjenjivi git-SHA tagovi.
- `maxUnavailable: 0` čuva staru verziju živom dok nova ne postane ready.

---

## Incident 3 — Neispravan secret / pogrešna lozinka baze

### Simptomi
- `api`/`worker` logovi: `password authentication failed for user "ticketing_user"`.
- `api` `/readyz` = `503`; `worker` ne uspijeva `INSERT`.
- `postgres` radi, ali se klijenti ne mogu autentificirati.

### Dijagnostičke naredbe
```bash
kubectl -n ticketing logs deploy/api | grep -i "password\|auth\|ECONNREFUSED"
kubectl -n ticketing get secret ticketing-secret -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo
kubectl -n ticketing get configmap ticketing-config -o yaml | grep POSTGRES_
# Provjera izravno u bazi:
kubectl -n ticketing exec -it deploy/postgres -- \
  psql -U ticketing_user -d ticketing -c "SELECT 1;"
```

### Analiza uzroka
- **Neslaganje lozinke** između `Secret`-a i one s kojom je baza inicijalizirana.
  PostgreSQL postavlja lozinku **samo pri prvoj** inicijalizaciji volumena —
  kasnija promjena Secreta ne mijenja postojeću bazu.
- **Pogrešan ključ** u Secretu ili krivo ime varijable.
- **Nesklad** `DATABASE_URL` i diskretnih `POSTGRES_*` vrijednosti.

### Korektivne mjere
```bash
# Uskladi lozinku U BAZI s onom iz Secreta (baza već postoji):
kubectl -n ticketing exec -it deploy/postgres -- \
  psql -U ticketing_user -d ticketing \
  -c "ALTER USER ticketing_user WITH PASSWORD '<lozinka-iz-secreta>';"

# Ažuriraj Secret pa restartaj potrošače da pokupe novu vrijednost:
kubectl -n ticketing create secret generic ticketing-secret \
  --from-literal=POSTGRES_PASSWORD='<nova>' \
  --from-literal=JWT_SECRET='<...>' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ticketing rollout restart deployment/api deployment/worker

# ⚠️ Samo na DEMO klasteru: potpuni reset baze (BRIŠE PODATKE)
#   kubectl -n ticketing delete pvc postgres-pvc
#   kubectl -n ticketing rollout restart deployment/postgres
```

### Validacija nakon popravka
```bash
kubectl -n ticketing exec deploy/postgres -- pg_isready
kubectl -n ticketing port-forward svc/api 8080:8080 &
curl http://localhost:8080/readyz       # {"status":"ready"}
```

### Preventivne mjere
- Jedan izvor istine za lozinku (Secret); izbjegavaj dupliranje u `DATABASE_URL`.
- Rotaciju lozinke radi uz `ALTER USER` (ne oslanjaj se na re-init volumena).
- Razmotri External Secrets / Vault za automatsku sinkronizaciju.

---

## Brza referenca dijagnostičkih naredbi

```bash
# Compose
docker compose ps
docker compose logs -f <servis>
docker compose exec <servis> sh

# Kubernetes
kubectl -n ticketing get pods
kubectl -n ticketing describe pod <pod>
kubectl -n ticketing logs <pod> [--previous] [-f]
kubectl -n ticketing get events --sort-by=.lastTimestamp
kubectl -n ticketing rollout status|history|undo deployment/<dep>
kubectl -n ticketing exec -it deploy/<dep> -- sh
```
