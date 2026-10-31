defmodule Patchbay.ArtifactStore do
  @moduledoc """
  Manager-owned storage for published artifact files.

  Agents finish by submitting results through `complete_task`. A `file` result
  names a file inside the agent's workspace or result directory, both of which
  belong to the agent user. The runtime copies the named file into
  `<state_dir>/artifacts/<agent-id>/` while the worker is still alive, so the
  copy outlives any later workspace teardown. The manager process writes the
  copy itself: directories are `0700` and files are `0600`, both manager-owned,
  regardless of the UID that produced the source file.

  Public names are `<memorable-slug>-<short-random>.<ext>`. The slug is derived
  from the result id and the source file stem, followed by a short tag for the
  active run and eight random base32 characters that keep names
  collision-resistant; the source extension is preserved. Listing and
  resolution only ever accept a single name component, so no published name can
  escape its agent directory.

  Bytes are served with a conservative content type. Extensions with a known
  safe type are inlined, everything else is `application/octet-stream` with an
  `attachment` disposition.
  """

  alias Patchbay.Transcript

  @file_mode 0o600

  @default_max_artifact_bytes 8 * 1024 * 1024
  @max_name_bytes 255
  @max_slug_bytes 32
  @random_bytes 5

  @component_regex ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @ext_regex ~r/\A[a-z0-9]{1,16}\z/

  @inline_content_types %{
    "txt" => "text/plain",
    "md" => "text/markdown",
    "markdown" => "text/markdown",
    "csv" => "text/csv",
    "json" => "application/json",
    "log" => "text/plain",
    "png" => "image/png",
    "jpg" => "image/jpeg",
    "jpeg" => "image/jpeg",
    "webp" => "image/webp",
    "pdf" => "application/pdf"
  }

  @fallback_content_type "application/octet-stream"

  @type artifact :: %{
          name: binary(),
          size: non_neg_integer(),
          content_type: binary(),
          disposition: :inline | :attachment,
          modified: non_neg_integer()
        }

  @doc "Maximum artifact size the runtime publishes by default."
  @spec default_max_artifact_bytes() :: pos_integer()
  def default_max_artifact_bytes, do: @default_max_artifact_bytes

  @doc """
  Directory holding one agent's artifacts: `<state_dir>/artifacts/<agent-id>`.
  """
  @spec dir(binary(), binary()) :: binary()
  def dir(state_dir, agent_id), do: Path.join([state_dir, "artifacts", agent_id])

  @doc """
  Builds a public name from memorable hints, an optional run id, and a source
  extension.

  Hints are slugified; a short tag derived from `run_id` and eight random
  base32 characters keep names collision-resistant across runs and agents with
  the same file names. `write/4` never overwrites an existing file.
  """
  @spec public_name(term(), term(), binary()) :: binary()
  def public_name(hints, run_id, ext) do
    [tag(hints), run_tag(run_id), random_token(@random_bytes)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("-")
    |> Kernel.<>("." <> normalize_ext(ext))
  end

  @doc """
  Normalizes an extension for a public name.

  Sources without a usable extension are published as `.bin` so every artifact
  has one and the served content type is always decided by this module, never
  by the agent.
  """
  @spec normalize_ext(term()) :: binary()
  def normalize_ext(ext) do
    ext = ext |> to_string() |> String.trim_leading(".") |> String.downcase()

    if Regex.match?(@ext_regex, ext), do: ext, else: "bin"
  end

  @doc """
  Lints a file result's source name against its declared extensions.

  A non-empty declared list restricts the source to those extensions (case
  and leading dot are ignored, blank entries are ignored so a definition with
  a trailing empty extension still lints the real names). The normalized
  source extension is returned for the public name.
  """
  @spec lint_source(binary(), [binary()]) ::
          {:ok, binary()} | {:error, {:extension_not_allowed, binary()}}
  def lint_source(name, declared) do
    source_ext =
      case Path.extname(name) do
        "." <> ext -> String.downcase(ext)
        "" -> nil
      end

    declared =
      declared
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim_leading(&1, "."))
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    extensionless? = "" in declared
    named = Enum.reject(declared, &(&1 == ""))

    cond do
      named == [] and not extensionless? ->
        {:ok, normalize_ext(source_ext || "")}

      is_nil(source_ext) ->
        if extensionless?, do: {:ok, "bin"}, else: {:error, {:extension_not_allowed, "bin"}}

      source_ext in named ->
        {:ok, source_ext}

      true ->
        {:error, {:extension_not_allowed, source_ext}}
    end
  end

  @doc """
  Publishes `bytes` as `name` for `agent_id`.

  The agent directory is created with mode `0700` and the file with mode
  `0600`. `name` must be a single confined path component; an existing name is
  never overwritten.
  """
  @spec write(binary(), binary(), binary(), binary()) ::
          {:ok, %{name: binary(), path: binary(), size: non_neg_integer()}} | {:error, term()}
  def write(state_dir, agent_id, name, bytes) when is_binary(bytes) do
    with :ok <- validate_agent_id(agent_id),
         :ok <- validate_name(name),
         :ok <- ensure_size(bytes),
         :ok <- Transcript.ensure_dir(dir(state_dir, agent_id)),
         name_path = Path.join(dir(state_dir, agent_id), name),
         {:ok, written} <- exclusive_write(name_path, bytes) do
      {:ok, written}
    end
  end

  @doc """
  Lists one agent's artifacts, newest first.

  Only regular files directly inside the agent's artifact directory are
  returned; anything else, including names that fail validation, yields an
  empty list.
  """
  @spec list(binary(), binary()) :: {:ok, [artifact()]}
  def list(state_dir, agent_id) do
    with :ok <- validate_agent_id(agent_id) do
      directory = dir(state_dir, agent_id)

      entries =
        directory
        |> Path.join("*")
        |> Path.wildcard()
        |> Enum.reject(&File.dir?/1)
        |> Enum.flat_map(fn path ->
          case entry(path) do
            {:ok, entry_map} -> [entry_map]
            :error -> []
          end
        end)
        |> Enum.sort(fn a, b ->
          a.modified > b.modified or (a.modified == b.modified and a.name <= b.name)
        end)

      {:ok, entries}
    end
  end

  @doc """
  Resolves one published name to its path and serving metadata.

  `filename` must be a single path component naming a regular file directly
  inside the agent's artifact directory; anything else is refused without
  following symlinks.
  """
  @spec resolve(binary(), binary(), binary()) :: {:ok, artifact() | map()} | {:error, term()}
  def resolve(state_dir, agent_id, filename) do
    with :ok <- validate_agent_id(agent_id),
         :ok <- validate_name(filename),
         path = Path.expand(Path.join(dir(state_dir, agent_id), filename)),
         true <- Path.dirname(path) == Path.expand(dir(state_dir, agent_id)),
         {:ok, entry} <- entry(path) do
      {:ok, Map.put(entry, :path, path)}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :not_found}
    end
  end

  @doc """
  Reads one published artifact's bytes.

  Used by tests and manager-side consumers; the HTTP route streams from disk
  instead.
  """
  @spec read(binary(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def read(state_dir, agent_id, filename) do
    with {:ok, %{path: path}} <- resolve(state_dir, agent_id, filename) do
      File.read(path)
    end
  end

  @spec serving(binary()) :: %{content_type: binary(), disposition: :inline | :attachment}
  def serving(name_or_ext) do
    ext =
      case Path.extname(name_or_ext) do
        "." <> ext -> ext
        "" -> name_or_ext
      end

    case Map.fetch(@inline_content_types, normalize_ext(ext)) do
      {:ok, content_type} -> %{content_type: content_type, disposition: :inline}
      :error -> %{content_type: @fallback_content_type, disposition: :attachment}
    end
  end

  defp entry(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        {modified, _} = mtime
        name = Path.basename(path)
        metadata = serving(name)

        {:ok,
         %{
           name: name,
           size: size,
           content_type: metadata.content_type,
           disposition: metadata.disposition,
           modified: modified
         }}

      _other ->
        :error
    end
  end

  defp exclusive_write(path, bytes) do
    with :ok <- Transcript.ensure_file(path),
         {:ok, io} <- File.open(path, [:write, :exclusive, :binary]) do
      written = with :ok <- IO.binwrite(io, bytes), do: File.chmod(path, @file_mode)

      File.close(io)

      case written do
        :ok ->
          {:ok, %{name: Path.basename(path), path: path, size: byte_size(bytes)}}

        {:error, reason} ->
          _ = File.rm(path)
          {:error, {:artifact_write_failed, reason}}
      end
    else
      {:error, :eexist} -> {:error, :name_taken}
      {:error, reason} -> {:error, {:artifact_write_failed, reason}}
    end
  end

  defp ensure_size(bytes) do
    if byte_size(bytes) <= @default_max_artifact_bytes,
      do: :ok,
      else: {:error, :artifact_too_large}
  end

  defp validate_agent_id(agent_id) do
    if component?(agent_id), do: :ok, else: {:error, :invalid_agent_id}
  end

  defp validate_name(name) do
    if is_binary(name) and byte_size(name) <= @max_name_bytes and component?(name),
      do: :ok,
      else: {:error, :invalid_name}
  end

  defp component?(value) do
    is_binary(value) and value != "" and value != "." and value != ".." and
      not forbidden_component?(value) and
      Regex.match?(@component_regex, value)
  end

  defp forbidden_component?(value), do: String.contains?(value, ["\\", "/", <<0>>])

  defp tag(hints) do
    hints
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.flat_map(&String.split(&1, ~r/[^A-Za-z0-9]+/))
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("-")
    |> String.slice(0, @max_slug_bytes)
    |> String.trim_trailing("-")
    |> case do
      "" -> "artifact"
      slug -> slug
    end
  end

  defp run_tag(nil), do: nil

  defp run_tag(run_id) do
    <<_::binary-size(14), tag::binary>> = :crypto.hash(:md5, to_string(run_id))
    Base.encode32(tag, padding: false, case: :lower)
  end

  defp random_token(bytes) when is_integer(bytes) and bytes > 0 do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(padding: false, case: :lower)
  end
end
