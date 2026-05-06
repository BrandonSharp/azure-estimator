#!/usr/bin/env bash

emit_spoke_log_analytics() {
  # Args: resource_json spoke_name
  local r="$1" spoke="$2"
  emit_log_analytics "$r" "$spoke"
}

emit_vm() {
  local r="$1" context_label="${2:-Baseline}"
  local count size hours os notes
  count="$(echo "$r" | jq -r '.count // 1')"
  size="$(echo "$r" | jq -r '.size')"
  hours="$(echo "$r" | jq -r '.hours_per_month // 730')"
  os="$(echo "$r" | jq -r '.os // "linux"')"
  notes="$(notes_from_cfg "$r")"

  if [[ -z "$size" || "$size" == "null" ]]; then
    add_warning "VM resource in '${context_label}' is missing required field 'size'; skipping."
    return 0
  fi

  local filter; filter="$(build_filter "vm")"
  local json; json="$(price_query "$filter")"
  local p; p="$(select_vm_unit_price "$json" "$size" "$os")"

  local qty; qty="$(jq -n --argjson c "$count" --argjson h "$hours" '$c*$h')"
  add_item "VM (${context_label}) ${size} (${os})" "hour" "$qty" "${p:-0}" "$(source_from_price "$p")" \
    "$(jq -n --arg size "$size" --arg os "$os" '{armSkuNameContains:$size, os:$os}')" "$notes"
}

emit_custom() {
  local r="$1" context_label="${2:-Baseline}"
  local name unit qty up notes
  name="$(echo "$r" | jq -r '.name')"
  unit="$(echo "$r" | jq -r '.unit // "each"')"
  qty="$(echo "$r" | jq -r '.quantity // 1')"
  up="$(echo "$r" | jq -r '.unit_price // 0')"
  notes="$(notes_from_cfg "$r")"
  add_item "Custom (${context_label}) - ${name}" "$unit" "$qty" "$up" "manual" "{}" "$notes"
}
