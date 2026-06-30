# Mapiranje ishoda (I1–I6) na artefakte

Tablica povezuje ishode kolegija s konkretnim artefaktima u repozitoriju, tako da
se za svaki ishod može pokazati gdje je i kako ostvaren.

| Ishod | Naziv | Glavni artefakti | Dokaz / objašnjenje |
|-------|-------|------------------|---------------------|
| **I1** | Procjena kontejnera i servisa | [`docs/architecture.md`](architecture.md), [`compose.yaml`](../compose.yaml) | Identificirani servisi i uloge, kontejneri vs. VM, međuservisna komunikacija, tok podataka, sigurnosne prednosti izolacije |
| **I2** | Sigurno upravljanje slikama | [`api/Containerfile`](../api/Containerfile), [`frontend/Containerfile`](../frontend/Containerfile), [`worker/Containerfile`](../worker/Containerfile), [`.dockerignore`](../.dockerignore), [`docs/security/image-scan-report.md`](security/image-scan-report.md) | Multi-stage build, non-root, minimalna runtime slika, samo prod ovisnosti, bez tajni u imageu, Trivy izvješće + gate |
| **I3** | Ubrzana isporuka | [`.github/workflows/ci-cd.yaml`](../.github/workflows/ci-cd.yaml), [`infra/k8s/kustomization.yaml`](../infra/k8s/kustomization.yaml) | Automatiziran pipeline (test→build→scan→push→deploy), standardiziran deployment, nepromjenjivi git-SHA tagovi, DORA objašnjenje |
| **I4** | DevSecOps metodologija | [`docs/devsecops.md`](devsecops.md), [`scripts/trivy-scan.sh`](../scripts/trivy-scan.sh), Trivy koraci u CI-u, [`.env.example`](../.env.example), [`infra/k8s/04-secret.example.yaml`](../infra/k8s/04-secret.example.yaml) | Shift-left, container + IaC scanning, quality gate (HIGH/CRITICAL), upravljanje tajnama, tagging politika |
| **I5** | Troubleshooting | [`docs/runbook.md`](runbook.md) | 3 incidenta (DB crash, ImagePullBackOff, krivi secret) sa simptomima, dijagnostikom, uzrokom, popravkom, validacijom i prevencijom + opći workflow |
| **I6** | Orkestracija | [`infra/k8s/`](../infra/k8s/) (00–12 + kustomization) | Deploymenti/Services, probe, resource requests/limits, ResourceQuota, LimitRange, RBAC, NetworkPolicy (default-deny), Ingress, PVC perzistencija |

## Sažetak pokrivenosti zahtjeva

### I1 — Kontejneri i servisi
Pet servisa s jasnim ulogama; obrazloženje izbora kontejnera; dijagram toka
podataka korisnik → frontend → API → Redis → worker → PostgreSQL.

### I2 — Sigurne slike
Svaki `Containerfile` ima `base`/`deps`/`dev`/`runtime` stageove, koristi
`node:20-alpine`, dropa na `USER node`, instalira samo produkcijske ovisnosti u
finalnoj slici (`--omit=dev`), `npm ci` kad postoji lockfile. `.dockerignore`
sprječava ulazak `.env`/ključeva u image.

### I3 — Brža isporuka
GitHub Actions automatizira cijeli put do registryja; deploy job je opcionalan i
gated. Nepromjenjivi tagovi + `kustomize edit set image` omogućuju deterministički
deploy i rollback.

### I4 — DevSecOps
Sigurnost je u svakoj fazi: lokalna skripta, CI image+IaC scan, quality gate,
SARIF u Security tab, odvojene tajne, dokumentirana remediation i DORA metrike.

### I5 — Troubleshooting
Runbook pokriva tri tražena scenarija plus opći 6-koračni workflow i brzu
referencu naredbi (Compose + kubectl).

### I6 — Orkestracija
Potpun set manifesta s sigurnosnim kontekstom (runAsNonRoot, drop ALL,
allowPrivilegeEscalation false, readOnlyRootFilesystem gdje je izvedivo),
probama, limitima, kvotama, RBAC-om, mrežnim politikama i Ingressom; PostgreSQL
perzistira preko PVC-a.
