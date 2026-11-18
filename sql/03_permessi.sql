-- =====================================================================
-- Permessi sugli oggetti TPL (pums.tpl_*) del DB amm_viab.  FACOLTATIVO.
--
-- NON serve se QGIS/Lizmap e lo script di aggiornamento si collegano
-- con un superuser o con il proprietario dello schema pums.
--
-- Serve solo se si usano ruoli dedicati, non superuser. Indicare i nomi
-- qui sotto; lasciare NULL per saltare quel ruolo. I ruoli indicati che
-- non esistono vengono ignorati con un avviso.
--   loader = utente dello script notturno (legge e scrive i dati)
--   reader = utente con cui QGIS Server/Lizmap legge il DB
--
-- Eseguire DOPO "gtfs_lizmap.py init" e ripetere dopo ogni init
-- (init ricrea le viste e i loro GRANT si perdono).
-- I GRANT riguardano solo gli oggetti tpl_*: il resto di pums non cambia.
-- =====================================================================
DO $$
DECLARE
    loader text := NULL;   -- es. 'gtfs_loader'
    reader text := NULL;   -- es. 'qgis_reader'
    ruolo  text;
    r      record;
BEGIN
    FOREACH ruolo IN ARRAY ARRAY[loader, reader] LOOP
        CONTINUE WHEN ruolo IS NULL;
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ruolo) THEN
            RAISE NOTICE 'ruolo % inesistente: saltato', ruolo;
            CONTINUE;
        END IF;
        IF (SELECT rolsuper FROM pg_roles WHERE rolname = ruolo) THEN
            RAISE NOTICE 'ruolo % è superuser: nessun permesso necessario', ruolo;
            CONTINUE;
        END IF;

        EXECUTE format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', current_database(), ruolo);
        EXECUTE format('GRANT USAGE ON SCHEMA pums TO %I', ruolo);

        FOR r IN SELECT c.relname, c.relkind FROM pg_class c
                  JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'pums' AND c.relname LIKE 'tpl\_%' AND c.relkind IN ('r','v')
        LOOP
            IF ruolo = loader AND r.relkind = 'r' THEN
                EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON pums.%I TO %I', r.relname, ruolo);
            ELSE
                -- il reader legge anche le tabelle: le funzioni del popup
                -- girano con i permessi di chi le chiama (QGIS Server)
                EXECUTE format('GRANT SELECT ON pums.%I TO %I', r.relname, ruolo);
            END IF;
        END LOOP;

        FOR r IN SELECT p.oid::regprocedure AS firma FROM pg_proc p
                  JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'pums' AND p.proname LIKE 'tpl\_%'
        LOOP
            EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', r.firma, ruolo);
        END LOOP;
        RAISE NOTICE 'permessi concessi a %', ruolo;
    END LOOP;
END $$;
