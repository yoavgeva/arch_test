defmodule ArchTest.CompiledFixture do
  @moduledoc """
  Compiles fixture sources into BEAM files with debug info and docs, as `mix compile` would, so rules that read
  compiled code run on real modules. Each source is compiled under the file name it is given, which its violations
  report.
  """

  @doc """
  Compiles `sources`, a list of `{file, source}` pairs, into a fresh `directory` and returns the directory.
  """
  @spec compile(Path.t(), [{String.t(), String.t()}]) :: Path.t()
  def compile(directory, sources) do
    File.rm_rf!(directory)
    File.mkdir_p!(directory)
    previous = Code.compiler_options()
    # Examples define the same modules again and again, as each rule's project does.
    Code.compiler_options(debug_info: true, docs: true, ignore_module_conflict: true)

    try do
      for {file, source} <- sources, {module, binary} <- Code.compile_string(source, file) do
        File.write!(Path.join(directory, "#{module}.beam"), binary)
      end
    after
      Code.compiler_options(
        debug_info: previous.debug_info,
        docs: previous.docs,
        ignore_module_conflict: previous.ignore_module_conflict
      )
    end

    directory
  end

  @doc """
  Compiles source `files` together, as `mix compile` does, into BEAM files in `directory`. Paths are relative to the
  working directory, which their violations report relative to.
  """
  @spec compile_files(Path.t(), [Path.t()]) :: Path.t()
  def compile_files(directory, files) do
    File.rm_rf!(directory)
    File.mkdir_p!(directory)
    previous = Code.compiler_options()
    Code.compiler_options(debug_info: true, docs: true, ignore_module_conflict: true)

    try do
      {:ok, _modules, _warnings} =
        Kernel.ParallelCompiler.compile_to_path(files, directory, return_diagnostics: true)
    after
      Code.compiler_options(
        debug_info: previous.debug_info,
        docs: previous.docs,
        ignore_module_conflict: previous.ignore_module_conflict
      )
    end

    directory
  end
end
