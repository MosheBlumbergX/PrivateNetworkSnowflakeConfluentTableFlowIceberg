---
theme: default
title: Private Networking - Tableflow to Snowflake (Iceberg)
info: Confluent Tableflow -> ADLS -> Snowflake over Azure Private Link, no public data path.
class: text-left
fonts:
  sans: Inter
  mono: Fira Code
drawings:
  enabled: false
transition: slide-left
mdc: true
---

<div class="cover-wrap">
  <div><span class="tag">AZURE PRIVATE LINK · UKSOUTH</span></div>
  <h1 class="mt-6">Tableflow to Snowflake,<br/>fully private.</h1>
  <div class="sub">Confluent Cloud produces Iceberg tables to ADLS and lands them in Snowflake with no public data path. The catch: the Iceberg REST Catalog disappears.</div>
  <div class="meta">REVIEW · 2026-11-17 · mblumberg · CSTA</div>
</div>

<!--
Framing: take the public demo and make every record hop private. The interesting part is what breaks.
-->

---

## The problem

<div class="kicker">Private networking removes the easy path</div>

<div class="grid grid-cols-2 gap-5 mt-5">
<div class="card">
<div class="text-lg font-semibold mb-1">No built-in catalog</div>
The Iceberg <b>REST Catalog is not served</b> for private-networking clusters. Snowflake has nothing to federate to.
</div>
<div class="card">
<div class="text-lg font-semibold mb-1">No Azure catalog targets</div>
Glue is AWS only. Unity Catalog and Open Catalog are <b>unsupported</b> over private networking.
</div>
</div>

<div class="card card-warn mt-6">
<div class="kicker" style="color:var(--warn)">The pivot</div>
<div class="mt-1">Skip the catalog. Make <b>storage the source of truth</b>: Snowflake reads Tableflow's Iceberg metadata directly from ADLS, and a 60s sync job keeps it pointed at the newest snapshot.</div>
</div>

---

## Architecture

<div class="kicker">The data path, left to right, every hop private</div>

<div class="flow mt-8">
  <div class="node"><div class="n-title">producer.py</div><div class="n-sub">Avro, in the VNet</div></div>
  <div class="hop"><div class="h-arrow">&rarr;</div><div class="h-lab">Private Link</div></div>
  <div class="node"><div class="n-title">Kafka</div><div class="n-sub">stock_trades</div></div>
  <div class="hop"><div class="h-arrow">&rarr;</div><div class="h-lab">Tableflow</div></div>
  <div class="node node-store"><div class="n-title">Iceberg</div><div class="n-sub">files on ADLS</div></div>
  <div class="hop"><div class="h-arrow">&rarr;</div><div class="h-lab">reads</div></div>
  <div class="node node-sink"><div class="n-title">Snowflake</div><div class="n-sub">Iceberg tables</div></div>
</div>

<div class="grid grid-cols-2 gap-5 mt-8">
  <div class="card">
    <div class="kicker">The sync loop</div>
    <div class="mt-1 text-sm"><code>sync.py</code> (60s, in the VNet) reads the newest Iceberg metadata from ADLS over a <b>private endpoint</b> and refreshes Snowflake. Snowflake reads ADLS over <b>VNet service endpoints</b>.</div>
  </div>
  <div class="card">
    <div class="kicker">What stays public</div>
    <div class="mt-1 text-sm">Only <b>control-plane metadata</b>: topic names, file paths, DDL, and Avro schemas. <b>No record data</b> ever leaves a private path.</div>
  </div>
</div>

<div class="rowline mt-5"><span class="legend-dot" style="background:var(--accent)"></span>Producer to Kafka, Tableflow to ADLS, sync and Snowflake to ADLS: all private. ADLS firewall defaults to Deny.</div>

---

## How the sync works

<div class="grid grid-cols-5 gap-3 items-stretch mt-2">
<div class="card col-span-3">
<div class="kicker">sync.py · every 60s, inside the VNet</div>
<ol class="mt-2 leading-relaxed">
<li>List Tableflow topics via the Confluent API <span class="rowline">(control plane only)</span></li>
<li>Find the newest <code>*.metadata.json</code> in ADLS over a <b>private endpoint</b></li>
<li><code>CREATE</code> the Iceberg table in Snowflake, then <code>ALTER ... REFRESH</code> as snapshots move</li>
</ol>
</div>
<div class="card col-span-2 flex flex-col justify-center">
<div class="kicker">Freshness</div>
<div class="text-3xl font-bold mt-1">~3 min</div>
<div class="rowline">Tableflow commit interval + up to 60s sync</div>
</div>
</div>

<div class="grid grid-cols-5 gap-3 items-center mt-5">
<div class="stat"><div class="num">735k</div><div class="lab">in Kafka</div></div>
<div class="arrow">&rarr;</div>
<div class="stat"><div class="num">732k</div><div class="lab">Iceberg in ADLS</div></div>
<div class="arrow">&rarr;</div>
<div class="stat"><div class="num">723k</div><div class="lab">queryable in Snowflake</div></div>
</div>

---

## Monitoring &amp; what's next

<div class="grid grid-cols-2 gap-6 mt-4">

<div class="card">
<div class="kicker">Monitoring · Prometheus + Grafana on the VM</div>
<ul class="mt-2">
<li>Confluent Metrics API <code>/export</code> for Kafka + Tableflow</li>
<li><code>sync.py</code> emits the <b>ADLS &rarr; Snowflake hop</b> no vendor metric covers</li>
<li>One dashboard spans the whole chain</li>
</ul>
</div>

<div class="card">
<div class="kicker">Next</div>
<ul class="mt-2">
<li><b>Feature request</b>: serve IRC metadata for private clusters, pointing at the private path</li>
<li>Fail the apply loudly if the Snowflake leg breaks</li>
<li>Decide: keep storage-as-truth, or adopt IRC if shipped</li>
</ul>
</div>

</div>

<div class="card card-good mt-5">
<span class="pill pill-good">LIVE</span>&nbsp; Private demo running · Grafana at <code>localhost:3000</code> · demo scripts <code>check_rest_catalog.py</code>, <code>counts.py</code>
</div>

<div class="foot">Tableflow to Snowflake · private networking · 2026-11-17</div>
