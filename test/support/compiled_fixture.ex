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
    Code.compiler_options(debug_info: true, docs: true)

    try do
      for {file, source} <- sources, {module, binary} <- Code.compile_string(source, file) do
        File.write!(Path.join(directory, "#{module}.beam"), binary)
      end
    after
      Code.compiler_options(debug_info: previous.debug_info, docs: previous.docs)
    end

    directory
  end
end
