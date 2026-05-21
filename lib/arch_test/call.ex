defmodule ArchTest.Call do
  @moduledoc """
  Function-level call metadata extracted from compiled BEAM files.

  `ArchTest.Collector.calls/2` and `calls_from_path/2` return this struct
  when debug information is available. The module-level dependency graph stays
  available for fast checks; call metadata is for diagnostics and advanced
  rules that need caller function, callee function, file, or line. `kind`
  describes how the dependency was observed, such as `:remote_call`,
  `:remote_capture`, or `:static_apply`.
  """

  @enforce_keys [:caller_module, :callee_module]
  defstruct [
    :caller_module,
    :caller_function,
    :caller_arity,
    :callee_module,
    :callee_function,
    :callee_arity,
    :file,
    :line,
    kind: :remote_call
  ]

  @type t :: %__MODULE__{
          caller_module: module(),
          caller_function: atom() | nil,
          caller_arity: non_neg_integer() | nil,
          callee_module: module(),
          callee_function: atom() | nil,
          callee_arity: non_neg_integer() | nil,
          file: String.t() | nil,
          line: pos_integer() | nil,
          kind: atom()
        }
end
