# Adding New Resource Types

This guide explains how to add a new priced resource to the estimator.

## How The Pipeline Works

1. `src/configs/demo-estimate.yaml` and `src/configs/profiles.yaml` define baseline and spoke resources using the same typed shape.
  - `src/configs/estimate.schema.json` and `src/configs/profiles.schema.json` provide editor validation and completion.
2. `src/configs/manual-pricing.yaml` provides default prices for manual service items.
3. `src/configs/service-meter-map.yaml` defines Azure Retail API lookup rules:
   - service name
   - optional service-level filters
   - meter keys and matching constraints
4. Emitter functions (`src/emitters/baseline.sh` and `src/emitters/spokes.sh`) convert config inputs into line items:
   - quantity math
   - unit price lookup via `price_for`
   - output rows via `add_item`
5. `output/line-items.json` and `output/line-items.csv` are generated.

## File Responsibilities

- `src/configs/demo-estimate.yaml`: user intent and quantities
- `src/configs/estimate.schema.json`: estimate-file schema used by YAML tooling for completion and validation
- `src/configs/profiles.schema.json`: profile-overlay schema used by YAML tooling for completion and validation
- `src/configs/profiles.yaml`: profile overlays with the same resource schema as estimate
- `src/configs/manual-pricing.yaml`: baseline defaults for manual/non-API priced items
- `src/configs/service-meter-map.yaml`: API matching rules
- `src/az-cost.sh`: merge/orchestration and output formatting
- `src/emitters/baseline.sh`: baseline + shared service emitters
- `src/emitters/spokes.sh`: spoke and cross-scope resource emitters

## Resource Schema (Baseline + Spokes)

Use the same schema in both places:

- `baseline.resources`: array (or keyed object map) of typed resources
- `spokes[].resources`: array (or keyed object map) of typed resources

Typed resource shape:

```yaml
type: vm
enabled: true
# resource-specific fields...
```

Examples:

```yaml
baseline:
  resources:
    - type: vm
      count: 2
      size: "Standard_D4s_v5"
      os: "windows"

spokes:
  - name: app1
    resources:
      - type: app_gateway_waf
        sku: "WAF_v2"
```

## Manual Pricing Defaults

- Defaults are loaded from `src/configs/manual-pricing.yaml` (or a custom file path passed as arg 5).
- Override precedence is:
  - `manual-pricing.yaml` defaults
  - `profiles.yaml` values
  - `estimate.yaml` values
- This is used for manual-priced items such as Managed Services SWAT rates and Entra P2 price assumptions.

## Step 1: Add Or Update Meter Map Rules

Add or update a service under the cloud block in `src/configs/service-meter-map.yaml`.

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

## Step 2: Create The Emitter

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

## Step 3: Add The Emitter Function

Dispatch is automatic by resource type. The script calls `emit_<type>`.

- `type: vm` -> `emit_vm`
- `type: app_gateway_waf` -> `emit_app_gateway_waf`

Type normalization:

- Hyphens are converted to underscores (`app-gateway-waf` -> `emit_app_gateway_waf`)
- `app_gateway` aliases to `app_gateway_waf`

If a type has no emitter, the script warns and falls back to `emit_custom` placeholder pricing.

## Step 4: Add Config Shape In demo-estimate.yaml

Document and add example input under baseline and/or spokes (same typed shape).

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

## Step 5: Update The Estimate Schema

When a new resource type or input field is added, update both `src/configs/estimate.schema.json` and `src/configs/profiles.schema.json` so users get completion and validation while editing estimate/profile files.

Minimum schema updates:

- Add a new resource definition under `$defs` for the new `type` (for array-style resources) in `src/configs/estimate.schema.json`.
- Add a no-type companion definition for keyed-object resources (for example `vmNoType`) in `src/configs/estimate.schema.json`.
- Register both definitions in `oneOf` lists under `$defs.resource` and `$defs.resourceWithoutType` in `src/configs/estimate.schema.json`.
- Ensure `src/configs/profiles.schema.json` references the updated `#/$defs/resources` from `src/configs/estimate.schema.json` (or update it if you decouple schemas later).
- Add or update field descriptions/defaults so hints in editors stay accurate.

Validation tip:

- Open `src/configs/demo-estimate.yaml` and `src/configs/profiles.yaml` in VS Code and verify completions and warnings reflect your new type/fields.

## Step 6: Validate

Run:

```bash
./src/az-cost.sh src/configs/demo-estimate.yaml src/configs/profiles.yaml src/configs/service-meter-map.yaml output/
```

Check:

- `source` should be `api` for successful meter matches.
- Missing matches show `source: missing`.
- Console warnings indicate enabled types without implemented emitters.

## Practical Notes

- API naming differs by cloud (`azuregov` vs commercial). Tune per cloud block.
- Keep quantity units and meter units aligned (`hour`, `GB`, `GB-month`, etc.).
- If one meter key can return multiple rows, tighten regex/contains filters before trusting results.
