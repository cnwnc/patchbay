defmodule Patchbay.Worker.Wire do
  @moduledoc """
  Fixed vocabulary for terms that cross the worker protocol.

  Frames are decoded with `:erlang.binary_to_term/2` and the `:safe` option.
  Safe decoding refuses atoms that the receiving VM has not already created,
  so a message built in one OS process/VM must only contain atoms from a
  known, preloaded set. `ensure_loaded/0` is called before every safe decode;
  it loads this module and therefore inserts the whole vocabulary into the
  receiver's atom table.

  Error reasons are also mapped through `error/1`. Arbitrary terms (exception
  structs, pids, paths that happen to be atoms, and so on) never reach the
  wire; anything unrecognised becomes `:execution_failed`.
  """

  @message_atoms [
    :hello,
    :welcome,
    :rejected,
    :ready,
    :execute,
    :result,
    :ping,
    :pong,
    :shutdown,
    :start_worker,
    :start_worker_result,
    :stop_worker,
    :stop_worker_result,
    :teardown_workspace,
    :teardown_workspace_result,
    :list_workers,
    :list_workers_result,
    :worker_exited,
    :error_response,
    :event
  ]

  @key_atoms [
    :role,
    :version,
    :worker_id,
    :token,
    :call_id,
    :operation,
    :arguments,
    :variables,
    :status,
    :output,
    :exit_status,
    :duration_ms,
    :error,
    :request_id,
    :os_pid,
    :manager_host,
    :manager_port,
    :operations_path,
    :operations,
    :workspace,
    :result_dir,
    :state_dir,
    :secrets,
    :name,
    :executable,
    :argv,
    :required,
    :values,
    :description,
    :workers,
    :reason,
    :timeout,
    :type,
    :limit,
    :session_closed,
    :session_down,
    :worker_exited,
    :port_down,
    :action,
    :path
  ]

  @value_atoms [
    :worker,
    :manager,
    :ok,
    :error,
    :started,
    :stopping,
    :stopped,
    :unauthorized,
    :invalid_request,
    :execution_failed,
    :worker_connected,
    :worker_ready,
    :tool_call,
    :tool_result,
    :unknown_message,
    :invalid_request_id,
    :unknown_worker,
    :already_started,
    :worker_limit,
    :worker_spawn_failed,
    :retain,
    :export,
    :destroy,
    :workspace_not_found,
    :workspace_destroy_failed,
    :workspace_export_failed,
    :workspace_teardown_failed,
    :invalid_teardown_action,
    :non_loopback_manager,
    :invalid_manager_port,
    :invalid_worker_token,
    :invalid_worker_id,
    :invalid_operations,
    :invalid_secrets,
    :invalid_secret_name,
    :invalid_secret_value,
    :invalid_supervisor_response,
    :invalid_result,
    :not_connected,
    :busy,
    :send_failed,
    :unsupported,
    :terminated,
    :manager_down,
    :worker_closed,
    :reader_exited,
    :handshake_failed,
    :missing_hello,
    :missing_welcome,
    :invalid_hello,
    :unexpected_handshake,
    :unexpected_message,
    :normal,
    :noproc,
    :closed,
    :timeout
  ]

  @operation_atoms [
    :string,
    :number,
    :integer,
    :boolean,
    :enum,
    :path,
    :file,
    :directory
  ]

  @error_atoms [
    :unknown_operation,
    :invalid_operation,
    :invalid_operation_name,
    :invalid_arguments,
    :missing_arguments,
    :unknown_arguments,
    :invalid_argument,
    :invalid_variables,
    :workspace_required,
    :invalid_workspace,
    :invalid_operations_path,
    :invalid_result_dir,
    :invalid_state_dir,
    :agent_state_root_not_configured,
    :agent_directory_unavailable,
    :operations_write_failed,
    :path_outside_workspace,
    :file_not_found,
    :directory_not_found,
    :argv_too_large,
    :invalid_argv,
    :invalid_executable,
    :invalid_timeout,
    :invalid_output_limit,
    :invalid_working_directory,
    :output_limit,
    :timeout,
    :execution_failed,
    :workspace_unavailable,
    :result_dir_unavailable,
    :not_found,
    :not_a_regular_file,
    :path_outside_root,
    :invalid_path,
    :invalid_root,
    :invalid_offset,
    :invalid_length
  ]

  @vocabulary Enum.uniq(
                @message_atoms ++ @key_atoms ++ @value_atoms ++ @operation_atoms ++ @error_atoms
              )

  @doc "All atoms that may appear in a decoded wire term."
  @spec vocabulary() :: [atom()]
  def vocabulary, do: @vocabulary

  @doc """
  Forces this module (and thus the vocabulary) into the receiver's atom table.

  Safe decoding of a wire term is only guaranteed to succeed after this ran.
  """
  @spec ensure_loaded() :: :ok
  def ensure_loaded do
    _ = @vocabulary
    :ok
  end

  @doc "Returns true when `atom` is part of the fixed wire vocabulary."
  @spec known_atom?(term()) :: boolean()
  def known_atom?(atom) when is_atom(atom), do: atom in @vocabulary
  def known_atom?(_term), do: false

  @doc """
  Maps an internal execution error reason onto a wire-safe term.

  Every atom returned here is in `vocabulary/0`; binaries and integers are
  passed through, and unrecognised structures collapse to
  `:execution_failed`.
  """
  @spec error(term()) :: term()
  def error({:unknown_operation, name}) when is_binary(name), do: {:unknown_operation, name}

  def error({:invalid_operation_name, name}) when is_binary(name),
    do: {:invalid_operation_name, name}

  def error({:unknown_arguments, names}) when is_list(names) do
    {:unknown_arguments, Enum.filter(names, &is_binary/1)}
  end

  def error({:missing_arguments, names}) when is_list(names) do
    {:missing_arguments, Enum.filter(names, &is_binary/1)}
  end

  def error({:invalid_argument, name}) when is_binary(name), do: {:invalid_argument, name}

  def error({:path_outside_workspace, path}) when is_binary(path),
    do: {:path_outside_workspace, path}

  def error({:file_not_found, path}) when is_binary(path), do: {:file_not_found, path}

  def error({:directory_not_found, path}) when is_binary(path),
    do: {:directory_not_found, path}

  def error({:output_limit, %{limit: limit, output: output}})
      when is_integer(limit) and is_binary(output) do
    {:output_limit, %{limit: limit, output: output, os_pid: nil}}
  end

  def error({:read_failed, reason}) when is_atom(reason) or is_binary(reason),
    do: {:read_failed, to_string(reason)}

  def error(reason) when is_atom(reason) do
    if reason in @error_atoms, do: reason, else: :execution_failed
  end

  def error(_reason), do: :execution_failed
end
