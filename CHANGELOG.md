# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-03-08

### Added

- **Igniter Mix tasks** — 8 generators for common architecture patterns:
  - `mix igniter.install arch_test` / `mix arch_test.install` — basic arch test file with cycle check
  - `mix arch_test.gen.phoenix` — opinionated Phoenix setup (layers + naming + conventions)
  - `mix arch_test.gen.layers` — classic web → context → repo layered architecture
  - `mix arch_test.gen.onion` — onion / hexagonal architecture (domain → application → adapters → web)
  - `mix arch_test.gen.modulith` — bounded-context slice isolation
  - `mix arch_test.gen.naming` — naming convention rules (no Managers, schema placement)
  - `mix arch_test.gen.conventions` — code hygiene checks (no `IO.puts`, `dbg`, bare `raise`)
  - `mix arch_test.gen.freeze` — freeze baseline for gradual adoption
- **Optional Igniter dependency** — `{:igniter, "~> 0.7", only: [:dev, :test], optional: true, runtime: false}`

## [0.1.2] - 2026-03-07

### Added

- `Modulith.all_modules_covered_by/3` — asserts that every module under a
  namespace pattern belongs to a declared slice. Modules that escape slice
  coverage cause an explicit test failure instead of being silently ignored.
  Supports `:except` (list of glob patterns) and `:graph` (for testability).
  Also delegated from `ArchTest` as `all_modules_covered_by/2,3`.

## [0.1.1] - 2026-03-07

### Fixed

- OTP version compatibility: tests now use stable fixture modules instead of OTP-version-sensitive stdlib internals, fixing failures on OTP 26/27
- All credo `--strict` issues resolved (implicit try, `Enum.map_join`, negated if/else, nesting depth, cyclomatic complexity)

## [0.1.0] - 2026-03-06

Initial release.

### Added

- **Dependency assertions** — `should_not_depend_on/2`, `should_only_depend_on/2`, `should_not_be_called_by/2`, `should_only_be_called_by/2`, `should_not_transitively_depend_on/2`, `should_be_free_of_cycles/1`, `should_not_exist/1`
- **Naming assertions** — `should_reside_under/2`, `should_have_name_matching/2`, `should_have_module_count/2`
- **Behaviour / protocol assertions** — `should_implement_behaviour/2`, `should_not_implement_behaviour/2`, `should_implement_protocol/2`, `should_not_implement_protocol/2`
- **Module attribute assertions** — `should_have_attribute/2`, `should_not_have_attribute/2`, `should_have_attribute_value/3`, `should_not_have_attribute_value/3`
- **Function assertions** — `should_export/3`, `should_not_export/3`, `should_have_public_functions_matching/2`, `should_not_have_public_functions_matching/2`, `should_use/2`, `should_not_use/2`
- **Layered architecture** — `define_layers/1` + `enforce_direction/1`, `define_onion/1` + `enforce_onion_rules/1`
- **Modulith / bounded-context isolation** — `define_slices/1`, `allow_dependency/3`, `enforce_isolation/1`, `should_not_depend_on_each_other/1`
- **`ArchTest.Conventions`** — pre-built checks: `no_io_puts_in/2`, `no_process_sleep_in/2`, `no_application_get_env_in/2`, `no_dbg_in/2`, `no_raise_string_in/2`, `no_plug_in/2`, `all_public_functions_documented/2`
- **`ArchTest.Metrics`** — afferent/efferent coupling, instability, abstractness, distance from main sequence (Martin metrics)
- **`ArchTest.Freeze`** — violation baseline freezing for gradual adoption; `ARCH_TEST_UPDATE_FREEZE=true` mode
- **`ArchTest.ModuleSet`** — fluent module selection DSL: glob patterns, `excluding/2`, `union/2`, `intersection/2`, `satisfying/1`
- **`ArchTest.Pattern`** — glob pattern compiler with `*` (single segment) and `**` (multi-segment) wildcards
- **`ArchTest.Collector`** — BEAM-native dependency graph builder via OTP `:xref`; works on compiled bytecode, no source parsing
- **Conventions support for both legacy and modern BEAM debug formats** — handles both `:abstract_code` (OTP < 24) and `:debug_info_v1` with `:elixir_erl` backend (Elixir 1.14+)
