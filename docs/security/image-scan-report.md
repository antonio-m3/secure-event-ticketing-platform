# Trivy Image Scan Report

> ✅ **REAL SCAN.** Ovo izvješće je generirano stvarnim pokretanjem Trivyja nad
> lokalno izgrađenim `runtime` slikama. Sirovi izlazi su u
> [`docs/security/scans/`](scans/). Regeneriraj bilo kad s:
> ```bash
> ./scripts/trivy-scan.sh --build
> ```

| Polje              | Vrijednost                              |
|--------------------|-----------------------------------------|
| Datum skena        | 2026-06-28                              |
| Trivy verzija      | 0.71.2                                   |
| Bazni image        | `node:20-alpine` (alpine 3.23.4)        |
| Skenirane slike    | `ticketing-api`, `ticketing-frontend`, `ticketing-worker` (target `runtime`) |
| Politika gatea     | fail na **fixable HIGH/CRITICAL** (`--ignore-unfixed`) |

## 1. Sažetak (nakon korektivnih mjera)

| Sken                         | CRITICAL | HIGH | Gate |
|------------------------------|:--------:|:----:|:----:|
| Image: ticketing-api         |    0     |  0   | ✅ PASS |
| Image: ticketing-frontend    |    0     |  0   | ✅ PASS |
| Image: ticketing-worker      |    0     |  0   | ✅ PASS |
| Filesystem (app deps, sve 3) |    0     |  0   | ✅ PASS |
| IaC config (Containerfile + k8s) |  0   |  0   | ✅ PASS |

Sve slike i konfiguracija prolaze quality gate (0 fixable HIGH/CRITICAL).

## 2. Što je nađeno prije korektivnih mjera (baseline)

Prvi sken neizmijenjenih `runtime` slika dao je **2 CRITICAL + 4 HIGH po slici**.
Ključno: **niti jedna ranjivost nije bila u kodu aplikacije** — `filesystem`
sken `app/node_modules/*` bio je čist (0). Svi nalazi su bili **naslijeđeni iz
baznog `node:20-alpine` imagea**:

| Paket / lokacija                         | CVE (primjeri)                                   | Severity | Izvor                |
|------------------------------------------|--------------------------------------------------|----------|----------------------|
| `libcrypto3` / `libssl3` (openssl)       | CVE-2026-45447 (Heap UAF u PKCS7_verify)         | HIGH     | alpine OS paket      |
| `tar` / `node-tar` (npm bundled)         | CVE-2026-23745, -23950, -24842, -26960, -29786, -31802 | HIGH/CRITICAL | bundled npm CLI |
| `minimatch` (npm bundled)                | CVE-2026-26996, -27903, -27904                   | HIGH     | bundled npm CLI      |
| `glob` (npm bundled)                     | CVE-2025-64756 (Command Injection)               | HIGH     | bundled npm CLI      |
| `cross-spawn` (npm bundled)              | CVE-2024-21538 (ReDoS)                           | HIGH     | bundled npm CLI      |

> Napomena: `tar`/`glob`/`minimatch`/`cross-spawn` žive u
> `/usr/local/lib/node_modules/npm/...` — to je **npm CLI koji dolazi s baznom
> slikom**, a ne ovisnost aplikacije. Aplikacija u produkciji pokreće isključivo
> `node src/server.js` i nikad ne poziva npm.

## 3. Korektivne mjere (primijenjene i verificirane)

| # | Mjera | Datoteka | Učinak |
|---|-------|----------|--------|
| 1 | `apk upgrade --no-cache` u `base` stageu | `*/Containerfile` | Zatvara alpine/openssl nalaze (libcrypto3/libssl3 → 3.5.7-r0). Alpine sken: 2 → **0**. |
| 2 | Uklanjanje npm/corepack/yarn iz `runtime` slike | `*/Containerfile` | Briše ranjivi bundled npm CLI iz finalne slike. Nije potreban u runtimeu. npm nalazi → **0**. |

Verifikacija nakon mjera:
- `trivy image --ignore-unfixed --severity HIGH,CRITICAL --exit-code 1` → **0** za sve tri slike (gate prolazi).
- `docker run --entrypoint node ticketing-api:runtime --version` → `v20.20.2` (aplikacija radi normalno bez npm-a).

## 4. IaC / config scan

`trivy config` nad Containerfileovima i `infra/k8s/` → **0 HIGH/CRITICAL**.
Tijekom rada otkriven je i popravljen jedan HIGH nalaz:

- **KSV-0014** (`readOnlyRootFilesystem` na PostgreSQL Deploymentu) → riješeno
  postavljanjem `readOnlyRootFilesystem: true` uz eksplicitne zapisive
  `emptyDir`/PVC mountove (PGDATA, `/var/run/postgresql`, `/tmp`) u
  [`infra/k8s/06-postgres.yaml`](../../infra/k8s/06-postgres.yaml).

## 5. Quality gate politika

| Severity            | Fixable | Akcija u CI-u            |
|---------------------|:-------:|--------------------------|
| CRITICAL / HIGH     |   da    | ❌ **ruši build**         |
| CRITICAL / HIGH     |   ne    | ⚠️ prijavi, ne ruši (`--ignore-unfixed`) |
| MEDIUM / LOW        |  bilo   | ⚠️ prijavi (triage)       |

Implementacija: `severity: HIGH,CRITICAL`, `ignore-unfixed: true`, `exit-code: 1`
u `.github/workflows/ci-cd.yaml` i `scripts/trivy-scan.sh`.

## 6. Trajno održavanje

- **Bazni image**: periodički `docker pull node:20-alpine` + rebuild da se
  pokupe novi sigurnosni patchevi; CI to radi pri svakom buildu.
- **App ovisnosti**: `npm audit` + Dependabot/Renovate za `package.json`.
- **Regeneracija izvješća**: `./scripts/trivy-scan.sh --build`, zatim ažuriraj
  tablice ovdje iz `docs/security/scans/`.

## 7. Kako reproducirati

```bash
# Build runtime slike i sken (image + filesystem + IaC); izlaz u docs/security/scans/
./scripts/trivy-scan.sh --build

# Samo gate provjera jedne slike
trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 ticketing-api:runtime
```
