# DevSecOps pristup

Ovaj dokument opisuje kako je sigurnost ugrađena u cijeli životni ciklus
isporuke ove platforme, a ne dodana naknadno.

## 1. Filozofija: shift-left sigurnost

„Shift-left" znači pomicanje sigurnosnih provjera što ranije u proces — idealno
na razvojevo računalo i u *pull request*, a ne tek pred produkciju. Cilj je
otkriti ranjivost dok je popravak jeftin (sekunde u CI-u) umjesto skup
(incident u produkciji).

Slojevi provjera u ovom projektu:

| Faza             | Provjera                                   | Alat / artefakt                |
|------------------|--------------------------------------------|--------------------------------|
| Razvoj (lokalno) | sigurnosno skeniranje na zahtjev           | `scripts/trivy-scan.sh`        |
| Commit / PR      | testovi, image scan, IaC scan, quality gate| GitHub Actions `ci-cd.yaml`    |
| Build            | non-root, minimalne slike, bez tajni       | `Containerfile`, `.dockerignore` |
| Deploy           | RBAC, NetworkPolicy, probe, limiti         | `infra/k8s/*`                  |
| Runtime          | health/readiness, logovi                   | `/healthz`, `/readyz`, k8s probe |

## 2. CI/CD pipeline

Definiran u [`.github/workflows/ci-cd.yaml`](../.github/workflows/ci-cd.yaml).
Pokreće se na `push` i `pull_request` prema `main`. Jobovi:

1. **test** — matrica (`api`, `frontend`, `worker`): `npm ci`/`install`,
   `npm run lint --if-present`, `npm test --if-present`, te `node --check`
   *syntax smoke-test* entrypointa (radi i prije nego se napišu unit testovi).
2. **build-and-scan** — gradi `runtime` image za svaki servis s **nepromjenjivim
   git-SHA tagom**, pa ga Trivy skenira.
3. **iac-scan** — `trivy config` nad Containerfileovima i k8s manifestima.
4. **push** — push slika na **GHCR** (samo na `main`, tek nakon prolaska gateova).
5. **deploy** *(opcionalno)* — pokreće se samo ako je `vars.ENABLE_DEPLOY == 'true'`
   i postoji `KUBE_CONFIG` secret; postavlja SHA tagove i radi `kubectl apply -k`.

```
push/PR ─▶ test ─▶ build-and-scan ─┐
                   iac-scan ────────┴─▶ push(GHCR) ─▶ [deploy?]
                        (quality gate ovdje ruši build)
```

## 3. Testovi

Trenutno postoje *smoke* provjere (`node --check`) i kuke `--if-present` za lint
i unit testove, pa pipeline radi i kako se test-suite širi. Preporučeni sljedeći
korak: dodati `jest`/`supertest` za `/healthz`, `/events` i validaciju kupnje.
Time pipeline dobiva pravi *test gate* uz postojeći sigurnosni gate.

## 4. Container scanning (Trivy)

- Skenira se OS sloj **i** aplikacijske ovisnosti (`vuln-type: os,library`).
- `ignore-unfixed: true` — gate pada samo na ranjivosti za koje **postoji
  popravak** (fixable), da ne blokira na onome što se ne može popraviti.
- Rezultati se uploadaju kao **SARIF** u GitHub Security tab (vidljivo po PR-u).
- Lokalno: `./scripts/trivy-scan.sh` (image + filesystem + config), rezultati u
  `docs/security/scans/`.

## 5. IaC / config scanning

`trivy config` analizira Containerfileove i Kubernetes manifeste i upozorava na
loše konfiguracije (npr. kontejner kao root, nedostatak resource limita,
privilegirani pristup). Ovo hvata *infrastrukturne* greške koje image scan ne
vidi.

## 6. Quality gate

**Pravilo:** build pada ako Trivy pronađe **fixable HIGH ili CRITICAL** ranjivost
u slici ili HIGH/CRITICAL grešku konfiguracije u IaC-u.

| Severity        | Akcija                                   |
|-----------------|------------------------------------------|
| CRITICAL (fixable) | ❌ ruši build — mora se popraviti odmah |
| HIGH (fixable)     | ❌ ruši build                            |
| MEDIUM / LOW       | ⚠️ prijavljeno, ne ruši build (triage)  |
| unfixed (bilo koji)| ⚠️ prijavljeno, ne ruši (nema popravka) |

Implementacija: `exit-code: "1"` + `severity: HIGH,CRITICAL` +
`ignore-unfixed: true` u Trivy koraku.

## 7. Upravljanje tajnama

- Lokalno: `.env` (git-ignoriran); u repo ide samo `.env.example` s placeholderima.
- Kubernetes: vrijednosti iz `Secret`-a (`04-secret.example.yaml` je samo
  predložak; stvarni Secret se kreira `kubectl create secret ...` ili preko
  Sealed Secrets / External Secrets / Vault).
- CI: isključivo **GitHub Secrets** (`GITHUB_TOKEN`, `KUBE_CONFIG`); nikad u kodu.
- `.dockerignore` sprječava da `.env`, `*.pem`, `*.key` završe u image sloju.
- `.gitignore` sprječava commit `.env` i stvarnog `secret.yaml`.

## 8. Tagging politika slika

- **Nepromjenjivi tagovi** = prvih 12 znakova git SHA (`build-and-scan` job).
  Svaki build je sljediv do točnog commita; isti tag uvijek znači isti sadržaj.
- **`latest` se NE koristi za produkciju** — vodi do *„koja verzija zapravo
  radi?"* problema i otežava rollback. `latest` postoji samo kao default
  placeholder u manifestima dok ga CI ne prepiše SHA tagom.
- Rollback = ponovni deploy prethodnog SHA taga (vidi
  [production-deployment.md](production-deployment.md)).

## 9. Korektivne mjere (remediation)

Kad gate prijavi ranjivost:

1. **Trijaža** — pogledaj CVE, je li fixable, koji paket.
2. **Popravak** — podigni baznu sliku (`node:20-alpine` → noviji patch),
   ažuriraj ovisnost (`npm update <paket>`), ili dodaj iznimku uz obrazloženje.
3. **Re-scan** — `./scripts/trivy-scan.sh` lokalno dok ne prođe.
4. **Verifikacija** — novi commit ponovo prolazi cijeli pipeline.
5. **Dokumentiranje** — bilješka u
   [security/image-scan-report.md](security/image-scan-report.md).

## 10. Mjerljiv napredak isporuke (DORA)

Četiri ključne DORA metrike i kako ih ovaj projekt podupire:

| Metrika                         | Što mjeri                          | Kako projekt pomaže                                  |
|---------------------------------|------------------------------------|-----------------------------------------------------|
| Deployment Frequency            | Koliko često isporučujemo          | Automatiziran pipeline → svaki merge može u deploy  |
| Lead Time for Changes           | Vrijeme od commita do produkcije   | Build+scan+push automatizirani; nema ručnih koraka  |
| Change Failure Rate             | % deploya koji uzrokuju kvar       | Quality gate + testovi + probe hvataju greške rano  |
| Time to Restore (MTTR)          | Brzina oporavka od incidenta       | Nepromjenjivi tagovi + `rollout undo` + runbook     |

Jednostavno rečeno: standardiziran, automatiziran i sigurnosno provjeren tok
znači **češće, brže i pouzdanije** isporuke uz **brži oporavak** kad nešto pođe
po zlu. Vidi [runbook.md](runbook.md) za oporavak i
[outcomes-mapping.md](outcomes-mapping.md) za ishode I3/I4.
