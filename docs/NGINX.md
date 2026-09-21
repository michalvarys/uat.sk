# Nastavení nginx v aaPanelu

Kontejnery poslouchají jen na localhostu. Do internetu je pouští nginx
spravovaný aaPanelem, který zároveň řeší HTTPS.

```
                    ┌──────────────────────────┐
  uat.sk ─────────► │                          │ ──► 127.0.0.1:3000
  cms.uat.sk ─────► │   nginx (aaPanel)        │ ──► 127.0.0.1:1337
  staging.uat.sk ─► │   + Let's Encrypt        │ ──► 127.0.0.1:3001
  staging-cms… ───► │                          │ ──► 127.0.0.1:1338
                    └──────────────────────────┘
```

## Rozdělení portů

| Prostředí | Frontend | Backend | Databáze |
|---|---|---|---|
| produkce | 3000 | 1337 | — (jen v síti) |
| staging | 3001 | 1338 | 5434 |
| dev | 3002 | 1339 | 5433 |

Porty se nastavují v `env/<prostředí>.env` (`FE_PORT`, `BE_PORT`).
Všechny jsou vázané na `127.0.0.1`, takže zvenčí nejsou dostupné.

## Založení webu v panelu

Pro každou doménu zvlášť:

1. **Website → Add site** — zadejte doménu, PHP nastavte na *Pure static*
2. **SSL → Let's Encrypt** — vystavit certifikát, zapnout *Force HTTPS*
3. **Reverse proxy → Add reverse proxy**
   - *Target URL*: `http://127.0.0.1:3001` (podle tabulky výš)
   - *Send domain*: zapnuto

## Doplňková konfigurace

Panel vygeneruje základ sám; následující se přidává do konfigurace webu
(**Website → Config**).

### Staging — frontend

```nginx
# Staging nesmí do vyhledávačů, jinak konkuruje produkci
# duplicitním obsahem.
add_header X-Robots-Tag "noindex, nofollow" always;

# Ochrana heslem. Soubor vytvoříte:
#   htpasswd -c /www/server/panel/vhost/staging.htpasswd uzivatel
auth_basic "Staging";
auth_basic_user_file /www/server/panel/vhost/staging.htpasswd;
```

### Staging — backend (administrace)

```nginx
add_header X-Robots-Tag "noindex, nofollow" always;

# Strapi nahrává soubory, výchozí limit 1 MB nestačí.
client_max_body_size 200M;
```

> **Bez `auth_basic`.** Administrace má vlastní přihlášení a basic auth
> by rozbila volání API z frontendu.

### Produkce — backend

```nginx
client_max_body_size 200M;
```

### Všechna prostředí

Panel obvykle tyto hlavičky nastaví sám. Ověřte, že v konfiguraci jsou —
bez nich Strapi i Next.js špatně poznají původní adresu a protokol:

```nginx
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

# Bez toho nefunguje websocket v administraci Strapi.
proxy_http_version 1.1;
proxy_set_header Upgrade    $http_upgrade;
proxy_set_header Connection "upgrade";
```

## Ověření

```bash
# kontejnery odpovídají?
curl -s -o /dev/null -w "frontend %{http_code}\n" http://127.0.0.1:3001/
curl -s -o /dev/null -w "backend  %{http_code}\n" http://127.0.0.1:1338/admin

# projde to přes nginx?
curl -s -o /dev/null -w "%{http_code}\n" https://staging.uat.sk/

# basic auth funguje?
curl -s -o /dev/null -w "bez hesla: %{http_code} (čekáme 401)\n" https://staging.uat.sk/
```

`./scripts/status.sh` ukazuje obojí odděleně — když kontejner odpovídá
a doména ne, chyba je v nginxu, ne v aplikaci.

## Časté potíže

**502 Bad Gateway**
Kontejner neběží nebo poslouchá na jiném portu.
```bash
docker ps | grep uat-staging
ss -ltnp | grep -E '3001|1338'
```

**Strapi generuje odkazy na localhost**
Chybí `URL` v prostředí kontejneru. Nastavuje se v `base.yml`
z `BE_DOMAIN`, takže zkontrolujte `env/<prostředí>.env`.

**Nahrání souboru skončí chybou 413**
Chybí `client_max_body_size` v konfiguraci backendu.

**Let's Encrypt nevydá certifikát**
Doména nemá A záznam na tento server, nebo port 80 neodpovídá.
