# Adding New Resource Types

This guide explains how to add a new priced resource to the estimator.

## How The Pipeline Works

1. `configs/estimate.yaml` (and optional profile overlays) define enabled baseline and spoke resources.
2. `configs/manual-pricing.yaml` provides default prices for manual service items.
3. `configs/service-meter-map.yaml` defines Azure Retail API lookup rules:
   - service name
   - optional service-level filters
   - meter keys and matching constraints
4. `az-cost.sh` emitter functions convert config inputs into line items:
   - quantity math
   - unit price lookup via `price_for`
   - output rows via `add_item`
5. `output/line-items.json` and `output/line-items.csv` are generated.

## File Responsibilities

- `configs/estimate.yaml`: user intent and quantities
- `configs/manual-pricing.yaml`: baseline defaults for manual/non-API priced items
- `configs/service-meter-map.yaml`: API matching rules
- `az-cost.sh`: computation and output formatting

## Manual Pricing Defaults

- Defaults are loaded from `configs/manual-pricing.yaml` (or a custom file path passed as arg 5).
- Override precedence is:
  - `manual-pricing.yaml` defaults
  - `profiles.yaml` values
  - `estimate.yaml` values
- This is used for manual-priced items such as Managed Services SWAT rates and Entra P2 price assumptions.

## Step 1: Add Or Update Meter Map Rules

Add or update a service under the cloud block in `configs/service-meter-map.yaml`.

Example shape:

```yaml
azuregov:
  services:
    my_service_key:
      serviceName: "Exact Azure Retail service name"
      priceType: "Consumption" # optional; defaults in script
      filters:                  # optional service-wide OData-style contains filters
        productNameContains: "Some product hint"
        skuNameContains: "Some sku hint"
      meters:
        my_meter_key:
          meterRegex: "(Hour|Hours|1 Hour)"
          skuNameContains: "Standard"       # optional
          productNameContains: "v2"         # optional
          armSkuNameContains: "D4s_v5"      # optional
          skuMatch: "^Standard$"            # optional regex on skuName
```

Tips:

- Prefer exact `serviceName` values from live API responses for your cloud/region.
- Keep meter filters narrow enough to avoid grabbing unrelated rows.
- Use `skuMatch` for regex matching, and `skuNameContains` for simpler contains matching.

## Step 2: Create The Emitter In az-cost.sh

Add an emitter function that:

1. Reads config values from the resource JSON.
2. Computes quantity.
3. Calls `price_for <service_key> <meter_key> [skuOverride] [productOverride] [armSkuOverride]`.
4. Emits rows using `add_item`.

Example skeleton:

```bash
emit_my_service() {
  local cfg="$1"
  local size count
  size="$(echo "$cfg" | jq -r '.size // "Standard"')"
  count="$(echo "$cfg" | jq -r '.count // 1')"

  local p_hour; p_hour="$(price_for "my_service_key" "my_meter_key" "$size")"
  add_item "My Service (${size})" "hour" "$count" "${p_hour:-0}" "$(source_from_price "$p_hour")"
}
```

## Step 3: Register The Emitter

### Baseline resources

Register in `emit_baseline_service()` case statement.

Example:

```bash
my_service) emit_my_service "$cfg" ;;
```

### Spoke resource types

Register in the spoke `case "$typ" in` dispatch.

Example:

```bash
my_service) emit_spoke_my_service "$r" "$spoke_name" ;;
```

If a type is missing, the script now warns and falls back to a custom placeholder for spokes.

## Step 4: Add Config Shape In estimate.yaml

Document and add example input under baseline and/or spokes.

Spoke example:

```yaml
spokes:
  - name: app1
    enabled: true
    resources:
      - type: log_analytics
        ingest_gb_per_day: 12.5
        retention_days: 90
```

## Step 5: Validate

Run:

```bash
./az-cost.sh configs/estimate.yaml configs/profiles.yaml configs/service-meter-map.yaml output/
```

Check:

- `source` should be `api` for successful meter matches.
- Missing matches show `source: missing`.
- Console warnings indicate enabled types without implemented emitters.

## Practical Notes

- API naming differs by cloud (`azuregov` vs commercial). Tune per cloud block.
- Keep quantity units and meter units aligned (`hour`, `GB`, `GB-month`, etc.).
- If one meter key can return multiple rows, tighten regex/contains filters before trusting results.
