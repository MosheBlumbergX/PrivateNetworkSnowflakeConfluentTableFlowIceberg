# ============================================================================
# Monitoring: Prometheus + Grafana on the demo VM, scraping the Confluent Cloud
# Metrics API export endpoint (OpenMetrics) for Kafka and Tableflow metrics.
#
# Everything here is created and destroyed with the demo. Nothing is attached
# to shared org-level resources (no notification integrations or subscriptions,
# which in a shared Confluent org belong to other people).
#
# The export endpoint rejects resource-scoped keys with 403, so the scrape needs
# its own cloud-scoped API key held by a service account with MetricsViewer.
# ============================================================================
resource "confluent_service_account" "metrics" {
  display_name = "${local.name}-metrics"
  description  = "Reads Kafka and Tableflow metrics from the Metrics API for the demo's Grafana"
}

# Scoped to this environment only, not the organization.
resource "confluent_role_binding" "metrics_viewer" {
  principal   = "User:${confluent_service_account.metrics.id}"
  role_name   = "MetricsViewer"
  crn_pattern = confluent_environment.main.resource_name
}

# No managed_resource block => a cloud-scoped API key, which is what
# api.telemetry.confluent.cloud requires.
resource "confluent_api_key" "metrics" {
  display_name = "${local.name}-metrics"
  description  = "Metrics API scrape key for the demo's Prometheus"

  owner {
    id          = confluent_service_account.metrics.id
    api_version = confluent_service_account.metrics.api_version
    kind        = confluent_service_account.metrics.kind
  }

  depends_on = [confluent_role_binding.metrics_viewer]
}

# Grafana keeps an admin login behind the anonymous viewer access so panels can
# still be edited. Generated rather than left on admin/admin, whose forced
# password-change prompt is an unpleasant thing to hit during a live demo.
resource "random_password" "grafana_admin" {
  length  = 20
  special = false
}
