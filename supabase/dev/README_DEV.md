# Office Lore — DEV omgeving (veilig testen vóór productie)

Een apart Supabase-project met alle migraties (0001 t/m 0081). De app op `localhost` kan er met één commando naartoe wisselen.
Productie en QuestNest worden niet aangeraakt: een nieuw project heeft een eigen database en eigen accounts.

## Opzetten (±15 minuten, 1 keer)
1. supabase.com → **New project** (gratis), noem het bv. `office-lore-dev`. Wacht tot het klaar is.
2. **Authentication → Providers → Email → "Confirm email" uitzetten.**
3. **SQL Editor**: plak en run, in volgorde, elk bestand **1 keer** (nieuwe query per bestand):
   `dev_1_0001-0036.sql`, `dev_2_0037-0045.sql`, `dev_3_0046-0051.sql`, `dev_4_0052-0077.sql`, `dev_5_0078-0081.sql`
   (gemaakt met `supabase/tools/build_dev_bundle.py`; opnieuw maken kan altijd, bv. na een nieuwe migratie)
4. **Project Settings → API**: kopieer de *Project URL* en de *publishable key*.
5. Open **http://localhost:8796**, open de browserconsole (F12 of Cmd+Option+J) en typ:
   `olUseDev('https://JOUWPROJECT.supabase.co', 'sb_publishable_...')`
   (Blijft het label rood? Doe een harde herlaad: Cmd+Shift+R. De pagina is groot en wordt soms uit de cache getoond.)
   De pagina herlaadt met een **groen label linksonder: "🧪 DEV DATABASE"**. Rood label ("localhost · PRODUCTION data") = je zit op echte data.
6. Klik 3 keer op **Registreren** (log tussendoor uit) met bv. `elien@dev.test`, `nick@dev.test`, `atti@dev.test` en een wachtwoord dat je nergens anders gebruikt.
7. SQL Editor (dev): run `dev_grant_access.sql` en daarna `dev_seed.sql` (demo-nicknames, bieren, sessies).
8. Log in. Klaar: je ziet de volledige nieuwe app met testdata.

## Handig tijdens het testen
- `dev_test_knobs.sql`: pets en outfits vallen bijna bij elke claim, zodat je ze snel ziet.
- Met meerdere mensen tegelijk (Group Dailies/Quests, Group Quests, battles): gebruik een **privévenster of een ander browserprofiel per account**; ze delen anders je sessie.
- Terug naar productie-data: `olUseProd()` in de console.
- De DEV-schakelaar werkt alleen op `localhost`; op de echte website doet hij niets.

## Opruimen
Klaar met testen? Verwijder het dev-project in Supabase. Er staat niets van productie in.
