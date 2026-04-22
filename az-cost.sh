#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-estimate.yaml}"
OUTDIR="${2:-output}"
mkdir -p "$OUTDIR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need yq
need jq
need curl
need sha256sum

urlencode() {
  # minimal urlencode for query filters
  local s="$1"
  jq -rn --arg v "$s" '$v|@uri'
}

# Basic cache to avoid re-querying the same filter repeatedly
CACHE_DIR="${CACHE_DIR:-.cache}"
mkdir -p "$CACHE_DIR"

price_query() {
  # Args: filter currency
  local filter="$1"
  local currency="$2"
  local key
  key="$(printf "%s|%s" "$filter" "$currency" | sha256sum | awk '{print $1}')"
  local cache_file="$CACHE_DIR/$key.json"

  if [[ -f "$cache_file" ]]; then
    cat "$cache_file"
    return 0
  fi

  # Common public pricing pattern: prices endpoint + $filter OData-like expressions.
  # You will likely tune serviceName/skuName/meterName/productName strings per environment.
  local enc
  enc="$(urlencode "$filter")"
  local url="https://prices.azure.com/api/retail/prices?\$filter=${enc}"

  # Handle pagination (NextPageLink) until we have Items or run out
  local tmp
  tmp="$(mktemp)"
  local page="$url"
  local merged='{"Items":[]}'
  while [[ -n "$page" && "$page" != "null" ]]; do
    curl -sS "$page" > "$tmp"
    merged="$(jq -s '{Items: (.[0].Items + .[1].Items)}' <(echo "$merged") "$tmp")"
    page="$(jq -r '.NextPageLink // empty' "$tmp")"
    # stop early if we got anything
    if [[ "$(echo "$merged" | jq '.Items | length')" -gt 0 ]]; then
      break
    fi
  done

  rm -f "$tmp"
  echo "$merged" | tee "$cache_file" >/dev/null
  cat "$cache_file"
}

first_unit_price() {
  # Args: json meter_regex(optional)
  local json="$1"
  local meter_re="${2:-.*}"
  echo "$json" | jq -r --arg re "$meter_re" '
    .Items
    | map(select((.currencyCode? // "USD") != null))
    | map(select((.meterName? // "") | test($re;"i")))
    | (.[0].unitPrice // empty)
  '
}

# Merge profile overrides into baseline (simple deep merge for baseline subtree)
config_json="$(yq -o=json '.' "$CONFIG")"
profile="$(echo "$config_json" | jq -r '.profile // "balanced"')"

merged_baseline="$(jq -n --argjson c "$config_json" --arg p "$profile" '
  def deepmerge(a;b):
    reduce (b|keys_unsorted[]) as $k (a;
      .[$k] = if (a[$k] | type) == "object" and (b[$k] | type) == "object"
              then deepmerge(a[$k]; b[$k])
              else b[$k] end);
  ($c.baseline // {}) as $base
  | ($c.profiles[$p].baseline // {}) as $ovr
  | deepmerge($base; $ovr)
')"

meta="$(echo "$config_json" | jq '.meta // {}')"
region="$(echo "$meta" | jq -r '.region // "eastus"')"
currency="$(echo "$meta" | jq -r '.currency // "USD"')"
hpm="$(echo "$meta" | jq -r '.hours_per_month // 730')"
discount_pct="$(echo "$meta" | jq -r '.discount_pct // 0')"
uplift_pct="$(echo "$meta" | jq -r '.uplift_pct // 0')"

# Normalize line items into JSON array: [{name, unit, quantity, unit_price, source}]
line_items='[]'

add_item() {
  local name="$1" unit="$2" qty="$3" unit_price="$4" source="$5"
  line_items="$(echo "$line_items" | jq --arg n "$name" --arg u "$unit" --arg s "$source" \
    --argjson q "$qty" --argjson p "$unit_price" \
    '. + [{name:$n, unit:$u, quantity:$q, unit_price:$p, source:$s}]')"
}

# --- Baseline expansion helpers ---
# Note: Filters are intentionally editable; you tune strings once and reuse.
emit_firewall() {
  local fw="$1"
  local sku instances data_gb
  sku="$(echo "$fw" | jq -r '.sku // "Standard"')"
  instances="$(echo "$fw" | jq -r '.instances // 1')"
  data_gb="$(echo "$fw" | jq -r '.data_processed_gb_per_month // 0')"

  # Base hourly
  local filter="armRegionName eq '${region}' and serviceName eq 'Azure Firewall' and priceType eq 'Consumption' and contains(skuName,'${sku}')"
  local json price
  json="$(price_query "$filter" "$currency")"
  price="$(first_unit_price "$json" 'hour|Hours')"
  if [[ -n "$price" ]]; then
    add_item "Azure Firewall (${sku}) - base" "hour" "$(jq -n --argjson i "$instances" --argjson h "$hpm" '$i*$h')" "$price" "api"
  else
    add_item "Azure Firewall (${sku}) - base (UNRESOLVED PRICE)" "hour" "$(jq -n --argjson i "$instances" --argjson h "$hpm" '$i*$h')" 0 "missing"
  fi

  # Data processed (GB)
  if [[ "$data_gb" != "0" ]]; then
    price="$(first_unit_price "$json" 'GB|Data')"
    add_item "Azure Firewall (${sku}) - data processed" "GB" "$data_gb" "${price:-0}" "${price:+api}${price:-missing}"
  fi
}

emit_nat() {
  local nat="$1"
  local gateways data_gb
  gateways="$(echo "$nat" | jq -r '.gateways // 1')"
  data_gb="$(echo "$nat" | jq -r '.data_processed_gb_per_month // 0')"

  local filter="armRegionName eq '${region}' and serviceName eq 'NAT Gateway' and priceType eq 'Consumption'"
  local json price
  json="$(price_query "$filter" "$currency")"

  price="$(first_unit_price "$json" 'hour|Hours')"
  add_item "NAT Gateway - base" "hour" "$(jq -n --argjson g "$gateways" --argjson h "$hpm" '$g*$h')" "${price:-0}" "${price:+api}${price:-missing}"

  if [[ "$data_gb" != "0" ]]; then
    price="$(first_unit_price "$json" 'GB|Data')"
    add_item "NAT Gateway - data processed" "GB" "$data_gb" "${price:-0}" "${price:+api}${price:-missing}"
  fi
}

emit_bastion() {
  local b="$1"
  local sku hours data_gb
  sku="$(echo "$b" | jq -r '.sku // "Standard"')"
  hours="$(echo "$b" | jq -r '.hours_per_month // 0')"
  data_gb="$(echo "$b" | jq -r '.data_out_gb_per_month // 0')"

  local filter="armRegionName eq '${region}' and serviceName eq 'Azure Bastion' and priceType eq 'Consumption' and contains(skuName,'${sku}')"
  local json price
  json="$(price_query "$filter" "$currency")"

  price="$(first_unit_price "$json" 'hour|Hours')"
  add_item "Azure Bastion (${sku}) - base" "hour" "$hours" "${price:-0}" "${price:+api}${price:-missing}"

  if [[ "$data_gb" != "0" ]]; then
    price="$(first_unit_price "$json" 'GB|Data|Outbound|Egress')"
    add_item "Azure Bastion (${sku}) - data out" "GB" "$data_gb" "${price:-0}" "${price:+api}${price:-missing}"
  fi
}

emit_log_analytics() {
  local law="$1"
  local ingest retention
  ingest="$(echo "$law" | jq -r '.ingest_gb_per_day // 0')"
  retention="$(echo "$law" | jq -r '.retention_days // 30')"

  local gb_month
  gb_month="$(jq -n --argjson g "$ingest" '$g*30')"

  local filter="armRegionName eq '${region}' and (serviceName eq 'Log Analytics' or contains(productName,'Log Analytics')) and priceType eq 'Consumption'"
  local json price
  json="$(price_query "$filter" "$currency")"
  price="$(first_unit_price "$json" 'GB|Data')"
  add_item "Log Analytics - ingestion" "GB" "$gb_month" "${price:-0}" "${price:+api}${price:-missing}"

  # retention is nuanced; model it as assumption in v1
  add_item "Log Analytics - retention (${retention} days) (ASSUMPTION)" "month" 1 0 "assumption"
}

emit_sentinel() {
  local s="$1"
  local ingest commitment
  ingest="$(echo "$s" | jq -r '.ingest_gb_per_day // 0')"
  commitment="$(echo "$s" | jq -r '.commitment_tier_gb_per_day // 0')"

  local gb_month
  gb_month="$(jq -n --argjson g "$ingest" '$g*30')"

  local filter="armRegionName eq '${region}' and (serviceName eq 'Microsoft Sentinel' or contains(productName,'Sentinel')) and priceType eq 'Consumption'"
  local json price
  json="$(price_query "$filter" "$currency")"

  if [[ "$commitment" != "0" ]]; then
    add_item "Microsoft Sentinel - commitment tier (CONFIG NEEDED)" "month" 1 0 "assumption"
  else
    price="$(first_unit_price "$json" 'GB|Data')"
    add_item "Microsoft Sentinel - paygo" "GB" "$gb_month" "${price:-0}" "${price:+api}${price:-missing}"
  fi
}

emit_entra_p2() {
  local e="$1"
  local users price_year
  users="$(echo "$e" | jq -r '.users // 0')"
  price_year="$(echo "$e" | jq -r '.price_per_user_per_year // 0')"
  local price_month
  price_month="$(jq -n --argjson py "$price_year" '$py/12')"
  add_item "Entra ID P2 (license)" "user-month" "$users" "$price_month" "manual"
}

# --- Spoke resources (v1: VM via API, storage as assumption/custom) ---
emit_vm() {
  local vm="$1" spoke="$2"
  local count size hours os
  count="$(echo "$vm" | jq -r '.count // 1')"
  size="$(echo "$vm" | jq -r '.size')"
  hours="$(echo "$vm" | jq -r '.hours_per_month // 0')"
  os="$(echo "$vm" | jq -r '.os // "linux"')"

  local filter="armRegionName eq '${region}' and serviceName eq 'Virtual Machines' and priceType eq 'Consumption' and contains(armSkuName,'${size}')"
  local json price
  json="$(price_query "$filter" "$currency")"
  # meters vary; try to match “Linux” / “Windows” if present
  if [[ "$os" == "windows" ]]; then
    price="$(first_unit_price "$json" 'Windows|hour|Hours')"
  else
    price="$(first_unit_price "$json" 'Linux|hour|Hours')"
  fi
  add_item "VM (${spoke}) ${size} (${os})" "hour" "$(jq -n --argjson c "$count" --argjson h "$hours" '$c*$h')" "${price:-0}" "${price:+api}${price:-missing}"
}

emit_custom() {
  local r="$1" spoke="$2"
  local name unit qty up
  name="$(echo "$r" | jq -r '.name')"
  unit="$(echo "$r" | jq -r '.unit // "each"')"
  qty="$(echo "$r" | jq -r '.quantity // 1')"
  up="$(echo "$r" | jq -r '.unit_price // 0')"
  add_item "Custom (${spoke}) - ${name}" "$unit" "$qty" "$up" "manual"
}

# ---- Build baseline ----
if [[ "$(echo "$merged_baseline" | jq -r '.azure_firewall.enabled // false')" == "true" ]]; then
  emit_firewall "$(echo "$merged_baseline" | jq '.azure_firewall')"
fi
if [[ "$(echo "$merged_baseline" | jq -r '.nat_gateway.enabled // false')" == "true" ]]; then
  emit_nat "$(echo "$merged_baseline" | jq '.nat_gateway')"
fi
if [[ "$(echo "$merged_baseline" | jq -r '.bastion.enabled // false')" == "true" ]]; then
  emit_bastion "$(echo "$merged_baseline" | jq '.bastion')"
fi
if [[ "$(echo "$merged_baseline" | jq -r '.log_analytics.enabled // false')" == "true" ]]; then
  emit_log_analytics "$(echo "$merged_baseline" | jq '.log_analytics')"
fi
if [[ "$(echo "$merged_baseline" | jq -r '.sentinel.enabled // false')" == "true" ]]; then
  emit_sentinel "$(echo "$merged_baseline" | jq '.sentinel')"
fi
if [[ "$(echo "$merged_baseline" | jq -r '.entra_p2.enabled // false')" == "true" ]]; then
  emit_entra_p2 "$(echo "$merged_baseline" | jq '.entra_p2')"
fi

# ---- Build spokes ----
spokes="$(echo "$config_json" | jq '.spokes // []')"
echo "$spokes" | jq -c '.[]' | while read -r s; do
  enabled="$(echo "$s" | jq -r '.enabled // true')"
  [[ "$enabled" == "true" ]] || continue
  spoke_name="$(echo "$s" | jq -r '.name')"
  echo "$s" | jq -c '.resources[]?' | while read -r r; do
    typ="$(echo "$r" | jq -r '.type')"
    case "$typ" in
      vm) emit_vm "$r" "$spoke_name" ;;
      custom) emit_custom "$r" "$spoke_name" ;;
      *) emit_custom "$(echo "$r" | jq --arg n "$typ" '. + {name: (.name // $n), unit:"each", quantity:(.count // 1), unit_price:(.unit_price // 0)}')" "$spoke_name" ;;
    esac
  done
done

# ---- Totals + discount/uplift ----
line_items_json="$(echo "$line_items" | jq '
  map(.extended = (.quantity * .unit_price))
')"

subtotal="$(echo "$line_items_json" | jq '[.[].extended] | add // 0')"
discount_amt="$(jq -n --argjson s "$subtotal" --argjson d "$discount_pct" '$s * ($d/100)')"
uplift_amt="$(jq -n --argjson s "$subtotal" --argjson u "$uplift_pct" '$s * ($u/100)')"
total="$(jq -n --argjson s "$subtotal" --argjson da "$discount_amt" --argjson ua "$uplift_amt" '$s - $da + $ua')"

# write outputs
echo "$line_items_json" > "$OUTDIR/line-items.json"
echo "name,unit,quantity,unit_price,extended,source" > "$OUTDIR/line-items.csv"
echo "$line_items_json" | jq -r '.[] | [.name,.unit,.quantity,.unit_price,.extended,.source] | @csv' >> "$OUTDIR/line-items.csv"

# pretty print summary
printf "\nEstimate (%s, %s, profile=%s)\n" "$(echo "$meta" | jq -r '.customer // "Customer"')" "$region" "$profile"
printf "Subtotal: %.2f %s\n" "$subtotal" "$currency"
printf "Discount: -%.2f (%s%%)\n" "$discount_amt" "$discount_pct"
printf "Uplift:   +%.2f (%s%%)\n" "$uplift_amt" "$uplift_pct"
printf "TOTAL:    %.2f %s\n\n" "$total" "$currency"

echo "$line_items_json" | jq -r '
  ["Item","Unit","Qty","Unit Price","Ext","Source"],
  ( .[] | [.name,.unit,(.quantity|tostring),(.unit_price|tostring),(.extended|tostring),.source] )
  | @tsv
' | column -t -s $'\t'