# Dashboard Fase 2 (NON provisionate)

Dashboard che richiedono datasource non ancora deployati:

- `mimir-*` → metriche via Mimir/Prometheus (`prometheus.remote_write` commentato in `config.alloy`)
- `trace-*` → trace via Tempo (`otelcol.exporter.otlp` commentato in `config.alloy`)
- `JVM_Spring`, `Spring_boot_3.x_dashboard`, `dashboard_*_metrics`, `docker_*`, `monitor_services`,
  `grafana-agent-receiver`, `rollout-operator`, `dashboard`, `893_rev5`, `1860_rev32`,
  `17024_rev1`, `395_rev1` → metriche Prometheus (node-exporter / cAdvisor / JMX)

Spostate qui fuori da `dashboards/` (che Grafana provisiona) perche' senza il datasource
mostrano solo "No data"/errori. Rimetterle in `dashboards/` quando Mimir/Tempo/Prometheus
saranno in stack (Fase 2 — vedi commenti in `config.alloy`).

## Dashboard Loki generiche (schema label diverso)

- `frontend-application` (Frontend web-vitals) → richiede dati Faro (`{kind="measurement"}`), non attivi
- `logging_dashboard`, `loki_example` → label k8s (`container`/`pod`/`stream`/`namespace`), qui si usa `container_name`
- `Loki_logs_app` → label `job`, non impostata
- `Pcs_Loki_Dash_` → label `app`/`level`, presenti solo per il frontend / non come label

Le dashboard di log utili per questo stack sono le `irccs-*` (audit trail, timeline paziente,
attivita' utente, metriche log).
