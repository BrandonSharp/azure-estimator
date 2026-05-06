#!/usr/bin/env bash

emit_azure_firewall() {
  local cfg="$1"
  local sku inst data_gb notes
  sku="$(echo "$cfg" | jq -r '.sku // "Standard"')"
  inst="$(echo "$cfg" | jq -r '.instances // 1')"
  data_gb="$(echo "$cfg" | jq -r '.data_processed_gb_per_month // 0')"
  notes="$(notes_from_cfg "$cfg")"

  local p_base; p_base="$(price_for "azure_firewall" "base_hour" "$sku")"
  local qty_base; qty_base="$(jq -n --argjson i "$inst" --argjson h "$hpm" '$i*$h')"
  add_item "Azure Firewall (${sku}) - base" "hour" "$qty_base" "${p_base:-0}" "$(source_from_price "$p_base")" \
    "$(jq -n --arg sku "$sku" '{sku:$sku}')" "$notes"

  if [[ "$data_gb" != "0" ]]; then
    local p_data; p_data="$(price_for "azure_firewall" "data_gb" "$sku")"
    add_item "Azure Firewall (${sku}) - data processed" "GB" "$data_gb" "${p_data:-0}" "$(source_from_price "$p_data")" \
      "$(jq -n --arg sku "$sku" '{sku:$sku}')" "$notes"
  fi
}

emit_nat_gateway() {
  local cfg="$1"
  local g data_gb notes
  g="$(echo "$cfg" | jq -r '.gateways // 1')"
  data_gb="$(echo "$cfg" | jq -r '.data_processed_gb_per_month // 0')"
  notes="$(notes_from_cfg "$cfg")"

  local p_base; p_base="$(price_for "nat_gateway" "base_hour")"
  local qty_base; qty_base="$(jq -n --argjson gg "$g" --argjson h "$hpm" '$gg*$h')"
  add_item "NAT Gateway - base" "hour" "$qty_base" "${p_base:-0}" "$(source_from_price "$p_base")" "{}" "$notes"

  if [[ "$data_gb" != "0" ]]; then
    local p_data; p_data="$(price_for "nat_gateway" "data_gb")"
    add_item "NAT Gateway - data processed" "GB" "$data_gb" "${p_data:-0}" "$(source_from_price "$p_data")" "{}" "$notes"
  fi
}

emit_public_ip() {
  local cfg="$1"
  local sku count hours notes
  sku="$(echo "$cfg" | jq -r '.sku // "Standard"')"
  count="$(echo "$cfg" | jq -r '.count // 1')"
  hours="$(echo "$cfg" | jq -r '.hours_per_month // 730')"
  notes="$(notes_from_cfg "$cfg")"

  local p_hour; p_hour="$(price_for "ip_addresses" "public_ip_hour" "$sku")"
  local qty; qty="$(jq -n --argjson c "$count" --argjson h "$hours" '$c*$h')"
  add_item "Public IP (${sku})" "hour" "$qty" "${p_hour:-0}" "$(source_from_price "$p_hour")" \
    "$(jq -n --arg sku "$sku" --argjson c "$count" '{sku:$sku, count:$c}')" "$notes"
}

emit_azure_backup() {
  local cfg="$1"
  local backup_storage_gb notes
  backup_storage_gb="$(echo "$cfg" | jq -r '.backup_storage_gb_per_month // 0')"
  notes="$(notes_from_cfg "$cfg")"

  while read -r pi; do
    local tier count p_inst
    tier="$(echo "$pi" | jq -r '.tier // "Unknown"')"
    count="$(echo "$pi" | jq -r '.count // 0')"
    [[ "$count" == "0" ]] && continue

    p_inst="$(price_for "azure_backup" "protected_instance")"
    add_item "Azure Backup - protected instance (${tier})" "instance-month" "$count" "${p_inst:-0}" "$(source_from_price "$p_inst")" \
      "$(jq -n --arg t "$tier" '{tier:$t}')" "$notes"
  done < <(echo "$cfg" | jq -c '.protected_instances[]?')

  if [[ "$backup_storage_gb" != "0" ]]; then
    local p_storage
    p_storage="$(price_for "azure_backup" "backup_storage")"
    add_item "Azure Backup - storage" "GB-month" "$backup_storage_gb" "${p_storage:-0}" "$(source_from_price "$p_storage")" "{}" "$notes"
  fi
}

emit_vpn_gateway() {
  local cfg="$1"
  local sku count hours notes
  sku="$(echo "$cfg" | jq -r '.sku // empty')"
  count="$(echo "$cfg" | jq -r '.count // 1')"
  hours="$(echo "$cfg" | jq -r '.hours_per_month // 730')"
  notes="$(notes_from_cfg "$cfg")"

  local p_hour; p_hour="$(price_for "vpn_gateway" "gateway_hour" "$sku")"
  local qty; qty="$(jq -n --argjson c "$count" --argjson h "$hours" '$c*$h')"
  add_item "VPN Gateway${sku:+ (${sku})}" "hour" "$qty" "${p_hour:-0}" "$(source_from_price "$p_hour")" \
    "$(jq -n --arg sku "$sku" --argjson c "$count" '{sku:$sku, count:$c}')" "$notes"
}

emit_app_gateway_waf() {
  local cfg="$1"
  local sku hours cu_avg product_hint notes
  sku="$(echo "$cfg" | jq -r '.sku // "WAF_v2"')"
  hours="$(echo "$cfg" | jq -r '.hours_per_month // 730')"
  cu_avg="$(echo "$cfg" | jq -r '.capacity_units_per_hour_avg // 0')"
  notes="$(notes_from_cfg "$cfg")"

  case "$sku" in
    WAF_v2|waf_v2|WAFv2|wafv2) product_hint="WAF v2" ;;
    Standard_v2|standard_v2|Standardv2|standardv2) product_hint="Standard v2" ;;
    *) product_hint="$(echo "$sku" | tr '_' ' ')" ;;
  esac

  local p_base; p_base="$(price_for "app_gateway" "base_hour" "" "$product_hint")"
  add_item "Application Gateway (${sku}) - base" "hour" "$hours" "${p_base:-0}" "$(source_from_price "$p_base")" \
    "$(jq -n --arg sku "$sku" '{sku:$sku}')" "$notes"

  if [[ "$cu_avg" != "0" ]]; then
    local p_cu qty_cu
    p_cu="$(price_for "app_gateway" "capacity_unit" "" "$product_hint")"
    qty_cu="$(jq -n --argjson h "$hours" --argjson cu "$cu_avg" '$h*$cu')"
    add_item "Application Gateway (${sku}) - capacity units" "CU-hour" "$qty_cu" "${p_cu:-0}" "$(source_from_price "$p_cu")" \
      "$(jq -n --arg sku "$sku" --argjson cu "$cu_avg" '{sku:$sku, capacity_units_per_hour_avg:$cu}')" "$notes"
  fi
}

emit_managed_services() {
  local swat_teams rate_per_team team_size notes
  swat_teams="$(echo "$pricing" | jq -r '.managed_services.swat_teams // 0')"
  rate_per_team="$(jq -n --argjson pr "$pricing" --argjson md "$manual_defaults_json" '($pr.managed_services.rate_per_team_per_month // $md.pricing.managed_services.rate_per_team_per_month // 0)')"
  team_size="$(jq -n --argjson pr "$pricing" --argjson md "$manual_defaults_json" '($pr.managed_services.people_per_team // $md.pricing.managed_services.people_per_team // 6)')"
  notes="$(echo "$pricing" | jq -r '.managed_services.notes // empty')"

  if [[ "$swat_teams" != "0" ]]; then
    add_item "Managed Services - SWAT team" "team-month" "$swat_teams" "$rate_per_team" "manual" \
      "$(jq -n --argjson t "$swat_teams" --argjson r "$rate_per_team" --argjson p "$team_size" '{swat_teams:$t, rate_per_team_per_month:$r, people_per_team:$p}')" "$notes"
  fi
}

emit_bastion() {
  local cfg="$1"
  local sku hours data_out notes
  sku="$(echo "$cfg" | jq -r '.sku // "Standard"')"
  hours="$(echo "$cfg" | jq -r '.hours_per_month // 730')"
  data_out="$(echo "$cfg" | jq -r '.data_out_gb_per_month // 0')"
  notes="$(notes_from_cfg "$cfg")"

  local p_base; p_base="$(price_for "bastion" "base_hour" "$sku")"
  add_item "Azure Bastion (${sku}) - base" "hour" "$hours" "${p_base:-0}" "$(source_from_price "$p_base")" \
    "$(jq -n --arg sku "$sku" '{sku:$sku}')" "$notes"

  if [[ "$data_out" != "0" ]]; then
    local p_out; p_out="$(price_for "bastion" "data_out" "$sku")"
    add_item "Azure Bastion (${sku}) - data out" "GB" "$data_out" "${p_out:-0}" "$(source_from_price "$p_out")" \
      "$(jq -n --arg sku "$sku" '{sku:$sku}')" "$notes"
  fi
}

emit_log_analytics() {
  local cfg="$1"
  local context_label="${2:-Baseline}"
  if [[ "$context_label" == "Baseline" ]]; then
    emit_log_analytics_common "$cfg" "Log Analytics"
  else
    emit_log_analytics_common "$cfg" "Log Analytics (${context_label})"
  fi
}

emit_sentinel() {
  local cfg="$1"
  local ingest_gb_day commitment notes
  ingest_gb_day="$(echo "$cfg" | jq -r '.ingest_gb_per_day // 0')"
  commitment="$(echo "$cfg" | jq -r '.commitment_tier_gb_per_day // 0')"
  notes="$(notes_from_cfg "$cfg")"

  local gb_month; gb_month="$(jq -n --argjson g "$ingest_gb_day" '$g*30')"

  if [[ "$commitment" != "0" ]]; then
    add_item "Microsoft Sentinel - commitment tier (ASSUMPTION)" "month" 1 0 "assumption" \
      "$(jq -n --argjson c "$commitment" '{commitment_gb_per_day:$c}')" "$notes"
  else
    local p_ingest; p_ingest="$(price_for "sentinel" "ingest_gb")"
    add_item "Microsoft Sentinel - paygo" "GB" "$gb_month" "${p_ingest:-0}" "$(source_from_price "$p_ingest")" "{}" "$notes"
  fi
}

emit_entra_p2() {
  local cfg="$1"
  local users price_year notes
  users="$(echo "$cfg" | jq -r '.users // 0')"
  price_year="$(jq -n --argjson c "$cfg" --argjson pr "$pricing" --argjson md "$manual_defaults_json" '($c.price_per_user_per_year // $pr.manual_services.entra_p2.price_per_user_per_year // $md.pricing.manual_services.entra_p2.price_per_user_per_year // 0)')"
  notes="$(notes_from_cfg "$cfg")"
  local price_month; price_month="$(jq -n --argjson py "$price_year" '$py/12')"
  add_item "Entra ID P2 (license)" "user-month" "$users" "$price_month" "manual" "{}" "$notes"
}

emit_defender() {
  local cfg="$1"
  local servers sql storage notes
  servers="$(echo "$cfg" | jq -r '.servers // 0')"
  sql="$(echo "$cfg" | jq -r '.sql // 0')"
  storage="$(echo "$cfg" | jq -r '.storage // 0')"
  notes="$(notes_from_cfg "$cfg")"

  add_item "Defender for Cloud - Servers (ASSUMPTION)" "server-month" "$servers" 0 "assumption" "{}" "$notes"
  add_item "Defender for Cloud - SQL (ASSUMPTION)" "sql-month" "$sql" 0 "assumption" "{}" "$notes"
  add_item "Defender for Cloud - Storage (ASSUMPTION)" "storage-month" "$storage" 0 "assumption" "{}" "$notes"
}

