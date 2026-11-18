#!/usr/bin/env python3
"""
gtfs_lizmap.py - Carica i feed GTFS regionali (Autolinee Toscane, Trenitalia...)
in PostGIS, filtrati sul territorio comunale, per i popup "prossime partenze"
in QGIS/Lizmap.

Comandi:
  check     [--scarica]          verifica che gli endpoint rispondano
                                 (con --scarica: download completo + validazione)
  init                           crea tabelle, funzioni e viste pums.tpl_*
                                 (da eseguire come proprietario dello schema pums)
  aggiorna  [--feed ID] [--file ZIP] [--forza]
                                 scarica e ricarica i feed (atomico per feed)
  stato                          mostra validità dei feed caricati

Codici di uscita: 0 = ok, 1 = avviso (es. feed in scadenza), 2 = errore.
Dipendenze: Python >= 3.8, psycopg2 (solo per init/aggiorna/stato).
"""
import argparse
import configparser
import csv
import datetime as dt
import hashlib
import io
import json
import logging
import os
import sys
import time
import urllib.error
import urllib.request
import zipfile

QUI = os.path.dirname(os.path.abspath(__file__))
UA = "gtfs-lizmap/1.0 (+aggiornamento orari TPL)"
FILE_OBBLIGATORI = ["agency.txt", "stops.txt", "routes.txt", "trips.txt", "stop_times.txt"]
log = logging.getLogger("gtfs_lizmap")

OK, AVVISO, ERRORE = 0, 1, 2


# ---------------------------------------------------------------------------
# Configurazione
# ---------------------------------------------------------------------------
class Config:
    def __init__(self, path):
        cp = configparser.ConfigParser(interpolation=None)
        if not cp.read(path, encoding="utf-8"):
            sys.exit(f"Configurazione non trovata: {path}")
        base = os.path.dirname(os.path.abspath(path))
        self.dsn = cp.get("database", "dsn", fallback="")
        self.download_dir = self._p(base, cp.get("generale", "download_dir", fallback="download"))
        self.giorni_preavviso = cp.getint("generale", "giorni_preavviso", fallback=5)
        self.timeout = cp.getint("generale", "timeout_s", fallback=300)
        self.territorio_geojson = cp.get("territorio", "geojson", fallback="")
        if self.territorio_geojson:
            self.territorio_geojson = self._p(base, self.territorio_geojson)
        self.territorio_query = cp.get("territorio", "query", fallback="")
        self.territorio_nome = cp.get("territorio", "nome", fallback="Territorio")
        self.buffer_default = cp.getfloat("territorio", "buffer_m", fallback=30)
        self.feeds = []
        for sez in cp.sections():
            if sez.startswith("feed:"):
                s = cp[sez]
                if not s.getboolean("attivo", fallback=True):
                    continue
                self.feeds.append({
                    "id": sez.split(":", 1)[1].strip(),
                    "nome": s.get("nome", sez),
                    "url": s.get("url"),
                    "buffer_m": s.getfloat("buffer_m", fallback=self.buffer_default),
                })

    @staticmethod
    def _p(base, p):
        return p if os.path.isabs(p) else os.path.join(base, p)


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
def _req(url, method="GET", headers=None):
    h = {"User-Agent": UA}
    h.update(headers or {})
    return urllib.request.Request(url, method=method, headers=h)


def sonda(url, timeout=30):
    """Verifica leggera: HEAD, se non supportato GET dei primi byte."""
    t0 = time.time()
    risultato = {"url": url}
    for metodo, extra in (("HEAD", {}), ("GET", {"Range": "bytes=0-3"})):
        try:
            with urllib.request.urlopen(_req(url, metodo, extra), timeout=timeout) as r:
                primi = r.read(4) if metodo == "GET" else b""
                risultato.update(
                    metodo=metodo,
                    status=r.status,
                    url_finale=r.geturl(),
                    content_type=r.headers.get("Content-Type"),
                    dimensione=r.headers.get("Content-Length")
                        if r.status != 206 else (r.headers.get("Content-Range") or "").split("/")[-1],
                    last_modified=r.headers.get("Last-Modified"),
                    etag=r.headers.get("ETag"),
                    zip_firma=(primi[:2] == b"PK") if primi else None,
                    secondi=round(time.time() - t0, 2),
                    esito="ok",
                )
                return risultato
        except urllib.error.HTTPError as e:
            if metodo == "HEAD" and e.code in (403, 405, 501):
                continue  # alcuni server non accettano HEAD: riprova in GET
            risultato.update(metodo=metodo, status=e.code, esito="errore",
                             errore=f"HTTP {e.code} {e.reason}", secondi=round(time.time() - t0, 2))
            return risultato
        except Exception as e:  # DNS, timeout, TLS, proxy...
            risultato.update(metodo=metodo, esito="errore", errore=f"{type(e).__name__}: {e}",
                             secondi=round(time.time() - t0, 2))
            return risultato
    return risultato


def scarica(url, dest, timeout=300):
    """Scarica in un file .part e lo rinomina solo se completo. Ritorna sha256."""
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    h = hashlib.sha256()
    t0 = time.time()
    with urllib.request.urlopen(_req(url), timeout=timeout) as r, open(tmp, "wb") as out:
        attesi = r.headers.get("Content-Length")
        n = 0
        while True:
            blocco = r.read(1 << 20)
            if not blocco:
                break
            out.write(blocco)
            h.update(blocco)
            n += len(blocco)
    if attesi and int(attesi) != n:
        raise IOError(f"download incompleto: {n} byte su {attesi}")
    os.replace(tmp, dest)
    log.info("scaricati %.1f MB in %.0f s", n / 1e6, time.time() - t0)
    return h.hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Lettura GTFS
# ---------------------------------------------------------------------------
def leggi(z, nome):
    """Iteratore di dict su un file del feed (gestisce BOM e spazi nei nomi colonna)."""
    if nome not in z.namelist():
        return iter(())
    f = io.TextIOWrapper(z.open(nome), encoding="utf-8-sig", newline="")
    r = csv.reader(f)
    intest = [c.strip() for c in next(r, [])]

    def gen():
        for riga in r:
            if riga:
                yield dict(zip(intest, riga))
    return gen()


def secondi(t):
    t = (t or "").strip()
    if not t:
        return None
    h, m, s = t.split(":")
    return int(h) * 3600 + int(m) * 60 + int(s)


def data_gtfs(s):
    s = (s or "").strip()
    return dt.date(int(s[:4]), int(s[4:6]), int(s[6:8])) if len(s) == 8 else None


def nn(v):
    v = (v or "").strip()
    return v if v != "" else None


def intn(v):
    v = nn(v)
    try:
        return int(float(v)) if v is not None else None
    except ValueError:
        return None


def validita(z):
    """Periodo di validità: feed_info se presente, altrimenti calendar/calendar_dates."""
    for fi in leggi(z, "feed_info.txt"):
        a, b = data_gtfs(fi.get("feed_start_date")), data_gtfs(fi.get("feed_end_date"))
        if a and b:
            return a, b
    date = []
    for c in leggi(z, "calendar.txt"):
        date += [data_gtfs(c.get("start_date")), data_gtfs(c.get("end_date"))]
    for c in leggi(z, "calendar_dates.txt"):
        if c.get("exception_type", "").strip() == "1":
            date.append(data_gtfs(c.get("date")))
    date = [d for d in date if d]
    return (min(date), max(date)) if date else (None, None)


def valida_zip(path):
    z = zipfile.ZipFile(path)
    mancanti = [f for f in FILE_OBBLIGATORI if f not in z.namelist()]
    if "calendar.txt" not in z.namelist() and "calendar_dates.txt" not in z.namelist():
        mancanti.append("calendar.txt|calendar_dates.txt")
    if mancanti:
        raise ValueError("file GTFS mancanti: " + ", ".join(mancanti))
    return z


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
def connetti(cfg):
    try:
        import psycopg2
    except ImportError:
        sys.exit("Serve psycopg2: pip install psycopg2-binary (oppure apt install python3-psycopg2)")
    conn = psycopg2.connect(cfg.dsn)
    conn.autocommit = False
    return conn


def copia(cur, tabella, colonne, righe):
    """COPY veloce da lista di tuple."""
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    n = 0
    for r in righe:
        w.writerow(["\\N" if v is None else v for v in r])
        n += 1
    buf.seek(0)
    cur.copy_expert(
        f"COPY {tabella} ({', '.join(colonne)}) FROM STDIN WITH (FORMAT csv, NULL '\\N')", buf)
    return n


def carica_territorio(cfg, cur):
    if cfg.territorio_geojson:
        with open(cfg.territorio_geojson, encoding="utf-8") as f:
            gj = json.load(f)
        geoms = [ft["geometry"] for ft in gj.get("features", [gj])]
        cur.execute("DELETE FROM pums.tpl_territorio")
        cur.execute(
            """INSERT INTO pums.tpl_territorio (id, nome, geom)
               SELECT 1, %s, ST_Multi(ST_Union(ST_SetSRID(ST_GeomFromGeoJSON(g), 4326)))
                 FROM unnest(%s::text[]) g""",
            (cfg.territorio_nome, [json.dumps(g) for g in geoms]))
    elif cfg.territorio_query:
        cur.execute("DELETE FROM pums.tpl_territorio")
        cur.execute(
            f"""INSERT INTO pums.tpl_territorio (id, nome, geom)
                SELECT 1, %s, ST_Multi(ST_Union(ST_Transform(q.geom, 4326)))
                  FROM ({cfg.territorio_query}) q""", (cfg.territorio_nome,))
    else:
        raise ValueError("configurare [territorio] geojson oppure query")


def importa_feed(cfg, conn, feed, zip_path, sha):
    fid = feed["id"]
    z = valida_zip(zip_path)
    dal, al = validita(z)
    cur = conn.cursor()

    # 1. Fermate del territorio (in PostGIS, sul confine comunale + buffer)
    tutte = {}
    for s in leggi(z, "stops.txt"):
        tutte[s["stop_id"]] = s
    cur.execute("CREATE TEMP TABLE IF NOT EXISTS _st (stop_id text, lon float8, lat float8) ON COMMIT DROP")
    cur.execute("TRUNCATE _st")
    copia(cur, "_st", ["stop_id", "lon", "lat"],
          ((k, v.get("stop_lon"), v.get("stop_lat")) for k, v in tutte.items()
           if nn(v.get("stop_lon")) and nn(v.get("stop_lat"))))
    cur.execute(
        """SELECT s.stop_id FROM _st s, pums.tpl_territorio t
            WHERE ST_DWithin(ST_SetSRID(ST_MakePoint(s.lon, s.lat), 4326)::geography,
                             t.geom::geography, %s)""", (feed["buffer_m"],))
    sel = {r[0] for r in cur.fetchall()}
    # includi stazioni "padre" e relativi binari
    padri = {nn(tutte[s].get("parent_station")) for s in sel} - {None}
    sel |= {p for p in padri if p in tutte}
    sel |= {k for k, v in tutte.items() if nn(v.get("parent_station")) in sel}
    log.info("[%s] fermate nel territorio: %d su %d", fid, len(sel), len(tutte))

    # 2. stop_times: un solo passaggio sul file (anche centinaia di MB)
    ultima = {}       # trip_id -> (seq max, stop_id)
    righe_st = []
    senza_orario = 0
    for r in leggi(z, "stop_times.txt"):
        tid, seq = r["trip_id"], int(r["stop_sequence"])
        u = ultima.get(tid)
        if u is None or seq > u[0]:
            ultima[tid] = (seq, r["stop_id"])
        if r["stop_id"] in sel:
            dep = secondi(r.get("departure_time")) or secondi(r.get("arrival_time"))
            if dep is None:
                senza_orario += 1
                continue
            righe_st.append([fid, tid, r["stop_id"], seq,
                             secondi(r.get("arrival_time")) or dep, dep,
                             intn(r.get("pickup_type")) or 0, intn(r.get("drop_off_type")) or 0])
    for rr in righe_st:
        rr.append("t" if ultima[rr[1]][0] == rr[3] else "f")
    trip_ids = {rr[1] for rr in righe_st}
    if senza_orario:
        log.warning("[%s] %d passaggi senza orario (fermate non timepoint) ignorati", fid, senza_orario)

    # 3. trips, routes, agency, calendario
    trips = [t for t in leggi(z, "trips.txt") if t["trip_id"] in trip_ids]
    route_ids = {t["route_id"] for t in trips}
    service_ids = {t["service_id"] for t in trips}
    shape_ids = {nn(t.get("shape_id")) for t in trips} - {None}
    routes = [r for r in leggi(z, "routes.txt") if r["route_id"] in route_ids]
    agency_ids = {nn(r.get("agency_id")) for r in routes}
    agencies = [a for a in leggi(z, "agency.txt")
                if nn(a.get("agency_id")) in agency_ids or None in agency_ids]
    cal = [c for c in leggi(z, "calendar.txt") if c["service_id"] in service_ids]
    cald = [c for c in leggi(z, "calendar_dates.txt") if c["service_id"] in service_ids]

    # 4. shapes delle corse coinvolte (percorso completo, non tagliato)
    punti = {}
    for s in leggi(z, "shapes.txt"):
        if s["shape_id"] in shape_ids:
            punti.setdefault(s["shape_id"], []).append(
                (int(s["shape_pt_sequence"]), s["shape_pt_lon"].strip(), s["shape_pt_lat"].strip()))
    shapes = []
    for k, pts in punti.items():
        pts.sort()
        if len(pts) >= 2:
            shapes.append((fid, k, "SRID=4326;LINESTRING(" + ",".join(f"{x} {y}" for _, x, y in pts) + ")"))

    # 5. Sostituzione atomica: chi usa Lizmap vede i dati vecchi fino al COMMIT
    for t in ("stop_times", "trips", "routes", "agency", "calendar", "calendar_dates", "shapes", "stops"):
        cur.execute(f"DELETE FROM pums.tpl_{t} WHERE feed_id = %s", (fid,))
    copia(cur, "pums.tpl_agency", ["feed_id", "agency_id", "agency_name", "agency_url"],
          ((fid, nn(a.get("agency_id")) or "_", nn(a.get("agency_name")), nn(a.get("agency_url")))
           for a in agencies))
    copia(cur, "pums.tpl_stops",
          ["feed_id", "stop_id", "stop_code", "stop_name", "location_type", "parent_station",
           "wheelchair_boarding", "platform_code", "geom"],
          ((fid, k, nn(tutte[k].get("stop_code")), nn(tutte[k].get("stop_name")),
            intn(tutte[k].get("location_type")) or 0, nn(tutte[k].get("parent_station")),
            intn(tutte[k].get("wheelchair_boarding")), nn(tutte[k].get("platform_code")),
            f"SRID=4326;POINT({tutte[k]['stop_lon'].strip()} {tutte[k]['stop_lat'].strip()})")
           for k in sorted(sel)))
    copia(cur, "pums.tpl_routes",
          ["feed_id", "route_id", "agency_id", "route_short_name", "route_long_name", "route_type",
           "route_color", "route_text_color", "route_sort_order"],
          ((fid, r["route_id"], nn(r.get("agency_id")) or "_", nn(r.get("route_short_name")),
            nn(r.get("route_long_name")), intn(r.get("route_type")),
            (nn(r.get("route_color")) or "").lstrip("#").upper() or None,
            (nn(r.get("route_text_color")) or "").lstrip("#").upper() or None,
            intn(r.get("route_sort_order"))) for r in routes))
    copia(cur, "pums.tpl_trips",
          ["feed_id", "trip_id", "route_id", "service_id", "trip_headsign", "trip_short_name",
           "direction_id", "shape_id", "wheelchair_accessible", "ultima_fermata"],
          ((fid, t["trip_id"], t["route_id"], t["service_id"], nn(t.get("trip_headsign")),
            nn(t.get("trip_short_name")), intn(t.get("direction_id")), nn(t.get("shape_id")),
            intn(t.get("wheelchair_accessible")),
            nn(tutte.get(ultima[t["trip_id"]][1], {}).get("stop_name"))) for t in trips))
    n_st = copia(cur, "pums.tpl_stop_times",
                 ["feed_id", "trip_id", "stop_id", "stop_sequence", "arr_s", "dep_s",
                  "pickup_type", "drop_off_type", "capolinea_fin"], righe_st)
    giorni = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    copia(cur, "pums.tpl_calendar",
          ["feed_id", "service_id", "lun", "mar", "mer", "gio", "ven", "sab", "dom", "start_date", "end_date"],
          ((fid, c["service_id"], *[("t" if c.get(g, "0").strip() == "1" else "f") for g in giorni],
            data_gtfs(c["start_date"]), data_gtfs(c["end_date"])) for c in cal))
    copia(cur, "pums.tpl_calendar_dates", ["feed_id", "service_id", "date", "exception_type"],
          ((fid, c["service_id"], data_gtfs(c["date"]), intn(c["exception_type"])) for c in cald))
    copia(cur, "pums.tpl_shapes", ["feed_id", "shape_id", "geom"], shapes)

    cur.execute(
        """INSERT INTO pums.tpl_feed (feed_id, nome, url, scaricato_il, sha256, valido_dal, valido_al, esito, messaggio)
           VALUES (%s,%s,%s,now(),%s,%s,%s,'ok',%s)
           ON CONFLICT (feed_id) DO UPDATE SET nome=EXCLUDED.nome, url=EXCLUDED.url,
             scaricato_il=EXCLUDED.scaricato_il, sha256=EXCLUDED.sha256, valido_dal=EXCLUDED.valido_dal,
             valido_al=EXCLUDED.valido_al, esito='ok', messaggio=EXCLUDED.messaggio""",
        (fid, feed["nome"], feed["url"], sha, dal, al,
         f"{len(sel)} fermate, {len(routes)} linee, {len(trips)} corse, {n_st} passaggi"))
    conn.commit()
    log.info("[%s] caricato: %d fermate, %d linee, %d corse, %d passaggi, %d percorsi; valido %s -> %s",
             fid, len(sel), len(routes), len(trips), n_st, len(shapes), dal, al)
    return dal, al


def segna_errore(conn, feed, msg):
    conn.rollback()
    cur = conn.cursor()
    cur.execute(
        """INSERT INTO pums.tpl_feed (feed_id, nome, url, esito, messaggio) VALUES (%s,%s,%s,'errore',%s)
           ON CONFLICT (feed_id) DO UPDATE SET esito='errore', messaggio=EXCLUDED.messaggio""",
        (feed["id"], feed["nome"], feed["url"], f"{dt.datetime.now():%Y-%m-%d %H:%M} {msg}"[:1000]))
    conn.commit()


# ---------------------------------------------------------------------------
# Comandi
# ---------------------------------------------------------------------------
def cmd_check(cfg, args):
    rc = OK
    for f in cfg.feeds:
        r = sonda(f["url"])
        if r["esito"] != "ok":
            print(f"✗ {f['id']:<12} {r.get('errore')}  ({r['url']})")
            rc = ERRORE
            continue
        dim = r.get("dimensione")
        dim = f"{int(dim) / 1e6:.1f} MB" if dim and dim.isdigit() else "dimensione n.d."
        print(f"✓ {f['id']:<12} HTTP {r['status']} via {r['metodo']} in {r['secondi']} s · "
              f"{r.get('content_type')} · {dim} · Last-Modified: {r.get('last_modified') or 'n.d.'}")
        if r.get("url_finale") and r["url_finale"] != f["url"]:
            print(f"  ↳ redirect a {r['url_finale']}")
        if r.get("zip_firma") is False:
            print("  ! la risposta non sembra uno zip (firma PK assente)")
            rc = max(rc, AVVISO)
        if args.scarica:
            dest = os.path.join(cfg.download_dir, f"{f['id']}.zip")
            try:
                scarica(f["url"], dest, cfg.timeout)
                z = valida_zip(dest)
                dal, al = validita(z)
                residui = (al - dt.date.today()).days if al else None
                print(f"  zip valido · {len(z.namelist())} file · validità {dal} → {al}"
                      + (f" ({residui} giorni residui)" if residui is not None else ""))
                if residui is not None and residui < cfg.giorni_preavviso:
                    print("  ! feed in scadenza o scaduto")
                    rc = max(rc, AVVISO)
            except Exception as e:
                print(f"  ✗ download/validazione falliti: {e}")
                rc = ERRORE
    return rc


def cmd_init(cfg, args):
    conn = connetti(cfg)
    cur = conn.cursor()
    for nome in ("01_schema.sql", "02_funzioni.sql"):
        with open(os.path.join(QUI, "sql", nome), encoding="utf-8") as f:
            cur.execute(f.read())
        log.info("eseguito %s", nome)
    carica_territorio(cfg, cur)
    conn.commit()
    cur.execute("SELECT round((ST_Area(geom::geography)/1e6)::numeric, 1) FROM pums.tpl_territorio")
    log.info("territorio '%s' caricato (%s km²)", cfg.territorio_nome, cur.fetchone()[0])
    return OK


def cmd_aggiorna(cfg, args):
    conn = connetti(cfg)
    cur = conn.cursor()
    carica_territorio(cfg, cur)
    conn.commit()
    rc = OK
    feeds = [f for f in cfg.feeds if not args.feed or f["id"] == args.feed]
    if not feeds:
        log.error("nessun feed corrispondente a %s", args.feed)
        return ERRORE
    for f in feeds:
        try:
            if args.file:
                zip_path, sha = args.file, sha256_file(args.file)
            else:
                zip_path = os.path.join(cfg.download_dir, f"{f['id']}.zip")
                sha = scarica(f["url"], zip_path, cfg.timeout)
            cur.execute("SELECT sha256, esito FROM pums.tpl_feed WHERE feed_id = %s", (f["id"],))
            prec = cur.fetchone()
            conn.commit()
            if prec and prec[0] == sha and prec[1] == "ok" and not args.forza:
                log.info("[%s] feed invariato, nessun ricaricamento", f["id"])
            else:
                importa_feed(cfg, conn, f, zip_path, sha)
        except Exception as e:
            log.exception("[%s] aggiornamento fallito, restano i dati precedenti", f["id"])
            segna_errore(conn, f, f"{type(e).__name__}: {e}")
            rc = ERRORE
    rc = max(rc, cmd_stato(cfg, args, conn) if rc == OK else rc)
    return rc


def cmd_stato(cfg, args, conn=None):
    conn = conn or connetti(cfg)
    cur = conn.cursor()
    cur.execute("SELECT feed_id, esito, valido_dal, valido_al, giorni_residui, messaggio "
                "FROM pums.tpl_v_stato_feed ORDER BY feed_id")
    rc = OK
    for fid, esito, dal, al, res, msg in cur.fetchall():
        segno = "✓"
        if esito != "ok":
            segno, rc = "✗", ERRORE
        elif res is None or res < cfg.giorni_preavviso:
            segno, rc = "!", max(rc, AVVISO)
        print(f"{segno} {fid:<12} {esito:<7} {dal} → {al} ({res} gg) · {msg}")
    return rc


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-c", "--config", default=os.path.join(QUI, "config.ini"))
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--dsn", help="connessione diversa da config.ini (es. proprietario dello schema per init)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("check"); p.add_argument("--scarica", action="store_true")
    sub.add_parser("init")
    p = sub.add_parser("aggiorna")
    p.add_argument("--feed"); p.add_argument("--file", help="usa uno zip locale invece di scaricarlo")
    p.add_argument("--forza", action="store_true", help="ricarica anche se il feed è invariato")
    sub.add_parser("stato")
    args = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    cfg = Config(args.config)
    if args.dsn:
        cfg.dsn = args.dsn
    fn = {"check": cmd_check, "init": cmd_init, "aggiorna": cmd_aggiorna, "stato": cmd_stato}[args.cmd]
    sys.exit(fn(cfg, args))


if __name__ == "__main__":
    main()
