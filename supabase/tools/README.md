# Local audit tools (not part of the app, never deployed)

A throwaway PostgreSQL 18 (pip: `pixeltable-pgserver psycopg2-binary pglast`) with Supabase stubs
(`auth.uid()`, roles, realtime publication). Paths inside the scripts point at /tmp/s: copy them there or edit.

- `harness.py`  build a fresh DB and apply 0001-00xx in order (0002 demo seed is applied separately)
- `fixtures.sql` extra nicknames + poems so every self-test has data
- `rt.py`       run any self-test file against that DB (`python3 rt.py tests/audit_selftest.sql`)
- `lint.py`     parse every migration + test with the real Postgres parser (SQL and plpgsql)
- `race.py`     parallel claims / opens / ensure / votes / fragment grants (needs committed fixtures)
- `sim.py`      Monte Carlo of Gauntlet earning speed on the REAL engine: `python3 sim.py <weeks> <runs> [weekly_cap]`

- `build_pet_images.py`  embeds `character-images/pet/*.png` into index.html as small WebP (`const PET_IMAGES`); re-run after adding or replacing a pet image
