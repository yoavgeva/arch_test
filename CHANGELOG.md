# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `ArchTest.Effects.no_io_in_transactions/2` flags HTTP requests, network
  calls, email and published messages inside `Repo.transaction/1`,
  `Repo.transact/1` or `Ecto.Multi.run/3`, directly or through the functions
  they call: a rollback can't take them back, and the transaction holds its
  connection while they wait.
- `ArchTest.Guardrails.no_swallowed_errors/2` flags catch-all handlers that
  turn an error from the outside world into success, such as `rescue _ -> nil`
  or `{:error, _} -> nil`, and `{:error, _}` results thrown away. Errors passed
  on or recorded, parsers' errors, predicates, cleanup and Mix tasks pass.
- Two effect kinds, `:mail` (Swoosh, Bamboo, `:gen_smtp_client`) and `:publish`
  (`Phoenix.PubSub` and channel broadcasts, AMQP, Kafka), which
  `should_be_free_of_side_effects/2` accepts in `allow:`.
- `ArchTest.Effects.writes_are_authorized/2` flags controller actions,
  LiveView events and channel messages that write to the database with
  nothing tying the change to the user asking: the call that writes isn't
  given the current user or scope, and no policy, plug or router pipeline
  checks permissions. `policy:` names a project's policy modules and plugs.
- `ArchTest.Processes.no_unbounded_waits/2` flags `:infinity` timeouts,
  `receive` without `after`, and `:gen_tcp`, `:ssl` and `:httpc` calls that
  wait forever by default. A process's own receive loop, and a receive that
  takes the `:DOWN` of the process it waits on, pass.
- `ArchTest.API`, rules about what public functions take and return:
  - `no_flag_arguments/2` flags boolean parameters a function branches on.
  - `typed_identifiers/2` flags functions taking two or more `*_id`
    parameters, which a call can swap.
  - `no_stringly_typed_choices/2` flags clause heads or a `case` matching
    three or more strings, other than a parser's.
  - `no_alternative_return_types/2` flags options that change the kind of
    value a function returns, from Elixir's design anti-patterns.
- `no_io_in_transactions/2`, `no_swallowed_errors/2`, `no_unbounded_waits/2`,
  `no_flag_arguments/2`, `no_stringly_typed_choices/2` and
  `no_alternative_return_types/2` are part of `ArchTest.Recommended`;
  `writes_are_authorized/2` and `typed_identifiers/2`, which need a project's
  own judgement, aren't.

### Changed

- `Phoenix.PubSub` broadcasts count as `:publish` rather than `:process`;
  subscribing is still `:process`.

## [0.4.0] - 2026-10-26

### Added

- `ArchTest.Effects`: rules about what code does to the outside world, followed
  through every call rather than only the calls written in a function.
  - `no_queries_in_loops/2` flags N+1 queries, including those made through
    context functions, captures, `for`, `reduce` and `Stream`.
  - `should_be_free_of_side_effects/2` keeps a functional core pure, reporting
    each call that leaves it, with an `:allow` option.
  - `no_work_in_init/2` flags GenServers that do I/O in `init/1` instead of
    `handle_continue/2`.
- `%ArchTest.Violation{}` gains `:rule` and `:fix`. Violations that set them
  print their file, line, function and fix. They aren't part of freeze keys, so
  existing baselines stay valid.
- `ArchTest.Processes`, from Elixir's process anti-patterns:
  - `processes_have_one_interface/2` flags messages sent to a named process
    from outside its module ("scattered process interfaces").
  - `processes_hold_state/2` flags GenServers whose state never changes and
    whose callbacks touch nothing outside them ("code organization by
    process"), passing ones that own a resource they start or clean up.
  - `processes_are_supervised/2` flags `spawn/1`, `Task.start/1`,
    `GenServer.start/2` and `Agent.start/1` ("unsupervised processes").
- `ArchTest.TestCode`, which reads `*_test.exs` files from source and checks
  them against the compiled code:
  - `tests_use_their_subject/2` flags a test that never uses the module it's
    named after, or only mocks it.
  - `tests_dont_mock_pure_modules/2` flags Mimic, Mock and Mox mocks of code
    that touches nothing outside it.
  - `tests_dont_sleep/2` flags `Process.sleep/1` and `:timer.sleep/1`.
  - `async_tests_share_no_state/2` flags global state changed in async tests.
- `ArchTest.Guardrails`, against shortcuts that get a build green:
  - `no_suppressions/2` flags `# credo:disable-...`, `# sobelow_skip`,
    `# coveralls-ignore-...`, `@dialyzer` and `@compile` nowarn options, with an
    `:allow` option.
  - `no_stubs/2` flags functions that only raise "not implemented" or return
    `{:error, :not_implemented}`.
  - `no_functions_only_tests_call/2` flags `@doc false` functions only tests
    call.
- `ArchTest.Recommended.check/2` runs the design rules worth holding any
  project to, and reports what each finds in one assertion, with an `:except`
  option. `mix arch_test.gen.design` writes a test running it, frozen.
- The effects, processes and test code guides, and the design rule examples
  guide, whose examples a test compiles and checks.
- CI runs on Elixir 1.20 and OTP 29.

### Checked on real code

The design rules ran on three Elixir codebases: a Phoenix app, an SDK and a
library. Every finding was read, and each false positive was fixed with a
failing test first:

- `Process.monitor/1` and `link/1` compile to `:erlang` calls, which now count
  as process effects, so a GenServer that monitors its owner owns a resource.
- Starting the `ssl` application isn't network I/O; connecting is.
- A module's own `start`/`start_link` functions may start an unlinked process.
- A test uses its subject when the code it calls, or a test helper it calls,
  reaches it, including through a registry naming rule modules.
- Raw SQL that writes, as a string, an interpolated one or one a helper builds,
  is a write, not a query.
- Sleeps in polling helpers, in fakes without tests, and
  `Process.sleep(:infinity)` aren't flagged.

### Fixed

- Elixir 1.20's compiler warnings: an unused `require Logger` in
  `ArchTest.Collector`, and an always-true `is_list/1` check in
  `ArchTest.Metrics`.

## [0.3.1] - 2026-05-21

### Added

- Added executable fixture-app architecture examples covering PlantUML
  conformance, captured slices, function-level call metadata, reusable rules,
  and graph metrics against real compiled BEAM files.
- Included the fixture example docs, PlantUML diagram, and test module in the
  Hex package, with the fixture README listed in HexDocs examples.

## [0.3.0] - 2026-05-21

### Added

- `use ArchTest, app: ...` now automatically scopes assertion, layer, onion,
  and modulith checks.
- `use ArchTest, freeze: true` auto-freezes assertion wrappers, with stable
  structured violation baseline keys.
- `ArchTest.Collector.build_graph_from_paths/2`, import filters, and
  function-level `%ArchTest.Call{}` metadata via `calls/2` and
  `calls_from_path/2`.
- `ArchTest.Rule` helpers for reusable rules, ignore filters, assertion, and
  freeze integration.
- `ArchTest.Modulith.define_slices_by/2` for captured namespace slices.
- `ArchTest.PlantUML.enforce/2` for component diagram conformance.
- `ArchTest.Metrics.afferent/2`, `efferent/2`, `fan_in/2`, `fan_out/2`,
  and `dependency_depth/2`.
- `ArchTest.Layers.allow_layer_dependency/3` and
  `ArchTest.allow_layer_dependency/3` for explicit layer-direction exceptions.

### Changed

- Empty assertion subjects now fail by default. Use `allow_empty: true` when an
  empty subject is intentional.
- `should_have_module_count/2` accepts `min:` and `max:` aliases for
  `at_least:` and `at_most:`.
- `should_be_free_of_cycles/2` now supports both `ModuleSet` checks and
  `Modulith` slice-cycle checks, so documented modulith pipelines work.
- `ArchTest.Collector` filters now keep dependency graphs closed by removing
  excluded modules from both graph keys and dependency edges.
- `ArchTest.Collector.calls/2` and `calls_from_path/2` now filter callers and
  callees, ignore generated protocol/compiler noise, and report static remote
  captures plus static `apply/3` targets.
- Layer, onion, modulith, and convention helpers now consistently forward
  graph/scope options to the collector.
- `ArchTest.Metrics.martin/2` now computes each module against itself rather
  than treating the whole matched set as one package.
- `ArchTest.Metrics.coupling/2` now treats a binary namespace root and its
  descendants as one package, and counts distinct external dependencies.
- `ArchTest.Modulith.define_slices_by/2` now discovers slices from descendant
  modules and resolves concrete roots when wildcard segments precede `(*)`.
- `ArchTest.PlantUML.parse_edges/1` now ignores line comments and PlantUML
  block comments.

### Fixed

- `use ArchTest, app: ...` now correctly respects per-rule scope overrides for
  `should_have_module_count/2`.
- `use ArchTest, freeze: true` now baselines `should_have_module_count/2`
  failures and includes semantic scope options (`app`, `apps`, `paths`,
  `include`, `exclude`) in generated freeze IDs.
- Freeze update mode no longer baselines empty-subject control failures.
- `should_only_be_called_by/3` now fails on an empty protected object set by
  default, matching other subject-based assertions.
- `should_have_module_count/3` no longer treats assertion options such as
  `rule_id:` and `allow_empty:` as count constraints.
- `should_have_module_count/3` no longer treats collector scope options such as
  `apps:`, `paths:`, `include:`, `exclude:`, and `force:` as count constraints.
- Auto-freeze rule IDs for `should_have_module_count/3` no longer include
  non-semantic `graph:` data.
- Repeated `ArchTest.Rule.ignore/2` calls now accumulate filters instead of
  replacing previous filters for the same field.
- `use ArchTest` now exposes option-aware `define_layers/2`, `define_onion/2`,
  and `define_slices/2` helpers.
- Documentation examples were corrected for freeze usage, layer exceptions,
  collector options, metric helpers, and non-overlapping layer patterns.
- Added a 0.2 to 0.3 migration guide with upgrade steps and before/after code
  examples for app scoping, conventions, empty subjects, freeze baselines,
  layer patterns, modulith slices, and reusable rules.
- Igniter generators now emit `use ArchTest, app: ...`, use safer
  non-overlapping layer defaults, pass app scope to generated convention checks,
  and mark optional schema-placement checks with `allow_empty: true`.

## [0.2.1] - 2026-04-10

### Fixed

- **Compilation without Igniter** — mix task files no longer fail with `module Igniter.Mix.Task is not loaded` when Igniter is not a dependency. All task modules are now wrapped in `Code.ensure_loaded?(Igniter.Mix.Task)` guards so they are only defined when Igniter is available.

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
