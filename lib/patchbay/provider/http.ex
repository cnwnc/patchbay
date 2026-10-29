defmodule Patchbay.Provider.HTTP do
  @moduledoc """
  `:httpc` transport for provider clients.

  `:inets` is started on demand, and `:ssl` for HTTPS URLs. OTP application
  ebin paths are restored when Mix omits them from the code path, so the
  client works without adding `:inets` or `:ssl` to `extra_applications`.
  HTTPS uses peer verification with the system CA store. The transport does
  not log or retry.

  `stream/6` uses `:httpc`'s asynchronous streaming mode. Body fragments are
  reduced as they arrive, an inactivity timeout aborts a stalled stream, and a
  reducer halt cancels the request. Messages for the request are flushed after
  cancellation so they do not remain in the caller's mailbox.
  """

  @behaviour Patchbay.Provider.Transport

  @default_timeout 60_000
  @http_apps [:inets, :public_key, :asn1, :crypto]
  @https_apps [:inets, :ssl, :public_key, :asn1, :crypto]

  @impl true
  def post(url, headers, body, opts \\ [])
      when is_binary(url) and is_binary(body) and is_list(headers) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with :ok <- ensure_started(url),
         {:ok, http_options} <- http_options(url, timeout) do
      request =
        {String.to_charlist(url), encode_headers(headers), ~c"application/json", body}

      case :httpc.request(:post, request, http_options, body_format: :binary) do
        {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
          {:ok, status, decode_headers(response_headers), response_body || ""}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def stream(url, headers, body, acc, reducer, opts \\ [])
      when is_binary(url) and is_binary(body) and is_list(headers) and is_function(reducer, 2) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    inactivity = Keyword.get(opts, :inactivity_timeout, timeout)
    cancel = Keyword.get(opts, :cancel)

    with :ok <- ensure_started(url),
         {:ok, http_options} <- http_options(url, timeout),
         :ok <- check_cancel(cancel),
         {:ok, request_id} <- start_stream(url, headers, body, http_options) do
      try do
        receive_stream(request_id, acc, reducer, inactivity, cancel)
      catch
        kind, reason ->
          cancel_stream(request_id)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    else
      {:error, reason} -> {:error, reason, acc}
      other -> {:error, other, acc}
    end
  end

  defp start_stream(url, headers, body, http_options) do
    request =
      {String.to_charlist(url), encode_headers(headers), ~c"application/json", body}

    request_options = [sync: false, stream: :self, body_format: :binary]

    case :httpc.request(:post, request, http_options, request_options) do
      {:ok, request_id} -> {:ok, request_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp receive_stream(request_id, acc, reducer, inactivity, cancel) do
    receive do
      {:http, {^request_id, :stream_start, headers}} ->
        response_headers = decode_headers(headers)

        case reduce(reducer, {:status, 200, response_headers}, acc) do
          {:cont, acc} ->
            stream_loop(request_id, acc, reducer, inactivity, cancel, response_headers)

          {:halt, acc} ->
            halt_stream(request_id, acc)
        end

      {:http, {^request_id, {{_version, status, _reason}, headers, body}}} ->
        response_headers = decode_headers(headers)

        with {:cont, acc} <- reduce(reducer, {:status, status, response_headers}, acc),
             {:cont, acc} <- reduce(reducer, {:data, body || ""}, acc) do
          {:ok, status, response_headers, acc}
        else
          {:halt, acc} -> halt_stream(request_id, acc)
        end

      {:http, {^request_id, {:error, reason}}} ->
        {:error, reason, acc}
    after
      inactivity ->
        cancel_stream(request_id)
        {:error, :timeout, acc}
    end
  end

  defp stream_loop(request_id, acc, reducer, inactivity, cancel, status_headers) do
    if canceled?(cancel) do
      cancel_stream(request_id)
      {:error, :cancelled, acc}
    else
      receive do
        {:http, {^request_id, :stream, chunk}} ->
          case reduce(reducer, {:data, IO.iodata_to_binary(chunk)}, acc) do
            {:cont, acc} ->
              stream_loop(request_id, acc, reducer, inactivity, cancel, status_headers)

            {:halt, acc} ->
              halt_stream(request_id, acc)
          end

        {:http, {^request_id, :stream_end, headers}} ->
          {:ok, 200, merge_headers(status_headers, decode_headers(headers)), acc}

        {:http, {^request_id, {:error, reason}}} ->
          {:error, reason, acc}
      after
        inactivity ->
          cancel_stream(request_id)
          {:error, :timeout, acc}
      end
    end
  end

  defp reduce(reducer, event, acc) do
    case reducer.(event, acc) do
      {:cont, acc} -> {:cont, acc}
      {:halt, acc} -> {:halt, acc}
      _other -> {:cont, acc}
    end
  end

  defp halt_stream(request_id, acc) do
    cancel_stream(request_id)
    {:halted, acc}
  end

  defp check_cancel(nil), do: :ok

  defp check_cancel(cancel) when is_function(cancel, 0) do
    if cancel.(), do: {:error, :cancelled}, else: :ok
  end

  defp check_cancel(_cancel), do: :ok

  defp canceled?(nil), do: false
  defp canceled?(cancel) when is_function(cancel, 0), do: cancel.()
  defp canceled?(_cancel), do: false

  defp cancel_stream(request_id) do
    _request = :httpc.cancel_request(request_id)
    flush_stream(request_id)
    :ok
  end

  # Stopping a stream can race with messages already handed to this process.
  # Drain briefly after cancellation so they do not survive in the mailbox.
  defp flush_stream(request_id) do
    receive do
      {:http, {^request_id, _event}} -> flush_stream(request_id)
    after
      25 -> :ok
    end
  end

  defp merge_headers(headers, extra) do
    Enum.uniq(headers ++ extra)
  end

  defp ensure_started(url) do
    apps = if https?(url), do: @https_apps, else: @http_apps

    with :ok <- ensure_otp_paths(apps),
         {:ok, _apps} <- Application.ensure_all_started(:inets) do
      ensure_ssl(url)
    end
  end

  # Mix can leave an OTP application registered as started while its ebin
  # directory is no longer on the code path. Restore the path before use so
  # httpc and ssl modules resolve in projects that do not list them in
  # extra_applications.
  defp ensure_otp_paths(apps) do
    Enum.reduce_while(apps, :ok, fn app, :ok ->
      case ensure_otp_path(app) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_otp_path(app) do
    case :code.lib_dir(app) do
      dir when is_list(dir) -> ensure_ebin(Path.join(List.to_string(dir), "ebin"))
      {:error, :bad_name} -> ensure_ebin(otp_ebin(app))
    end
  end

  defp otp_ebin(app) do
    root = :code.root_dir() |> List.to_string()
    unversioned = Path.join([root, "lib", Atom.to_string(app), "ebin"])

    versioned =
      case Application.spec(app, :vsn) do
        vsn when is_list(vsn) ->
          [Path.join([root, "lib", "#{app}-#{vsn}", "ebin"])]

        _missing ->
          []
      end

    Enum.find([unversioned | versioned], &File.dir?/1)
  end

  defp ensure_ebin(nil), do: {:error, :otp_app_path_not_found}

  defp ensure_ebin(ebin) when is_binary(ebin) do
    if ebin in Enum.map(:code.get_path(), &List.to_string/1) do
      :ok
    else
      _added = Code.prepend_path(ebin)
      :ok
    end
  end

  defp ensure_ssl(url) do
    if https?(url) do
      case Application.ensure_all_started(:ssl) do
        {:ok, _apps} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp http_options(url, timeout) do
    base = [timeout: timeout, connect_timeout: timeout]

    if https?(url) do
      try do
        {:ok, Keyword.put(base, :ssl, ssl_options())}
      rescue
        error -> {:error, {:ssl_options, Exception.message(error)}}
      end
    else
      {:ok, base}
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp https?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} -> String.downcase(scheme || "") == "https"
    end
  end

  defp encode_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp decode_headers(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end
end
