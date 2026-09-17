# UAT — infrastruktura

Compose soubory a skripty pro provoz webu SŠUPAT na jednom VPS.
Běží tu tři prostředí vedle sebe: **produkce**, **staging** a **dev**.

## Jak to funguje

```
                    ┌─────────────────────────────┐
  uat.sk ─────────► │                             │ ──► produkce
  staging.uat.sk ─► │   Traefik (porty 80, 443)   │ ──► staging
  dev.uat.sk ─────► │                             │ ──► dev
                    └─────────────────────────────┘
```

Porty 80 a 443 může držet jen jeden proces, takže všechna prostředí
sdílejí jeden Traefik a rozlišují se doménou. Každé prostředí má vlastní
databázi, uploady, síť i jméno projektu, takže si navzájem nesahají
na data.

Aplikace se **nestaví na serveru** — nasazují se hotové image z Docker
Hubu. Zdrojové repozitáře jsou tu jako submodules jen kvůli přehledu
a možnosti sáhnout do kódu.

## Struktura

```
compose/
  base.yml          společný základ (databáze, Strapi, Next.js)
  production.yml    ⎫
  staging.yml       ⎬ overlaye — domény, porty, odlišnosti
  dev.yml           ⎭
  proxy.yml         sdílený Traefik

scripts/
  lib.sh            sdílené funkce
  deploy.sh         nasazení do prostředí
  promote.sh        staging → produkce
  refresh-staging.sh  staging z produkčních dat
  backup.sh         záloha
  status.sh         přehled prostředí
  logs.sh           logy
  proxy.sh          správa Traefiku

env/
  example.env       šablona; skutečné *.env do gitu nepatří

apps/
  frontend          submodule (uat-frontend)
  backend           submodule (uat-admin-v4)
```

## První spuštění na serveru

```bash
git clone --recurse-submodules <url-tohoto-repa> /srv/uat/infra
cd /srv/uat/infra

# konfigurace pro každé prostředí
cp env/example.env env/production.env
cp env/example.env env/staging.env
$EDITOR env/production.env   # domény, hesla, klíče

# klíče pro Strapi: openssl rand -base64 32
# heslo pro staging:  htpasswd -nb uzivatel heslo   (znak $ zdvojit na $$)

mkdir -p /srv/uat/{production,staging}/{db,uploads}

./scripts/proxy.sh up          # jednou, sdílený Traefik
./scripts/deploy.sh --prod --tag v2.0.0
./scripts/deploy.sh --staging
```

**Než pustíte proxy**, musí mít všechny domény A záznam na tento server —
Let's Encrypt jinak certifikát nevydá.

## Běžná práce

### Otestovat novou verzi a pustit ji na produkci

```bash
# 1. staging naplnit aktuálními daty z produkce
./scripts/refresh-staging.sh

# 2. nasadit novou verzi na staging
./scripts/deploy.sh --staging --tag v2.1.0

# 3. otestovat na https://staging.uat.sk

# 4. povýšit na produkci
./scripts/promote.sh --as v2.1.0
```

Promote odešle **bitově shodný image**, jaký běžel na stagingu — jen ho
přeznačí. Produkce tak dostane přesně to, co prošlo testem, ne nový
build ze stejného tagu.

### Další

```bash
./scripts/status.sh                        # co kde běží
./scripts/logs.sh --prod strapi            # logy backendu
./scripts/backup.sh --prod                 # ruční záloha
./scripts/deploy.sh --prod --rollback      # zpět na předchozí verzi
./scripts/promote.sh --check               # co běží kde, bez zásahu
```

Každý skript má `--help` a většina i `--dry-run`.

## Zálohy

Před nasazením na produkci se **vždy** pořídí záloha databáze.
Ruční záloha: `./scripts/backup.sh --prod`.

Skript kontroluje, že dump není prázdný, poškozený ani useknutý —
falešná záloha je horší než žádná, protože se na ni spoléháte.

**Uploady se ve výchozím stavu nezálohují.** Je jich přes 9 GB a mění se
pomalu; kopírovat je při každém nasazení by trvalo zbytečně dlouho.
Pro ně použijte `--with-files` nebo samostatný plán (rsync na jiný stroj,
snapshot úložiště).

Zálohy se ukládají do `backups/<prostředí>/`, drží se posledních 14
(`--keep N`).

## Bezpečnostní zásady

Několik věcí je nastavených schválně:

- **Produkční databáze nemá port ven.** Přístup jen přes `docker exec`.
  Staging a dev port mají, kvůli ladění.
- **Staging je za heslem** a posílá `X-Robots-Tag: noindex` — nesmí
  konkurovat produkci v vyhledávačích.
- **Nasazení na produkci se ptá** a v neinteraktivním běhu skončí chybou,
  aby neproběhlo omylem ze skriptu nebo CI.
- **Každé prostředí má vlastní klíče.** Produkční `APP_KEYS` a JWT
  secrets nepatří na staging.
- **Soubory `env/*.env` nejsou v gitu.** Na server je dostanete ručně
  (`scp`) nebo přes správce tajemství.

## Když se něco pokazí

```bash
./scripts/deploy.sh --prod --rollback
```

Vrátí předchozí image. **Databázi nevrací** — pokud je potřeba i ta,
obnovte ji ze zálohy:

```bash
zcat backups/production/db-<datum>.sql.gz \
  | docker exec -i -e PGPASSWORD=<heslo> uat-production-db \
    psql -U uat_user -d uat_cms
```

## Submodules

```bash
git submodule update --remote apps/frontend   # aktualizovat na nejnovější
git add apps/frontend && git commit -m "..."  # zapsat verzi
```

Submodule ukazuje na konkrétní commit, takže repozitář si pamatuje,
který stav aplikace odpovídá které verzi infrastruktury. Po `git clone`
nezapomeňte na `--recurse-submodules`.
