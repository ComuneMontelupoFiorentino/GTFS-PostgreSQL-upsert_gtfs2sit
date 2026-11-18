# Orari TPL in Lizmap: Comune di Montelupo Fiorentino

Carica i feed GTFS regionali (Autolinee Toscane, Trenitalia) in PostGIS, filtrati sul
territorio comunale. Il layer delle paline mostra un popup con le **partenze attorno
all'ora del clic**: le ultime 2 passate e le prossime 8, con la prossima evidenziata.

```
gtfs_lizmap.py          script unico: check, init, aggiorna, stato
config.ini.example      modello di config.ini: feed, territorio, connessione al DB
sql/01_schema.sql       tabelle (DB amm_viab, schema pums, prefisso tpl_)
sql/02_funzioni.sql     calendario, partenze, HTML del popup, viste per QGIS
sql/03_permessi.sql     facoltativo: permessi per ruoli dedicati non superuser
territorio/             confine ISTAT 048028 (GeoJSON, EPSG:4326)
lizmap/gtfs_popup.js    stile del popup per Lizmap (inietta il CSS)
lizmap/gtfs_popup.css   lo stesso CSS, se preferite caricarlo da tema
anteprima/              anteprima del popup con i dati reali AT (Bootstrap 2.3.2 caricato)
```

Requisiti: PostgreSQL con PostGIS, Python ≥ 3.8 e `psycopg2`
(`apt install python3-psycopg2` oppure `pip install psycopg2-binary`).

---

## 1. Verificare gli endpoint (dal server Lizmap)

Gli endpoint vanno verificati **dalla macchina che farà gli aggiornamenti**, perché
proxy e firewall dell'ente contano. Lo script usa le variabili `HTTPS_PROXY`/`HTTP_PROXY`
se sono impostate.

```bash
python3 gtfs_lizmap.py check            # verifica rapida (HEAD o primi byte)
python3 gtfs_lizmap.py check --scarica  # download completo, controllo zip e validità
```

Esempio di output atteso:

```
✓ at           HTTP 200 via HEAD in 0.4 s · application/zip · 173.1 MB · Last-Modified: …
  zip valido · 10 file · validità 2026-10-29 → 2026-11-18 (20 giorni residui)
```

Controllo manuale equivalente con curl:

```bash
curl -sSIL https://regionetoscana.smartregion.toscana.it/mobility/artifacts/gtfs
```

Codici di uscita: `0` ok, `1` avviso (feed in scadenza), `2` errore. Si possono quindi
usare in cron o in un sistema di monitoraggio.

## 2. Installazione

```bash
# 1) cp config.ini.example config.ini, poi nel dsn l'utente PostgreSQL (superuser o proprietario di pums;
#    password in ~/.pgpass)
# 2) tabelle, funzioni, viste e confine comunale
python3 gtfs_lizmap.py init
# 3) primo caricamento (circa 30 s per il feed AT)
python3 gtfs_lizmap.py aggiorna
# (facoltativo) solo con ruoli dedicati non superuser: impostarli in
# sql/03_permessi.sql ed eseguirlo dopo ogni init
# psql -d amm_viab -f sql/03_permessi.sql
```

Se il confine comunale è già nel vostro PostGIS, in `config.ini` sostituite `geojson =`
con `query = SELECT geom FROM … WHERE cod_istat = '048028'`. La geometria viene
riproiettata automaticamente.

## 3. Aggiornamento automatico (obbligatorio)

Il feed di Autolinee Toscane **copre solo 3 settimane** a partire dalla data di
generazione, che avviene ogni notte verso le 3:50. Senza aggiornamento il popup si
svuota alla scadenza.

```cron
MAILTO=sit@comune.montelupo-fiorentino.fi.it
# ogni notte dopo la rigenerazione del feed AT
30 4 * * *  cd /opt/gtfs_lizmap && python3 gtfs_lizmap.py aggiorna >> /var/log/gtfs_lizmap.log 2>&1 || echo "Aggiornamento GTFS: verificare il log"
```

Come funziona l'aggiornamento:
- **È atomico per singolo feed.** La sostituzione avviene in una transazione: Lizmap
  vede i dati vecchi fino al commit, senza interruzioni e senza toccare il progetto QGIS.
- **Se un download fallisce, restano i dati precedenti** di quel feed. L'errore viene
  registrato in `pums.tpl_feed`.
- **Se il file scaricato è identico a quello già caricato** (stesso sha256), non viene
  ricaricato. Per forzare il ricaricamento c'è `--forza`.
- **Si può caricare uno zip locale** con `aggiorna --feed at --file percorso.zip`.
- `python3 gtfs_lizmap.py stato` (o la vista `pums.tpl_v_stato_feed`) mostra la validità
  e i giorni residui di ogni feed.

## 4. Configurazione in QGIS

1. Aggiungere il layer PostGIS **`pums.tpl_v_paline`**. Quando QGIS lo chiede, scegliere
   **`id`** come chiave primaria: è stabile tra un aggiornamento e l'altro.
2. Impostare il popup: *Proprietà layer → Visualizzazione → Suggerimento HTML*
   (Map tip) con:
   ```
   [% "popup_html" %]
   ```
3. Simbologia consigliata: categorizzata su `tipo` (`bus` / `treno`). Il campo `linee`
   si può usare per le etichette o per i filtri.
4. Facoltativo: aggiungere il layer **`pums.tpl_v_linee`** (percorsi completi delle linee
   che servono il comune) con chiave `id`. Ha un campo `colore` già in formato `#RRGGBB`,
   utilizzabile come colore definito da dati.
5. Facoltativo: aggiungere la tabella `pums.tpl_v_stato_feed` per vedere lo stato dei dati
   direttamente in Lizmap.

## 5. Configurazione in Lizmap

1. Nel plugin Lizmap, scheda *Layer*, su `v_paline`: spuntare **Popup** e scegliere come
   sorgente **QGIS** (map tip HTML).
2. Stile del popup: copiare `lizmap/gtfs_popup.js` in
   `<cartella repository>/media/js/<nome progetto>/` e, nel back-office di Lizmap,
   abilitare *Consenti JavaScript* per il repository.

   Se preferite non usare JavaScript, caricate `gtfs_popup.css` con il meccanismo di tema
   della vostra versione di Lizmap. Anche senza CSS il popup resta leggibile: i colori
   delle linee e l'evidenziazione della prossima corsa sono inline nell'HTML.
3. Le classi CSS hanno il prefisso `tpl-`, quindi non entrano in conflitto con
   Bootstrap 2 di Lizmap. È stato verificato con Bootstrap 2.3.2: vedi
   `anteprima/anteprima_popup.png`.
4. Font: il CSS chiede `Titillium Web`, il font di Bootstrap Italia, con ripiego sui
   font di sistema. Per averlo, conviene servirlo dal proprio server, per esempio dai
   file del pacchetto Bootstrap Italia, invece che da Google Fonts, per ragioni di
   privacy.

L'orario è sempre aggiornato perché il popup è calcolato da PostgreSQL **a ogni clic**:
la GetFeatureInfo di QGIS Server interroga la vista e la funzione usa `now()`. Tempo
misurato: circa 20 ms per palina.

### Personalizzazioni rapide

In `sql/02_funzioni.sql`, la funzione `pums.tpl_partenze()` ha questi parametri:

| parametro | default | significato |
|---|---|---|
| `p_prima` | 2 | quante corse già partite mostrare |
| `p_dopo` | 8 | quante corse future mostrare |
| `p_orizzonte` | 12 h | fino a quando cercare le corse future |

Per una "simulazione" a un'ora diversa da quella attuale:

```sql
SELECT * FROM pums.tpl_partenze('at', '151972', '2026-11-02 07:30+01');
SELECT pums.tpl_popup_html('at', '151972', '2026-11-02 07:30+01');
```

## Note sui dati

- **Orari oltre le 24:00 e calendario.** Gli orari dopo mezzanotte (fino a 26:52 nel
  feed AT), le eccezioni di `calendar_dates` e i cambi d'ora sono gestiti secondo la
  specifica GTFS.
- **Capolinea.** Alle fermate dove la corsa termina non viene mostrata una "partenza".
- **Stazioni ferroviarie.** Se il feed ha stazioni con binari figli (`parent_station`),
  sulla mappa compare solo la stazione e il popup riunisce le partenze di tutti i binari,
  con numero del treno e binario.
- **Dati programmati, non in tempo reale.** Il popup lo dichiara esplicitamente.
- **Feed Trenitalia.** Secondo la scheda CKAN è aggiornato a gennaio 2026. Dopo il primo
  caricamento controllate `python3 gtfs_lizmap.py stato`: se il calendario è scaduto,
  le partenze dei treni non compariranno.
- **Altri feed.** I feed Colbus / AT "Città Metropolitana" (01–04) del CKAN regionale
  possono contenere servizi scolastici che passano da Montelupo. Si aggiungono in
  `config.ini` come `[feed:at_scolastico]` con il relativo URL.
- **Licenza.** Dati Regione Toscana / Autolinee Toscane in CC-BY: va citata la fonte
  nei crediti del progetto Lizmap.

## Parte di Prosit

Questo componente fa parte di **[Prosit](https://github.com/ComuneMontelupoFiorentino/prosit)**,
il Sistema Informativo Territoriale del Comune di Montelupo Fiorentino. Nel repository
[prosit](https://github.com/ComuneMontelupoFiorentino/prosit) ci sono l'architettura, l'elenco
di tutti i componenti (topic [`prosit`](https://github.com/search?q=org%3AComuneMontelupoFiorentino+topic%3Aprosit&type=repositories))
e le versioni che funzionano insieme.

## Licenza

Rilasciato dal Comune di Montelupo Fiorentino con licenza [EUPL-1.2](LICENSE) (Licenza Pubblica dell'Unione Europea).
Il confine comunale in `territorio/` deriva dai dati ISTAT (CC BY 4.0).
