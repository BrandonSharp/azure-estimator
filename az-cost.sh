#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# az-cost.sh
#
# Usage:
#   ./az-cost.sh configs/estimate.yaml configs/profiles.yaml configs/service-meter-map.yaml output/ [configs/manual-pricing.yaml]
#
# Expected YAML shapes (high-level):
#
# estimate.yaml:
#   meta:
#     customer: "..."
#     cloud: "azuregov" | "commercial"
#     region: "usgovvirginia" | "eastus" | ...
#     currency: "USD"
#     hours_per_month: 730
#   pricing:
#     discount_pct: 0
#     uplift_pct: 0
#     managed_services:                 # optional
#       swat_teams: 0                   # supports fractional values, e.g. 1.5
#       rate_per_team_per_month: 2000
#   profile: "balanced"
#   baseline: { ... components ... }
#   spokes: [ { name, enabled, resources:[...] }, ... ]
#
# profiles.yaml:
#   balanced:
#     baseline:
#       resources:
#         - type: azure_firewall
#           enabled: true
#           sku: "Standard"
#     meta: { ... overrides ... }        # optional
#     pricing: { ... overrides ... }     # optional
#
# service-meter-map.yaml:
#   azuregov:
#     api:
#       base_url: "https://prices.azure.com/api/retail/prices"
#       api_version: "2023-01-01-preview"
#     services:
#       azure_firewall:
#         serviceName: "Azure Firewall"
#         priceType: "Consumption"
#         filters: { }                     # optional extra filters
#         meters:
#           base_hour:
#             meterRegex: "(Hour|Hours)"
#             skuNameContains: "Standard"  # optional
#           data_gb:
#             meterRegex: "(GB|Data)"
#
# Notes:
# - Filter values can be case-sensitive on newer API versions. Keep map values exact. [1](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
# - Pagination uses NextPageLink until enough Items are collected. [2](https://prices.azure.com/api/retail/prices)
# ------------------------------------------------------------------------------

ESTIMATE_YAML="${1:-configs/estimate.yaml}"
PROFILES_YAML="${2:-configs/profiles.yaml}"
METERMAP_YAML="${3:-configs/service-meter-map.yaml}"
OUTDIR="${4:-output}"
MANUAL_PRICING_YAML="${5:-configs/manual-pricing.yaml}"

mkdir -p "$OUTDIR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need yq
need jq
need curl
need sha256sum
need column

CACHE_DIR="${CACHE_DIR:-.cache}"
CACHE_VERSION="v2"
mkdir -p "$CACHE_DIR"

# --- Helpers ------------------------------------------------------------------

urlencode() {
  # OData filter needs URL encoding; use jq to encode safely
  local s="$1"
  jq -rn --arg v "$s" '$v|@uri'
}

deepmerge_jq='
  def deepmerge(a;b):
    reduce (b|keys_unsorted[]) as $k (a;
      .[$k] = if (a[$k] | type) == "object" and (b[$k] | type) == "object"
              then deepmerge(a[$k]; b[$k])
              elif (a[$k] | type) == "array" and (b[$k] | type) == "array"
              then (a[$k] + b[$k])
              else b[$k] end);
'

# Read YAML -> JSON once
estimate_json="$(yq -o=json '.' "$ESTIMATE_YAML")"
profiles_json="$(yq -o=json '.' "$PROFILES_YAML")"
meter_map_json="$(yq -o=json '.' "$METERMAP_YAML")"
manual_defaults_json='{}'
if [[ -f "$MANUAL_PRICING_YAML" ]]; then
  manual_defaults_json="$(yq -o=json '.' "$MANUAL_PRICING_YAML")"
fi

profile="$(echo "$estimate_json" | jq -r '.profile // "balanced"')"

# Pull profile object (or empty). Supports both:
#   profiles: { balanced: {...} }
# and top-level: { balanced: {...} }
profile_obj="$(echo "$profiles_json" | jq --arg p "$profile" '(.profiles[$p] // .[$p] // {})')"

# Merge profile overrides into estimate:
# - meta, pricing, baseline are deep-merged
merged_json="$(jq -n \
  --argjson m "$manual_defaults_json" \
  --argjson e "$estimate_json" \
  --argjson p "$profile_obj" \
  "$deepmerge_jq
   def merge_section(path):
     ( \$m | getpath(path) // {} ) as \$a
     | ( \$p | getpath(path) // {} ) as \$b
     | ( \$e | getpath(path) // {} ) as \$c
     | deepmerge(deepmerge(\$a;\$b);\$c);

   {
     meta:    merge_section([\"meta\"]),
     pricing: merge_section([\"pricing\"]),
     baseline:merge_section([\"baseline\"]),
     spokes:  (\$e.spokes // [])
   } + {profile: (\$e.profile // \"balanced\")}")"

meta="$(echo "$merged_json" | jq '.meta // {}')"
pricing="$(echo "$merged_json" | jq '.pricing // {}')"
baseline="$(echo "$merged_json" | jq '.baseline // {}')"
spokes="$(echo "$merged_json" | jq '.spokes // []')"

cloud="$(echo "$meta" | jq -r '.cloud // "azuregov"')"
region="$(echo "$meta" | jq -r '.region // "usgovvirginia"')"
currency="$(echo "$meta" | jq -r '.currency // "USD"')"
hpm="$(echo "$meta" | jq -r '.hours_per_month // 730')"

discount_pct="$(echo "$pricing" | jq -r '.discount_pct // 0')"
uplift_pct="$(echo "$pricing" | jq -r '.uplift_pct // 0')"

api_base="$(echo "$meter_map_json" | jq -r --arg c "$cloud" '.[$c].api.base_url // "https://prices.azure.com/api/retail/prices"')"
api_version="$(echo "$meter_map_json" | jq -r --arg c "$cloud" '.[$c].api.api_version // "2023-01-01-preview"')"

# Create a consistent API root; preview supports full meter sets and newer behaviors. [1](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
api_root="${api_base}?api-version=${api_version}"

# --- Retail Prices API query w/ caching + light pagination --------------------

price_query() {
  # Args: filter_expr (NOT url-encoded)
  local filter="$1"
  local key
  key="$(printf "%s|%s|%s|%s" "$CACHE_VERSION" "$api_root" "$filter" "$currency" | sha256sum | awk '{print $1}')"
  local cache_file="$CACHE_DIR/$key.json"

  if [[ -f "$cache_file" ]]; then
    cat "$cache_file"
    return 0
  fi

  local enc; enc="$(urlencode "$filter")"
  local url="${api_root}&\$filter=${enc}"
  local page="$url"

  # Collect all pages so later-page SKUs are available for selection. [2](https://prices.azure.com/api/retail/prices)
  local merged='{"Items":[]}'
  while [[ -n "$page" && "$page" != "null" ]]; do
    local resp
    resp="$(curl -sS "$page")"

    merged="$(jq -s '{Items: (.[0].Items + .[1].Items)}' <(echo "$merged") <(echo "$resp"))"

    page="$(echo "$resp" | jq -r '.NextPageLink // empty')"
  done

  echo "$merged" | tee "$cache_file" >/dev/null
  cat "$cache_file"
}

# Pick a unit price from returned Items using regex + optional contains constraints
select_unit_price() {
  # Args: items_json meterRegex skuNameContains? productNameContains? armSkuNameContains? skuNameRegex?
  local json="$1"
  local meter_re="$2"
  local sku_contains="${3:-}"
  local product_contains="${4:-}"
  local armsku_contains="${5:-}"
  local sku_regex="${6:-}"

  echo "$json" | jq -r \
    --arg re "$meter_re" \
    --arg cur "$currency" \
    --arg sku "$sku_contains" \
    --arg prod "$product_contains" \
    --arg armsku "$armsku_contains" \
    --arg sku_re "$sku_regex" '
    .Items
    | map(select((.currencyCode // "USD") == $cur))
    | map(select(((.meterName // "") | test($re;"i")) or ((.unitOfMeasure // "") | test($re;"i"))))
    | (if ($sku|length)>0 then map(select((.skuName // "") | contains($sku))) else . end)
    | (if ($sku_re|length)>0 then map(select((.skuName // "") | test($sku_re;"i"))) else . end)
    | (if ($prod|length)>0 then map(select((.productName // "") | contains($prod))) else . end)
    | (if ($armsku|length)>0 then map(select((.armSkuName // "") | contains($armsku))) else . end)
    | if any(.[]?; ((.unitPrice // 0) | tonumber) > 0)
      then map(select(((.unitPrice // 0) | tonumber) > 0))
      else .
      end
    | (.[0].unitPrice // empty)
  '
}

select_vm_unit_price() {
  # Args: items_json armSkuName os
  local json="$1"
  local arm_sku="$2"
  local os="$3"

  echo "$json" | jq -r \
    --arg cur "$currency" \
    --arg armSku "$arm_sku" \
    --arg os "$os" '
    .Items
    | map(select((.currencyCode // "USD") == $cur))
    | map(select(((.unitOfMeasure // "") | test("(Hour|Hours|1 Hour)";"i")) or ((.meterName // "") | test("(Hour|Hours|1 Hour)";"i"))))
    | map(select((.armSkuName // "") == $armSku))
    | map(select((.skuName // "") == $armSku))
    | if ($os == "windows")
      then map(select((.productName // "") | contains("Windows")))
      else map(select(((.productName // "") | contains("Windows")) | not))
      end
    | if any(.[]?; ((.unitPrice // 0) | tonumber) > 0)
      then map(select(((.unitPrice // 0) | tonumber) > 0))
      else .
      end
    | (.[0].unitPrice // empty)
  '
}

# Build OData filter string from service definition + required region/serviceName/priceType
build_filter() {
  # Args: svc_key
  local svc_key="$1"
  local svc_def
  svc_def="$(echo "$meter_map_json" | jq -c --arg c "$cloud" --arg s "$svc_key" '.[$c].services[$s]')"
  if [[ -z "$svc_def" || "$svc_def" == "null" ]]; then
    echo ""
    return 0
  fi

  local serviceName priceType
  serviceName="$(echo "$svc_def" | jq -r '.serviceName')"
  priceType="$(echo "$svc_def" | jq -r '.priceType // "Consumption"')"

  # Base filters; case sensitivity depends on API version—keep serviceName exact in the map. [1](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
  local f="armRegionName eq '${region}' and priceType eq '${priceType}' and serviceName eq '${serviceName}'"

  # Optional additional filters (map.filters is array of raw OData fragments or object fields)
  # If .filters is an array: append each string with "and"
  # If .filters is an object: supports keys:
  #   productNameContains, skuNameContains, meterNameContains, armSkuNameContains
  local filters_type
  filters_type="$(echo "$svc_def" | jq -r '.filters | type? // "null"')"

  if [[ "$filters_type" == "array" ]]; then
    local extra
    extra="$(echo "$svc_def" | jq -r '.filters[]?')"
    while IFS= read -r frag; do
      [[ -n "$frag" ]] && f="${f} and (${frag})"
    done <<< "$extra"
  elif [[ "$filters_type" == "object" ]]; then
    local prod sku meter armsku
    prod="$(echo "$svc_def" | jq -r '.filters.productNameContains // empty')"
    sku="$(echo "$svc_def" | jq -r '.filters.skuNameContains // empty')"
    meter="$(echo "$svc_def" | jq -r '.filters.meterNameContains // empty')"
    armsku="$(echo "$svc_def" | jq -r '.filters.armSkuNameContains // empty')"
    [[ -n "$prod" ]] && f="${f} and contains(productName,'${prod}')"
    [[ -n "$sku" ]] && f="${f} and contains(skuName,'${sku}')"
    [[ -n "$meter" ]] && f="${f} and contains(meterName,'${meter}')"
    [[ -n "$armsku" ]] && f="${f} and contains(armSkuName,'${armsku}')"
  fi

  echo "$f"
}

# Retrieve unit price using service + meter definitions from service-meter-map.yaml
price_for() {
  # Args: svc_key meter_key skuContainsOverride? productContainsOverride? armSkuContainsOverride?
  local svc_key="$1"
  local meter_key="$2"
  local sku_override="${3:-}"
  local prod_override="${4:-}"
  local armsku_override="${5:-}"
  # # echo "Entering price_for with svc_key=$svc_key meter_key=$meter_key" >&2
  # # echo "-----------------------------------------------------------" >&2
  local svc_def meter_def
  svc_def="$(echo "$meter_map_json" | jq -c --arg c "$cloud" --arg s "$svc_key" '.[$c].services[$s]')"
  meter_def="$(echo "$meter_map_json" | jq -c --arg c "$cloud" --arg s "$svc_key" --arg m "$meter_key" '.[$c].services[$s].meters[$m]')"

  if [[ -z "$svc_def" || "$svc_def" == "null" ]]; then
    echo ""
    return 0
  fi
  if [[ -z "$meter_def" || "$meter_def" == "null" ]]; then
    echo ""
    return 0
  fi

  local filter meterRegex skuContains prodContains armSkuContains skuRegex
  filter="$(build_filter "$svc_key")"
  meterRegex="$(echo "$meter_def" | jq -r '.meterRegex')"
  skuContains="$(echo "$meter_def" | jq -r '.skuNameContains // empty')"
  prodContains="$(echo "$meter_def" | jq -r '.productNameContains // empty')"
  armSkuContains="$(echo "$meter_def" | jq -r '.armSkuNameContains // empty')"
  skuRegex="$(echo "$meter_def" | jq -r '.skuMatch // empty')"

  # Explicit config SKU wins over generic meter-map contains defaults.
  if [[ -n "$sku_override" ]]; then
    skuContains="$sku_override"
  fi
  if [[ -n "$prod_override" ]]; then
    prodContains="$prod_override"
  fi
  if [[ -n "$armsku_override" ]]; then
    armSkuContains="$armsku_override"
  fi
  
  local json; json="$(price_query "$filter")"
  local p; p="$(select_unit_price "$json" "$meterRegex" "$skuContains" "$prodContains" "$armSkuContains" "$skuRegex")"

  echo "$p"
  # # echo "Exiting price_for with price=$p" >&2
  # # exit 0
}

# --- Line items ---------------------------------------------------------------

line_items='[]'
warnings='[]'
current_section='Baseline'

source_from_price() {
  local unit_price="${1:-}"
  if [[ -n "$unit_price" ]]; then
    echo "api"
  else
    echo "missing"
  fi
}

add_warning() {
  local msg="$1"
  warnings="$(echo "$warnings" | jq --arg m "$msg" 'if index($m) then . else . + [$m] end')"
}

notes_from_cfg() {
  local cfg="${1-}"
  [[ -n "$cfg" ]] || cfg='{}'
  echo "$cfg" | jq -r '.notes // empty'
}

add_item() {
  # name unit qty unit_price source details_json(optional) notes(optional) section(optional)
  local name="$1" unit="$2" qty="$3" unit_price="$4" source="$5" details="${6:-}" notes="${7:-}" section="${8:-${current_section:-Baseline}}"
  [[ -n "$details" ]] || details='{}'
  if [[ -z "$notes" && "$details" != "{}" ]]; then
    notes="$(echo "$details" | jq -r '.notes // empty' 2>/dev/null || true)"
  fi
  line_items="$(echo "$line_items" | jq \
    --arg n "$name" --arg u "$unit" --arg s "$source" --arg notes "$notes" --arg section "$section" \
    --argjson q "$qty" --argjson p "$unit_price" --argjson d "$details" \
    '. + [{name:$n, unit:$u, quantity:$q, unit_price:$p, source:$s, details:$d, notes:$notes, section:$section}]')"
}

normalize_type_name() {
  local t="${1:-}"
  t="${t//-/_}"
  echo "$t"
}

emit_resource() {
  # Args: resource_json context_label
  local r="$1"
  local context_label="${2:-}"
  local raw_type norm_type fn
  raw_type="$(echo "$r" | jq -r '.type // empty')"

  if [[ -z "$raw_type" || "$raw_type" == "null" ]]; then
    add_warning "Encountered resource with no 'type'; skipping."
    return 0
  fi

  norm_type="$(normalize_type_name "$raw_type")"
  if [[ "$norm_type" == "app_gateway" ]]; then
    norm_type="app_gateway_waf"
  fi

  fn="emit_${norm_type}"
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn" "$r" "$context_label"
    return 0
  fi

  add_warning "Resource type '${raw_type}' has no emitter (${fn}); using custom placeholder pricing."
  emit_custom "$(echo "$r" | jq --arg n "$raw_type" '. + {name:(.name // $n), unit:(.unit // "each"), quantity:(.quantity // (.count // 1)), unit_price:(.unit_price // 0)}')" "$context_label"
}

baseline_resources_json="$(echo "$baseline" | jq -c '
  if (type != "object") then
    []
  else
    if ((.resources // null) == null) then
      []
    elif ((.resources | type) == "array") then
      .resources
    elif ((.resources | type) == "object") then
      (.resources | to_entries | map((.value // {}) + {type:.key}))
    else
      []
    end
    | map(select((.enabled // true) == true))
  end
')"

# --- Emitters ----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=emitters/shared.sh
source "$SCRIPT_DIR/emitters/shared.sh"
# shellcheck source=emitters/baseline.sh
source "$SCRIPT_DIR/emitters/baseline.sh"
# shellcheck source=emitters/spokes.sh
source "$SCRIPT_DIR/emitters/spokes.sh"

# --- Build baseline from config ----------------------------------------------

# echo "Building baseline..." >&2
# echo "Profile: $profile" >&2
# echo "Region: $region" >&2
# echo "Currency: $currency" >&2
# echo "Baseline: $baseline" >&2

while read -r r; do
  current_section='Baseline'
  emit_resource "$r" "Baseline"
done < <(echo "$baseline_resources_json" | jq -c '.[]?')

# --- Build spokes/workloads ---------------------------------------------------

while read -r s; do
  enabled="$(echo "$s" | jq -r '.enabled // true')"
  [[ "$enabled" == "true" ]] || continue

  spoke_name="$(echo "$s" | jq -r '.name // "spoke"')"
  current_section="Spoke: ${spoke_name}"

  spoke_resources_json="$(echo "$s" | jq -c '
    if ((.resources // null) == null) then
      []
    elif ((.resources | type) == "array") then
      .resources
    elif ((.resources | type) == "object") then
      (.resources | to_entries | map((.value // {}) + {type:.key}))
    else
      []
    end
    | map(select((.enabled // true) == true))
  ')"

  while read -r r; do
    emit_resource "$r" "$spoke_name"
  done < <(echo "$spoke_resources_json" | jq -c '.[]?')
done < <(echo "$spokes" | jq -c '.[]?')

# Optional managed services line items (e.g., fractional SWAT teams per month)
current_section='Managed Services'
emit_managed_services

# --- Totals + write outputs ---------------------------------------------------

line_items_json="$(echo "$line_items" | jq 'def round2: ((. * 100) | round) / 100; map(.extended = ((.quantity * .unit_price) | round2))')"

subtotal="$(echo "$line_items_json" | jq '[.[].extended] | add // 0')"
discount_amt="$(jq -n --argjson s "$subtotal" --argjson d "$discount_pct" '$s * ($d/100)')"
uplift_amt="$(jq -n --argjson s "$subtotal" --argjson u "$uplift_pct" '$s * ($u/100)')"
total="$(jq -n --argjson s "$subtotal" --argjson da "$discount_amt" --argjson ua "$uplift_amt" '$s - $da + $ua')"

# Save JSON/CSV
echo "$line_items_json" > "$OUTDIR/line-items.json"
echo "section,name,unit,quantity,unit_price,extended,source,notes" > "$OUTDIR/line-items.csv"
echo "$line_items_json" | jq -r '.[] | [(.section // "Baseline"),.name,.unit,.quantity,.unit_price,.extended,.source,(.notes // "")] | @csv' >> "$OUTDIR/line-items.csv"

cust="$(echo "$meta" | jq -r '.customer // "Customer"')"

# Save shareable Markdown report
report_md="$OUTDIR/estimate-report.md"
{
  echo "# Managed Enclave - Estimated Monthly Costs"
  echo
  printf "_Generated: %s_\n\n" "$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  printf -- "- Customer: **%s**\n" "$cust"
  printf -- "- Cloud: **%s**\n" "$cloud"
  printf -- "- Region: **%s**\n" "$region"
  printf -- "- Profile: **%s**\n" "$profile"
  printf -- "- Currency: **%s**\n\n" "$currency"

  echo "## Totals (per month)"
  echo
  printf -- "- Subtotal: **%.2f %s**\n" "$subtotal" "$currency"
  printf -- "- Discount: **-%.2f (%s%%)**\n" "$discount_amt" "$discount_pct"
  printf -- "- Uplift: **+%.2f (%s%%)**\n" "$uplift_amt" "$uplift_pct"
  printf -- "- TOTAL: **%.2f %s**\n\n" "$total" "$currency"

  if [[ "$(echo "$warnings" | jq 'length')" -gt 0 ]]; then
    echo "## Warnings"
    echo
    echo "$warnings" | jq -r '.[] | "- " + .'
    echo
  fi

  while IFS= read -r section; do
    [[ -n "$section" ]] || continue
    printf "## %s\n\n" "$section"
    section_subtotal="$(echo "$line_items_json" | jq -r --arg sec "$section" '[.[] | select((.section // "Baseline") == $sec) | .extended] | add // 0')"
    printf "**Section Subtotal:** %.2f %s\n\n" "$section_subtotal" "$currency"
    echo "| Item | Unit | Qty | Unit Price | Ext | Source | Notes |"
    echo "|---|---|---:|---:|---:|---|---|"
    echo "$line_items_json" | jq -r --arg sec "$section" '
      .[]
      | select((.section // "Baseline") == $sec)
      | [(.name|tostring),(.unit|tostring),(.quantity|tostring),(.unit_price|tostring),(.extended|tostring),(.source|tostring),((.notes // "")|tostring)]
      | map(gsub("\\|"; "\\\\|") | gsub("\n"; " "))
      | "| " + join(" | ") + " |"
    '
    echo
  done < <(echo "$line_items_json" | jq -r 'reduce .[] as $item ([]; (($item.section // "Baseline") as $s | if index($s) then . else . + [$s] end)) | .[]')
} > "$report_md"
printf "\nEstimate (%s | cloud=%s | region=%s | profile=%s)\n" "$cust" "$cloud" "$region" "$profile"
printf "Subtotal: %.2f %s\n" "$subtotal" "$currency"
printf "Discount: -%.2f (%s%%)\n" "$discount_amt" "$discount_pct"
printf "Uplift:   +%.2f (%s%%)\n" "$uplift_amt" "$uplift_pct"
printf "TOTAL:    %.2f %s\n\n" "$total" "$currency"
printf "Markdown: %s\n\n" "$report_md"

if [[ "$(echo "$warnings" | jq 'length')" -gt 0 ]]; then
  echo "Warnings:"
  echo "$warnings" | jq -r '.[] | " - " + .'
  echo
fi

# Console tables by section
while IFS= read -r section; do
  [[ -n "$section" ]] || continue
  printf "%s\n" "$section"
  echo "$line_items_json" | jq -r --arg sec "$section" '
    ["Item","Unit","Qty","Unit Price","Ext","Source","Notes"],
    ( .[]
      | select((.section // "Baseline") == $sec)
      | [.name,.unit,(.quantity|tostring),(.unit_price|tostring),(.extended|tostring),.source, (.notes // "")] )
    | @tsv
  ' | column -t -s $'\t'
  section_subtotal="$(echo "$line_items_json" | jq -r --arg sec "$section" '[.[] | select((.section // "Baseline") == $sec) | .extended] | add // 0')"
  printf "Section Subtotal: %.2f %s\n\n" "$section_subtotal" "$currency"
done < <(echo "$line_items_json" | jq -r 'reduce .[] as $item ([]; (($item.section // "Baseline") as $s | if index($s) then . else . + [$s] end)) | .[]')