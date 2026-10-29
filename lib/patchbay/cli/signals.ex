defmodule Patchbay.CLI.Signals do
  @moduledoc """
  Turns OS termination signals into messages for a service loop.

  OTP exposes subscribable signals through the `:erl_signal_server` event
  manager. The default handler for `:sigterm` calls `init:stop/0`, which does
  not run `terminate/2` for a GenServer started directly by the CLI. This
  handler replaces it so the service loop can stop the service before halting.

  SIGINT is owned by the emulator break handler and is not a subscribable OTP
  signal, so it cannot be trapped from Erlang code. The handler still accepts a
  `:sigint` event if one is ever delivered, and the service loop understands the
  corresponding message.
  """

  @behaviour :gen_event

  @default_handler :erl_signal_handler
  @signals [:sigterm, :sigquit, :sigusr1]

  @doc """
  Installs the handler and subscribes to termination signals.

  `target` receives `{:signal, signal}` messages.
  """
  @spec install(pid()) :: :ok
  def install(target \\ self()) when is_pid(target) do
    remove_existing()

    case :gen_event.swap_handler(
           :erl_signal_server,
           {@default_handler, []},
           {__MODULE__, target}
         ) do
      :ok -> :ok
      _other -> :gen_event.add_handler(:erl_signal_server, __MODULE__, target)
    end

    Enum.each(@signals, &subscribe/1)
    :ok
  end

  defp remove_existing do
    if __MODULE__ in :gen_event.which_handlers(:erl_signal_server) do
      :gen_event.delete_handler(:erl_signal_server, __MODULE__, [])
    end
  end

  defp subscribe(signal) do
    :os.set_signal(signal, :handle)
  rescue
    _error -> :ok
  end

  @impl true
  def init(target) when is_pid(target), do: {:ok, target}

  @impl true
  def handle_event(:sigterm, target) do
    send(target, {:signal, :sigterm})
    {:ok, target}
  end

  def handle_event(:sigint, target) do
    send(target, {:signal, :sigint})
    {:ok, target}
  end

  def handle_event(:sigquit, _target) do
    :erlang.halt()
    {:ok, nil}
  end

  def handle_event(:sigusr1, _target) do
    :erlang.halt("Received SIGUSR1")
    {:ok, nil}
  end

  def handle_event(_signal, target), do: {:ok, target}

  @impl true
  def handle_call(_request, target), do: {:ok, :ok, target}

  @impl true
  def handle_info(_message, target), do: {:ok, target}

  @impl true
  def terminate(_reason, _target), do: :ok

  @impl true
  def code_change(_old_version, target, _extra), do: {:ok, target}
end
