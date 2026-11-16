"""Prometheus textfile metrics for the ADLS -> Snowflake hop.

Confluent's Metrics API covers Kafka and Tableflow up to "snapshot committed to
ADLS". The last leg of this demo is sync.py pointing Snowflake at that snapshot,
and no vendor metric sees it. This writes that leg as a textfile for
node_exporter's textfile collector, which Prometheus scrapes.

Row counts come from the Iceberg metadata JSON (snapshot summary total-records)
rather than COUNT(*) in Snowflake, so the dashboard costs no warehouse time and
keeps working while the warehouse is suspended.
"""
import os
import tempfile

TEXTFILE_DIR = os.environ.get("TEXTFILE_DIR", "/var/lib/tableflow-demo/textfile")
TEXTFILE_NAME = "tableflow_sync.prom"

_HELP = {
    "tableflow_sync_last_run_timestamp_seconds": ("gauge", "Unix time of the last sync run, successful or not."),
    "tableflow_sync_success": ("gauge", "1 if the last sync run completed without error, 0 otherwise."),
    "tableflow_sync_duration_seconds": ("gauge", "Wall-clock duration of the last sync run."),
    "tableflow_sync_topics_discovered": ("gauge", "Tableflow topics in RUNNING phase with an Iceberg table path."),
    "tableflow_sync_tables": ("gauge", "Tables this job currently keeps registered in Snowflake."),
    "tableflow_sync_actions": ("gauge", "Tables created, refreshed or dropped in the last run."),
    "tableflow_sync_adls_snapshot_timestamp_seconds": ("gauge", "Last-modified time of the newest Iceberg metadata file in ADLS."),
    "tableflow_sync_adls_total_records": ("gauge", "Records in the newest Iceberg snapshot in ADLS."),
    "tableflow_sync_snowflake_snapshot_timestamp_seconds": ("gauge", "Last-modified time of the metadata file Snowflake currently points at."),
    "tableflow_sync_snowflake_total_records": ("gauge", "Records visible in Snowflake, from the snapshot it points at."),
    "tableflow_sync_snowflake_current": ("gauge", "1 if Snowflake points at the newest metadata file in ADLS, 0 if it lags."),
}


def _escape(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _format(value):
    """Full precision, no exponent for whole numbers.

    Unix timestamps need every digit: '%g' would render 1794822766 as 1.79482e+09
    and throw away 2766 seconds, which would silently corrupt any
    time() - timestamp panel.
    """
    if value.is_integer() and abs(value) < 2 ** 53:
        return str(int(value))
    return repr(value)


class Metrics:
    """Collects samples and writes them atomically so scrapes never see a partial file."""

    def __init__(self):
        self._samples = {}

    def set(self, name, value, **labels):
        self._samples.setdefault(name, []).append((labels, float(value)))

    def write(self, directory=TEXTFILE_DIR):
        lines = []
        for name, samples in self._samples.items():
            kind, help_text = _HELP.get(name, ("gauge", name))
            lines.append(f"# HELP {name} {help_text}")
            lines.append(f"# TYPE {name} {kind}")
            for labels, value in samples:
                rendered = ",".join(f'{k}="{_escape(v)}"' for k, v in sorted(labels.items()))
                text = _format(value)
                lines.append(f"{name}{{{rendered}}} {text}" if rendered else f"{name} {text}")
        body = "\n".join(lines) + "\n"

        try:
            os.makedirs(directory, exist_ok=True)
            # Same filesystem as the target so the rename is atomic.
            fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tableflow_sync.", suffix=".tmp")
            with os.fdopen(fd, "w") as f:
                f.write(body)
            os.chmod(tmp, 0o644)
            os.replace(tmp, os.path.join(directory, TEXTFILE_NAME))
        except OSError as exc:
            # Metrics must never take the sync job down.
            print(f"warning: could not write metrics to {directory}: {exc}")
