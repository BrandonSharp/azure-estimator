# Azure Estimator

Estimate monthly Azure costs from YAML inputs using Azure Retail Prices API lookups plus manual pricing defaults.

## What this project does

- Merges values from:
  - `src/configs/manual-pricing.yaml`
  - `src/configs/profiles.yaml`
  - estimate file (for example `estimates/test-estimate.yaml`)
- Resolves retail prices using `src/configs/service-meter-map.yaml`
- Emits detailed line items and a Markdown summary report
- Supports baseline and spoke workloads with typed resources

## Repository layout

- `src/az-cost.sh`: main orchestration script
- `src/configs/`: YAML configs and JSON schemas
- `src/emitters/`: resource pricing emitters
- `src/parsers/`: import helpers (for example Bicep)
- `estimates/`: user estimate files
- `output/`: generated reports and line-item outputs
- `.vscode/tasks.json`: ready-to-run VS Code tasks
- `doc/adding-resource-types.md`: guide for adding new resource types

## Prerequisites

Required CLI tools:

- `bash`
- `yq`
- `jq`
- `curl`
- `sha256sum`
- `column`

Optional (for helper task):

- `az` CLI (logged in and set to appropriate cloud/subscription)

## Quick start

1. Create or edit an estimate file in `estimates/`.
2. Set `profile` to a key present in `src/configs/profiles.yaml`.
3. Run one of the following:

### Option A: VS Code task (recommended)

Run task:

- `Estimate: Run az-cost for active file`

Behavior:

- Uses the currently focused file as estimate input
- Always uses `src/configs/profiles.yaml`
- Writes outputs to `output/<estimate-file-basename-no-extension>/`

### Option B: Direct CLI

```bash
./src/az-cost.sh \
  estimates/test-estimate.yaml \
  src/configs/profiles.yaml \
  src/configs/service-meter-map.yaml \
  output/test-estimate \
  src/configs/manual-pricing.yaml
```

## Outputs

Each run writes into the output directory you pass in:

- `estimate-report.md`: human-readable summary
- `line-items.json`: machine-readable line items
- `line-items.csv`: tabular export

## YAML schema and completion

VS Code YAML completion/validation is configured via:

- `src/configs/estimate.schema.json`
- `src/configs/profiles.schema.json`
- `.vscode/settings.json` schema mappings

You can also include schema hints in YAML files with:

```yaml
# yaml-language-server: $schema=./estimate.schema.json
```

## Common troubleshooting

- Cost is zero but source is `api`:
  - Check quantity fields (`hours_per_month`, `count`, `ingest_gb_per_day`, etc.).
- Source is `missing`:
  - Meter lookup did not match any price rows. Tighten or update mapping in `src/configs/service-meter-map.yaml`.
- Profile not applying:
  - Ensure estimate `profile` matches a key in `src/configs/profiles.yaml`.
- Unexpected totals:
  - Remember precedence: `manual-pricing.yaml` -> `profiles.yaml` -> estimate file.

## Getting VM SKU names by region

Run task:

- `Azure: List VM SKUs in region`

Inputs:

- Region prompt (default `usgovvirginia`)
- Optional case-insensitive contains filter for SKU names

## Contributing

For new resource types and meter wiring, follow:

- `doc/adding-resource-types.md`
