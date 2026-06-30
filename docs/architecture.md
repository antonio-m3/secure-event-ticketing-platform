# Arhitektura — Secure Event Ticketing Platform

## 1. Pregled

Platforma je podijeljena u pet servisa koji zajedno čine jednu logičku
aplikaciju, ali se razvijaju, skaliraju i osiguravaju neovisno. Dizajn slijedi
*microservice-lite* pristup: jasno odvojene odgovornosti, asinkrona obrada i
mrežna segmentacija po slojevima.

```
                 ┌─────────────┐
   korisnik ───▶ │  frontend   │  (web UI, Express, :3000)
   (browser)     └──────┬──────┘
                        │ HTTP (preko Ingressa /api, lokalno direktno :8080)
                        ▼
                 ┌─────────────┐        LPUSH         ┌─────────────┐
                 │     api     │ ───────────────────▶ │    redis    │
                 │  Express    │                      │  queue/cache│
                 │   :8080     │ ◀──── SELECT ───┐    └──────┬──────┘
                 └─────────────┘                 │           │ BRPOP
                        │                        │           ▼
                        │  INSERT/SELECT         │    ┌─────────────┐
                        └───────────────────────┴──▶ │   worker    │
                                                      │  consumer   │
                                                      └──────┬──────┘
                                                             │ INSERT
                                                             ▼
                                                      ┌─────────────┐
                                                      │  postgres   │
                                                      │  :5432 (PVC)│
                                                      └─────────────┘
```

## 2. Uloge servisa

- **frontend** — Express poslužitelj koji servira statički UI (`index.html`) i
  endpoint `/config` koji pregledniku javlja gdje je API. Nema pristup bazi ni
  Redisu — to je namjerna sigurnosna granica.
- **api** — REST sučelje. Izlaže evente (`/events`), prima kupnju
  (`/tickets/purchase`) koju **ne obrađuje sinkrono** nego stavlja u Redis red
  (`LPUSH`), te čita obrađene narudžbe iz PostgreSQL-a (`/tickets/orders`).
  Nudi `/healthz` (liveness) i `/readyz` (readiness — provjerava DB i Redis).
- **worker** — nema HTTP sučelja. U petlji čeka na poruke iz Redis reda
  (`BRPOP`) i svaku narudžbu trajno upisuje u PostgreSQL. Ovo razdvajanje znači
  da nagli porast kupnji ne ruši API — red apsorbira udar (*backpressure*).
- **postgres** — izvor istine za narudžbe. Perzistencija preko PVC-a (k8s) /
  imenovanog volumena (compose). Schema se postavlja iz `infra/postgres/init.sql`.
- **redis** — brzi red poruka između API-ja i workera te potencijalni cache.

## 3. Međuservisna komunikacija

| Od → Do            | Protokol / mehanizam      | Svrha                          |
|--------------------|---------------------------|--------------------------------|
| browser → frontend | HTTP                      | UI                             |
| browser → api      | HTTP (preko Ingress `/api`)| dohvat evenata, kupnja         |
| api → redis        | RESP (`LPUSH`)            | stavljanje narudžbe u red      |
| worker → redis     | RESP (`BRPOP`)           | preuzimanje narudžbe           |
| api → postgres     | TCP/SQL                   | čitanje obrađenih narudžbi     |
| worker → postgres  | TCP/SQL                   | upis narudžbe                  |

Imena servisa (`postgres`, `redis`, `api`) razrješavaju se internim DNS-om
(Compose mreža odn. Kubernetes Service). Aplikacija ne hardkodira IP adrese.

## 4. Tok podataka (kupnja karte)

1. Korisnik u **frontendu** odabere event i klikne *Purchase*.
2. Preglednik šalje `POST /tickets/purchase` na **API**.
3. **API** validira zahtjev i radi `LPUSH` narudžbe u **Redis** red; odmah vraća
   `202 Accepted` s `orderId` (asinkrono — korisnik ne čeka upis u bazu).
4. **Worker** `BRPOP`-om preuzme narudžbu iz **Redisa**.
5. **Worker** radi `INSERT` u **PostgreSQL** (status `processed`).
6. Korisnik/`api` čita stanje preko `GET /tickets/orders` iz **PostgreSQL-a**.

## 5. Kontejneri vs. virtualne mašine

| Aspekt              | Virtualne mašine                          | Kontejneri                                  |
|---------------------|-------------------------------------------|---------------------------------------------|
| Izolacija           | Cijeli gostujući OS po VM-u (hypervisor)  | Dijele kernel domaćina, izolacija namespacima/cgroupovima |
| Veličina            | GB (OS image)                             | MB (samo aplikacija + runtime)              |
| Vrijeme pokretanja  | Desetci sekundi do minute                 | Milisekunde do sekunde                      |
| Gustoća na hostu    | Niska (težak overhead)                    | Visoka                                      |
| Reproducibilnost    | Image + provisioning skripte              | Deklarativni Containerfile, isti artefakt svuda |
| Overhead            | Visok (svaki VM nosi kernel + OS)         | Nizak (jedan kernel)                        |

VM virtualizira **hardver** i pokreće zaseban kernel; kontejner virtualizira
**OS** i dijeli kernel domaćina, pakirajući samo aplikaciju i njezine ovisnosti.

## 6. Zašto kontejneri za ovaj projekt

- **Pet heterogenih servisa** (Node, PostgreSQL, Redis) — kontejneri svaki
  pakiraju s točno njegovim ovisnostima, bez sukoba verzija na hostu.
- **„Radi kod mene" problem** nestaje: isti image ide iz lokalnog Composea u
  CI i u Kubernetes — *build once, run anywhere*.
- **Brz feedback** u nastavi: cijeli stack se digne jednom naredbom u par
  sekundi, a ruši i čisti jednako lako.
- **Nizak overhead** — student može pokrenuti svih pet servisa na laptopu, što
  s pet VM-ova ne bi bilo praktično.
- **Deklarativnost** — Containerfile i Compose/K8s manifesti su verzionirani i
  ponovljivi, što je preduvjet za CI/CD i sigurnosno skeniranje.

## 7. Sigurnosne prednosti izolacije servisa

- **Mrežna segmentacija u dva sloja** (`web-tier`, `data-tier`): frontend
  fizički ne može doprijeti do baze ni Redisa. Smanjuje *attack surface* —
  kompromitirani frontend ne vodi izravno do podataka.
- **Princip najmanje privilegije**: svaki kontejner radi kao **non-root**, bez
  dodatnih Linux capabilitija (`drop ALL`), s `allowPrivilegeEscalation: false`
  i gdje je izvedivo `readOnlyRootFilesystem`.
- **Razdvajanje konfiguracije i tajni**: ne-tajna konfiguracija je u
  `ConfigMap`, lozinke u `Secret`. Tajne se ne pakiraju u image.
- **Eksplicitne dozvole prometa** (Kubernetes NetworkPolicy, default-deny):
  dozvoljeno je samo frontend→api, api→{postgres,redis}, worker→{postgres,redis};
  sve ostalo je zabranjeno.
- **Manja eksplozija štete (blast radius)**: kompromitacija jednog servisa
  ostaje ograničena na njegov namespace/sloj i njegove minimalne dozvole.

## 8. Mapiranje na ishod I1

Ovaj dokument zajedno s `compose.yaml` pokriva **ishod I1 — procjena
kontejnera i servisa**: identificirani su servisi i njihove uloge, obrazložen je
izbor kontejnera nad VM-ovima, opisana je međuservisna komunikacija i tok
podataka te sigurnosne prednosti izolacije. Vidi i
[outcomes-mapping.md](outcomes-mapping.md).
