# Rendered by the deploy script with envsubst. See app/deploy.sh.tftpl.
#
# Confluent's Metrics API /export endpoint speaks OpenMetrics, so Prometheus
# scrapes it directly and no exporter process is needed. This is the same
# pattern as confluentinc/jmx-monitoring-stacks/ccloud-prometheus-grafana.
#
# The endpoint returns only the most recent data point per metric, and Confluent
# publishes at 1 minute granularity, so scraping faster than 1m gains nothing.
global:
  scrape_interval: 1m
  scrape_timeout: 55s

scrape_configs:
  # Kafka cluster and Tableflow metrics. The io.confluent.tableflow/* metrics
  # are published under the kafka resource type, so one resource.kafka.id
  # parameter brings back both sets.
  - job_name: confluent-cloud
    # Confluent stamps each point with the minute it covers and repeats that
    # stamp across scrapes until a new point is published. Honouring those
    # timestamps makes Prometheus reject the repeats as duplicate samples,
    # leaving roughly one sample per series per window and breaking the panels.
    # Scrape time instead: values are attributed a few minutes late, which is
    # invisible on a dashboard and keeps the series continuous.
    honor_timestamps: false
    scheme: https
    metrics_path: /v2/metrics/cloud/export
    static_configs:
      - targets:
          - api.telemetry.confluent.cloud
    basic_auth:
      username: ${METRICS_API_KEY}
      password: ${METRICS_API_SECRET}
    params:
      resource.kafka.id:
        - ${KAFKA_CLUSTER_ID}
      resource.schema_registry.id:
        - ${SCHEMA_REGISTRY_ID}

  # The ADLS -> Snowflake hop, written as a textfile by sync.py each run.
  # Confluent's metrics stop at "snapshot committed to ADLS"; this is the rest.
  - job_name: tableflow-sync
    scrape_interval: 30s
    static_configs:
      - targets:
          - node-exporter:9100
