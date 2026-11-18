-- =====================================================================
-- Tabelle TPL (GTFS) per Lizmap - DB amm_viab, schema pums, prefisso tpl_
-- Idempotente: si può rieseguire senza perdere dati.
-- feed_id distingue i feed (at, trenitalia, ...) perché gli id GTFS
-- di feed diversi possono coincidere.
-- =====================================================================
-- Estensione e schema solo se mancano: così init funziona anche con un
-- utente senza permesso CREATE sul database (es. proprietario di pums)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis') THEN
        CREATE EXTENSION postgis;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'pums') THEN
        CREATE SCHEMA pums;
    END IF;
END $$;

-- Indici con nomi generici creati da una prima versione del DDL:
-- li rinomino con prefisso tpl_ per evitare collisioni con altre tabelle di pums
ALTER INDEX IF EXISTS pums.stops_geom_idx          RENAME TO tpl_stops_geom_idx;
ALTER INDEX IF EXISTS pums.stops_parent_idx        RENAME TO tpl_stops_parent_idx;
ALTER INDEX IF EXISTS pums.trips_service_idx       RENAME TO tpl_trips_service_idx;
ALTER INDEX IF EXISTS pums.stop_times_stop_idx     RENAME TO tpl_stop_times_stop_idx;
ALTER INDEX IF EXISTS pums.calendar_dates_date_idx RENAME TO tpl_calendar_dates_date_idx;
ALTER INDEX IF EXISTS pums.shapes_geom_idx         RENAME TO tpl_shapes_geom_idx;

-- Stato di ogni feed: quando è stato caricato, validità, esito
CREATE TABLE IF NOT EXISTS pums.tpl_feed (
    feed_id        text PRIMARY KEY,
    nome           text,
    url            text,
    scaricato_il   timestamptz,
    sha256         text,
    valido_dal     date,
    valido_al      date,
    esito          text,
    messaggio      text
);

CREATE TABLE IF NOT EXISTS pums.tpl_agency (
    feed_id     text NOT NULL,
    agency_id   text NOT NULL,
    agency_name text,
    agency_url  text,
    PRIMARY KEY (feed_id, agency_id)
);

CREATE TABLE IF NOT EXISTS pums.tpl_stops (
    feed_id             text NOT NULL,
    stop_id             text NOT NULL,
    stop_code           text,
    stop_name           text,
    location_type       smallint DEFAULT 0,
    parent_station      text,
    wheelchair_boarding smallint,
    platform_code       text,
    geom                geometry(Point, 4326),
    PRIMARY KEY (feed_id, stop_id)
);
CREATE INDEX IF NOT EXISTS tpl_stops_geom_idx   ON pums.tpl_stops USING gist (geom);
CREATE INDEX IF NOT EXISTS tpl_stops_parent_idx ON pums.tpl_stops (feed_id, parent_station);

CREATE TABLE IF NOT EXISTS pums.tpl_routes (
    feed_id          text NOT NULL,
    route_id         text NOT NULL,
    agency_id        text,
    route_short_name text,
    route_long_name  text,
    route_type       integer,
    route_color      text,
    route_text_color text,
    route_sort_order integer,
    PRIMARY KEY (feed_id, route_id)
);

CREATE TABLE IF NOT EXISTS pums.tpl_trips (
    feed_id         text NOT NULL,
    trip_id         text NOT NULL,
    route_id        text NOT NULL,
    service_id      text NOT NULL,
    trip_headsign   text,
    trip_short_name text,
    direction_id    smallint,
    shape_id        text,
    wheelchair_accessible smallint,
    ultima_fermata  text,          -- calcolata in import, serve se headsign è vuoto
    PRIMARY KEY (feed_id, trip_id)
);
CREATE INDEX IF NOT EXISTS tpl_trips_service_idx ON pums.tpl_trips (feed_id, service_id);

-- Solo i passaggi alle fermate del territorio (orari in secondi dalla
-- "mezzanotte di servizio": possono superare 86400, es. 26:52 = 96720)
CREATE TABLE IF NOT EXISTS pums.tpl_stop_times (
    feed_id        text NOT NULL,
    trip_id        text NOT NULL,
    stop_id        text NOT NULL,
    stop_sequence  integer NOT NULL,
    arr_s          integer,
    dep_s          integer,
    pickup_type    smallint DEFAULT 0,
    drop_off_type  smallint DEFAULT 0,
    capolinea_fin  boolean DEFAULT false,  -- ultima fermata della corsa
    PRIMARY KEY (feed_id, trip_id, stop_sequence)
);
CREATE INDEX IF NOT EXISTS tpl_stop_times_stop_idx ON pums.tpl_stop_times (feed_id, stop_id, dep_s);

CREATE TABLE IF NOT EXISTS pums.tpl_calendar (
    feed_id    text NOT NULL,
    service_id text NOT NULL,
    lun boolean, mar boolean, mer boolean, gio boolean,
    ven boolean, sab boolean, dom boolean,
    start_date date, end_date date,
    PRIMARY KEY (feed_id, service_id)
);

CREATE TABLE IF NOT EXISTS pums.tpl_calendar_dates (
    feed_id        text NOT NULL,
    service_id     text NOT NULL,
    date           date NOT NULL,
    exception_type smallint NOT NULL,   -- 1 = aggiunto, 2 = soppresso
    PRIMARY KEY (feed_id, service_id, date)
);
CREATE INDEX IF NOT EXISTS tpl_calendar_dates_date_idx ON pums.tpl_calendar_dates (date);

CREATE TABLE IF NOT EXISTS pums.tpl_shapes (
    feed_id  text NOT NULL,
    shape_id text NOT NULL,
    geom     geometry(LineString, 4326),
    PRIMARY KEY (feed_id, shape_id)
);
CREATE INDEX IF NOT EXISTS tpl_shapes_geom_idx ON pums.tpl_shapes USING gist (geom);

-- Confine del territorio (caricato dallo script da GeoJSON o da query)
CREATE TABLE IF NOT EXISTS pums.tpl_territorio (
    id   integer PRIMARY KEY DEFAULT 1,
    nome text,
    geom geometry(MultiPolygon, 4326)
);
