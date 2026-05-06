#!/usr/bin/env bash

emit_log_analytics_common() {
  # Args: cfg_json label
  local cfg="$1"
  local label="$2"
  local ingest_gb_day retention_days notes
  ingest_gb_day="$(echo "$cfg" | jq -r '.ingest_gb_per_day // .ingest_gb_day // 0')"
  retention_days="$(echo "$cfg" | jq -r '.retention_days // 30')"
  notes="$(notes_from_cfg "$cfg")"

  local gb_month; gb_month="$(jq -n --argjson g "$ingest_gb_day" '$g*30')"
  local p_ingest; p_ingest="$(price_for "log_analytics" "ingest_gb")"
  add_item "${label} - ingestion" "GB" "$gb_month" "${p_ingest:-0}" "$(source_from_price "$p_ingest")" \
    "$(jq -n --argjson r "$retention_days" --argjson g "$ingest_gb_day" '{retention_days:$r, ingest_gb_per_day:$g}')" "$notes"

  # Retention/archival pricing is meter-specific; keep this explicit until a retention meter is added.
  if [[ "$retention_days" != "30" ]]; then
    add_item "${label} - retention (${retention_days} days) (ASSUMPTION)" "month" 1 0 "assumption" \
      "$(jq -n --argjson r "$retention_days" '{retention_days:$r}')" "$notes"
  fi
}
