-- =====================================================================
-- Funzioni e viste per Lizmap (schema pums, prefisso tpl_).
-- Fuso orario: Europe/Rome. Gli orari GTFS sono relativi al "mezzogiorno
-- meno 12 ore" del giorno di servizio (corretto anche nei cambi d'ora)
-- e possono superare le 24:00 (corse notturne del giorno precedente).
-- =====================================================================

-- Servizi (service_id) attivi in una data, per un feed
CREATE OR REPLACE FUNCTION pums.tpl_servizi_attivi(p_feed text, p_data date)
RETURNS TABLE (service_id text)
LANGUAGE sql STABLE AS $$
    SELECT c.service_id
      FROM pums.tpl_calendar c
     WHERE c.feed_id = p_feed
       AND p_data BETWEEN c.start_date AND c.end_date
       AND CASE extract(isodow FROM p_data)::int
             WHEN 1 THEN c.lun WHEN 2 THEN c.mar WHEN 3 THEN c.mer
             WHEN 4 THEN c.gio WHEN 5 THEN c.ven WHEN 6 THEN c.sab
             ELSE c.dom END
    UNION
    SELECT cd.service_id FROM pums.tpl_calendar_dates cd
     WHERE cd.feed_id = p_feed AND cd.date = p_data AND cd.exception_type = 1
    EXCEPT
    SELECT cd.service_id FROM pums.tpl_calendar_dates cd
     WHERE cd.feed_id = p_feed AND cd.date = p_data AND cd.exception_type = 2
$$;

-- Partenze da una fermata (o da una stazione e dai suoi binari) attorno a un istante.
-- stato: 'partita' | 'prossima' | 'in_arrivo'
CREATE OR REPLACE FUNCTION pums.tpl_partenze(
    p_feed       text,
    p_stop       text,
    p_ora        timestamptz DEFAULT now(),
    p_prima      integer     DEFAULT 2,
    p_dopo       integer     DEFAULT 8,
    p_orizzonte  interval    DEFAULT interval '12 hours'
)
RETURNS TABLE (
    partenza      timestamptz,
    minuti        integer,
    stato         text,
    linea         text,
    colore        text,
    colore_testo  text,
    route_type    integer,
    destinazione  text,
    numero_corsa  text,
    binario       text
)
LANGUAGE sql STABLE AS $$
WITH giorni AS (
    SELECT ((p_ora AT TIME ZONE 'Europe/Rome')::date + k) AS giorno
      FROM generate_series(-1, 1) AS k
),
attivi AS (
    SELECT g.giorno, s.service_id
      FROM giorni g CROSS JOIN LATERAL pums.tpl_servizi_attivi(p_feed, g.giorno) s
),
fermate AS (
    SELECT s.stop_id, s.platform_code
      FROM pums.tpl_stops s
     WHERE s.feed_id = p_feed AND (s.stop_id = p_stop OR s.parent_station = p_stop)
),
candidate AS (
    SELECT ((a.giorno + time '12:00') AT TIME ZONE 'Europe/Rome')
             - interval '12 hours' + make_interval(secs => st.dep_s) AS ts,
           r.route_short_name, r.route_long_name, r.route_color, r.route_text_color, r.route_type,
           coalesce(nullif(t.trip_headsign, ''), t.ultima_fermata) AS dest,
           t.trip_short_name, f.platform_code
      FROM pums.tpl_stop_times st
      JOIN fermate f      ON f.stop_id = st.stop_id
      JOIN pums.tpl_trips t   ON t.feed_id = st.feed_id AND t.trip_id = st.trip_id
      JOIN attivi a       ON a.service_id = t.service_id
      JOIN pums.tpl_routes r  ON r.feed_id = t.feed_id AND r.route_id = t.route_id
     WHERE st.feed_id = p_feed
       AND NOT st.capolinea_fin                 -- qui la corsa termina: non è una partenza
       AND coalesce(st.pickup_type, 0) <> 1     -- salita non consentita
),
finestra AS (
    SELECT * FROM candidate
     WHERE ts >= p_ora - interval '3 hours' AND ts < p_ora + p_orizzonte
),
passate AS (SELECT * FROM finestra WHERE ts <  p_ora ORDER BY ts DESC LIMIT p_prima),
future  AS (SELECT * FROM finestra WHERE ts >= p_ora ORDER BY ts      LIMIT p_dopo),
tutte AS (SELECT * FROM passate UNION ALL SELECT * FROM future)
SELECT ts,
       floor(extract(epoch FROM ts - p_ora) / 60)::int,
       CASE WHEN ts < p_ora THEN 'partita'
            WHEN ts = min(ts) FILTER (WHERE ts >= p_ora) OVER () THEN 'prossima'
            ELSE 'in_arrivo' END,
       coalesce(nullif(route_short_name, ''), route_long_name),
       coalesce(nullif(route_color, ''),
                CASE WHEN route_type = 2 THEN 'C2185B' ELSE '0066CC' END),
       coalesce(nullif(route_text_color, ''), 'FFFFFF'),
       route_type, dest, trip_short_name, platform_code
  FROM tutte
 ORDER BY ts
$$;

-- Escape HTML
CREATE OR REPLACE FUNCTION pums.tpl_h(t text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT replace(replace(replace(replace(coalesce(t, ''),
           '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')
$$;

-- Badge di una linea (colore GTFS inline: funziona anche senza CSS)
CREATE OR REPLACE FUNCTION pums.tpl_badge(p_testo text, p_colore text, p_testo_col text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT format('<span class="tpl-badge" style="background:#%s;color:#%s">%s</span>',
                  coalesce(nullif(p_colore, ''), '0066CC'),
                  coalesce(nullif(p_testo_col, ''), 'FFFFFF'),
                  pums.tpl_h(p_testo))
$$;

-- HTML del popup di una palina/stazione. È ricalcolato a ogni clic
-- (GetFeatureInfo di QGIS Server), quindi l'ora è sempre quella attuale.
CREATE OR REPLACE FUNCTION pums.tpl_popup_html(
    p_feed text, p_stop text, p_ora timestamptz DEFAULT now()
) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    s        record;
    p        record;
    f        record;
    righe    text := '';
    linee    text;
    eta      text;
    is_treno boolean;
    icona    text;
    ora_loc  timestamp := p_ora AT TIME ZONE 'Europe/Rome';
    giorni   text[] := ARRAY['lunedì','martedì','mercoledì','giovedì','venerdì','sabato','domenica'];
    mesi     text[] := ARRAY['gennaio','febbraio','marzo','aprile','maggio','giugno','luglio',
                             'agosto','settembre','ottobre','novembre','dicembre'];
BEGIN
    SELECT * INTO s FROM pums.tpl_stops WHERE feed_id = p_feed AND stop_id = p_stop;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT * INTO f FROM pums.tpl_feed WHERE feed_id = p_feed;

    -- Linee che servono la fermata (indipendentemente dall'ora)
    SELECT string_agg(pums.tpl_badge(x.l,
                        coalesce(nullif(x.route_color, ''),
                                 CASE WHEN x.route_type = 2 THEN 'C2185B' ELSE '0066CC' END),
                        x.route_text_color), ' '
                      ORDER BY x.route_sort_order NULLS LAST, x.l),
           bool_or(x.route_type = 2)
      INTO linee, is_treno
      FROM (SELECT DISTINCT coalesce(nullif(r.route_short_name,''), r.route_long_name) AS l,
                   r.route_color, r.route_text_color, r.route_sort_order, r.route_type
              FROM pums.tpl_stop_times st
              JOIN pums.tpl_stops fs ON fs.feed_id = st.feed_id AND fs.stop_id = st.stop_id
              JOIN pums.tpl_trips t  ON t.feed_id = st.feed_id AND t.trip_id = st.trip_id
              JOIN pums.tpl_routes r ON r.feed_id = t.feed_id AND r.route_id = t.route_id
             WHERE st.feed_id = p_feed
               AND (fs.stop_id = p_stop OR fs.parent_station = p_stop)) x;

    icona := CASE WHEN is_treno THEN
      '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path fill="currentColor" d="M12 2c-4 0-8 .5-8 4v9.5A3.5 3.5 0 0 0 7.5 19L6 20.5v.5h2.2l2-2h3.6l2 2H18v-.5L16.5 19a3.5 3.5 0 0 0 3.5-3.5V6c0-3.5-4-4-8-4zM7.5 17a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3zm3.5-7H6V6h5v4zm2 0V6h5v4h-5zm3.5 7a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3z"/></svg>'
    ELSE
      '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path fill="currentColor" d="M4 16c0 .9.4 1.7 1 2.2V20a1 1 0 0 0 1 1h1a1 1 0 0 0 1-1v-1h8v1a1 1 0 0 0 1 1h1a1 1 0 0 0 1-1v-1.8c.6-.5 1-1.3 1-2.2V6c0-3.5-3.6-4-8-4s-8 .5-8 4v10zm3.5 1a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3zm9 0a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3zm1.5-6H6V6h12v5z"/></svg>'
    END;

    FOR p IN SELECT * FROM pums.tpl_partenze(p_feed, p_stop, p_ora) LOOP
        eta := CASE p.stato
                 WHEN 'partita' THEN 'partito'
                 ELSE CASE WHEN p.minuti < 1 THEN 'ora'
                           WHEN p.minuti < 60 THEN 'tra ' || p.minuti || ' min'
                           ELSE 'tra ' || (p.minuti / 60) || ' h ' || lpad((p.minuti % 60)::text, 2, '0') END
               END;
        righe := righe || format(
            '<div class="tpl-row tpl-%s"%s>'
              || '<span class="tpl-time">%s</span>'
              || '%s'
              || '<span class="tpl-dest">%s%s</span>'
              || '<span class="tpl-eta">%s</span></div>',
            p.stato,
            CASE p.stato WHEN 'prossima' THEN ' style="border-left:4px solid #0066CC;background:#E6F0FA"'
                         WHEN 'partita'  THEN ' style="opacity:.55"' ELSE '' END,
            to_char(p.partenza AT TIME ZONE 'Europe/Rome', 'HH24:MI'),
            pums.tpl_badge(p.linea, p.colore, p.colore_testo),
            pums.tpl_h(p.destinazione),
            CASE WHEN p.numero_corsa IS NOT NULL OR p.binario IS NOT NULL THEN
                 '<small class="tpl-meta">'
                 || concat_ws(' · ',
                      CASE WHEN is_treno AND p.numero_corsa IS NOT NULL THEN 'treno ' || pums.tpl_h(p.numero_corsa) END,
                      CASE WHEN p.binario IS NOT NULL THEN 'bin. ' || pums.tpl_h(p.binario) END)
                 || '</small>' ELSE '' END,
            eta);
    END LOOP;

    IF righe = '' THEN
        righe := '<div class="tpl-empty">Nessuna partenza programmata nelle prossime 12 ore.</div>';
    END IF;

    RETURN '<div class="tpl-popup">'
      || '<div class="tpl-head"><span class="tpl-ico">' || icona || '</span><div>'
      ||   '<div class="tpl-title">' || pums.tpl_h(initcap(lower(s.stop_name))) || '</div>'
      ||   '<div class="tpl-sub">'
      ||     concat_ws(' · ',
               CASE WHEN s.stop_code IS NOT NULL THEN
                    CASE WHEN is_treno THEN 'Stazione ' ELSE 'Palina ' END || pums.tpl_h(s.stop_code) END,
               pums.tpl_h(f.nome))
      ||   '</div></div></div>'
      || CASE WHEN linee IS NOT NULL THEN '<div class="tpl-lines">' || linee || '</div>' ELSE '' END
      || '<div class="tpl-when">Partenze attorno alle <strong>' || to_char(ora_loc, 'HH24:MI') || '</strong> di '
      ||   giorni[extract(isodow FROM ora_loc)::int] || ' ' || extract(day FROM ora_loc)::int || ' '
      ||   mesi[extract(month FROM ora_loc)::int] || '</div>'
      || '<div class="tpl-list">' || righe || '</div>'
      || '<div class="tpl-foot">Orario programmato, non in tempo reale'
      ||   CASE WHEN f.valido_al IS NOT NULL THEN ' · dati validi fino al ' || to_char(f.valido_al, 'DD/MM/YYYY') ELSE '' END
      ||   CASE WHEN f.valido_al IS NOT NULL AND f.valido_al < ora_loc::date
                THEN ' <strong class="tpl-warn">— dati scaduti</strong>' ELSE '' END
      || '</div></div>';
END;
$$;

-- ---------------------------------------------------------------------
-- Layer per QGIS / Lizmap
-- ---------------------------------------------------------------------

-- Paline e stazioni (i binari figli di una stazione non si mostrano:
-- le loro partenze compaiono nel popup della stazione)
DROP VIEW IF EXISTS pums.tpl_v_paline;
CREATE VIEW pums.tpl_v_paline AS
-- id stabile tra un aggiornamento e l'altro (niente window function:
-- permette a PostgreSQL di calcolare popup_html solo per le righe richieste)
SELECT hashtext(s.feed_id || '/' || s.stop_id) AS id,
       s.feed_id, s.stop_id, s.stop_code, s.stop_name,
       CASE WHEN EXISTS (
              SELECT 1 FROM pums.tpl_stop_times st
                JOIN pums.tpl_stops fs ON fs.feed_id = st.feed_id AND fs.stop_id = st.stop_id
                JOIN pums.tpl_trips t  ON t.feed_id = st.feed_id AND t.trip_id = st.trip_id
                JOIN pums.tpl_routes r ON r.feed_id = t.feed_id AND r.route_id = t.route_id
               WHERE st.feed_id = s.feed_id AND r.route_type = 2
                 AND (fs.stop_id = s.stop_id OR fs.parent_station = s.stop_id))
            THEN 'treno' ELSE 'bus' END AS tipo,
       (SELECT string_agg(DISTINCT coalesce(nullif(r.route_short_name,''), r.route_long_name), ', ')
          FROM pums.tpl_stop_times st
          JOIN pums.tpl_stops fs ON fs.feed_id = st.feed_id AND fs.stop_id = st.stop_id
          JOIN pums.tpl_trips t  ON t.feed_id = st.feed_id AND t.trip_id = st.trip_id
          JOIN pums.tpl_routes r ON r.feed_id = t.feed_id AND r.route_id = t.route_id
         WHERE st.feed_id = s.feed_id
           AND (fs.stop_id = s.stop_id OR fs.parent_station = s.stop_id)) AS linee,
       pums.tpl_popup_html(s.feed_id, s.stop_id) AS popup_html,
       s.geom
  FROM pums.tpl_stops s
 WHERE s.parent_station IS NULL OR s.parent_station = '';

-- Percorsi delle linee che servono il territorio (una geometria per linea/shape)
DROP VIEW IF EXISTS pums.tpl_v_linee;
CREATE VIEW pums.tpl_v_linee AS
SELECT hashtext(x.feed_id || '/' || x.route_id || '/' || x.shape_id) AS id, x.*
  FROM (
    SELECT DISTINCT ON (t.feed_id, t.route_id, t.shape_id)
           t.feed_id, t.route_id, t.shape_id,
           coalesce(nullif(r.route_short_name,''), r.route_long_name) AS linea,
           r.route_long_name AS descrizione,
           a.agency_name AS gestore,
           '#' || coalesce(nullif(r.route_color,''),
                    CASE WHEN r.route_type = 2 THEN 'C2185B' ELSE '0066CC' END) AS colore,
           CASE WHEN r.route_type = 2 THEN 'treno' ELSE 'bus' END AS tipo,
           sh.geom
      FROM pums.tpl_trips t
      JOIN pums.tpl_routes r  ON r.feed_id = t.feed_id AND r.route_id = t.route_id
      LEFT JOIN pums.tpl_agency a ON a.feed_id = r.feed_id AND a.agency_id = r.agency_id
      JOIN pums.tpl_shapes sh ON sh.feed_id = t.feed_id AND sh.shape_id = t.shape_id
     ORDER BY t.feed_id, t.route_id, t.shape_id
  ) x;

-- Stato dei feed (utile come tabella in Lizmap o per il monitoraggio)
CREATE OR REPLACE VIEW pums.tpl_v_stato_feed AS
SELECT feed_id, nome, esito, messaggio, scaricato_il, valido_dal, valido_al,
       valido_al - (now() AT TIME ZONE 'Europe/Rome')::date AS giorni_residui
  FROM pums.tpl_feed;
