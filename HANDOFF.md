# Office Lore — overdracht naar Claude Code + Vercel + Supabase

## Status

- `index.html` — de volledige app (UI, styling, alle features). Werkt nu nog met lokale mock-data (`APP_DATA`), niet met Supabase.
- `01_office_lore_schema.sql` — het volledige Supabase-schema (tabellen, RLS-policies, XP-triggers, seed-data) dat we in dit gesprek hebben voorbereid. Nog niet uitgevoerd in een echt Supabase-project.

**Nog te doen (Fase 2 en verder, in Claude Code):**
1. Supabase-project aanmaken + `01_office_lore_schema.sql` uitvoeren + 3 accounts aanmaken (zie stappen hieronder — dit staat los van welke tool je gebruikt).
2. `index.html` ombouwen: Supabase Auth inpluggen (login/logout/wachtwoord vergeten), het "Who enters the Lore?"-gatescherm vervangen door een echt login-scherm, en alle databronnen (nicknames, quotes, anecdotes, counters, beer club) laten praten met Supabase i.p.v. de lokale `APP_DATA`-array.
3. Realtime-subscriptions toevoegen.
4. Deployen op Vercel.

---

## Stap 1 — Claude Code installeren

**macOS / Linux:**
```bash
curl -fsSL https://claude.ai/install.sh | bash
```

**Windows (PowerShell):**
```powershell
irm https://claude.ai/install.ps1 | iex
```

Liever geen terminal-commando's? Download de desktop-app via [code.claude.com](https://code.claude.com).

Daarna: open een terminal, `cd` naar een lege projectmap, typ `claude`, en log in via de browser die automatisch opent.

## Stap 2 — Project opzetten

```bash
mkdir office-lore
cd office-lore
git init
```

Zet `index.html` en `01_office_lore_schema.sql` (beide bijgevoegd in dit gesprek) in deze map. Start daar `claude` op.

Geef Claude Code dan gewoon deze context mee (kort samengevat, of plak dit hele bestand): *"Dit is de Office Lore-app. Ik wil ze koppelen aan Supabase — Auth, database, RLS en realtime, zoals uitgewerkt in `01_office_lore_schema.sql`. Behoud alle bestaande UI/styling/functionaliteit."* Claude Code kan vanaf daar verder bouwen, exact zoals we hier deden — alleen nu rechtstreeks op je eigen computer, met git.

## Stap 3 — Supabase (kan al vóór of tijdens stap 2)

1. Nieuw project op [supabase.com](https://supabase.com) (gratis tier).
2. **Authentication → Users → Add user**: maak 3 accounts (`elien@officelore.app`, `nick@officelore.app`, `atti@officelore.app`, of jullie echte mails — pas dan sectie 10 van het SQL-bestand aan).
3. **SQL Editor**: plak en run `01_office_lore_schema.sql` volledig.
4. **Project Settings → API**: kopieer de **Project URL** en **anon/public key**. Deze plak je straks in de config van `index.html` (nooit de service_role key).

## Stap 4 — GitHub + Vercel

```bash
git add .
git commit -m "Initial commit: Office Lore + Supabase schema"
```

Maak een repo op GitHub (via [github.com/new](https://github.com/new) of `gh repo create`), en:
```bash
git remote add origin <jouw-repo-url>
git push -u origin main
```

Vercel:
- Ga naar [vercel.com/new](https://vercel.com/new), importeer de GitHub-repo → Deploy. Geen buildstap nodig, het is een statisch bestand.
- Of via CLI: `npm i -g vercel` → `vercel` in de projectmap → volg de prompts.
- Voeg de Supabase URL/key toe als Environment Variables in Vercel (Project Settings → Environment Variables) zodra de app ze uit `import.meta.env` of een config-bestand leest — Claude Code kan dat mee opzetten in stap 2.

---

Alles wat hierboven staat is ook gewoon uit te voeren terwijl je met mij hier verder praat, mocht je toch liever hier blijven — maar aangezien je koos voor Claude Code, is dit de volledige route van hier tot een live app op een eigen domein.
