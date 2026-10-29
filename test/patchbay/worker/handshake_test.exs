defmodule Patchbay.Worker.HandshakeTest do
  use ExUnit.Case, async: true

  alias Patchbay.Worker
  alias Patchbay.Worker.Protocol
  alias Patchbay.Worker.Protocol.Stream

  @token "handshake-token-0123456789"

  test "messages coalesced after the welcome frame are not lost" do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    test = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, [hello], stream} = Stream.recv(socket, Stream.new(), 5_000)
        send(test, {:hello, hello})

        frame = frame({:welcome, %{version: 1}}) <> frame({:ping, %{id: "leftover"}})
        :ok = :gen_tcp.send(socket, frame)

        {:ok, [ready | rest], stream} = Stream.recv(socket, stream, 5_000)
        send(test, {:ready, ready})

        messages =
          if Enum.any?(rest, &match?({:pong, _payload}, &1)) do
            rest
          else
            {:ok, more, _stream} = Stream.recv(socket, stream, 5_000)
            rest ++ more
          end

        send(test, {:after, messages})

        receive do
          :stop -> :gen_tcp.close(socket)
        after
          5_000 -> :gen_tcp.close(socket)
        end
      end)

    {:ok, worker} =
      Worker.start_link(
        worker_id: "handshake",
        manager_port: port,
        token: @token,
        operations: [],
        connect_timeout: 2_000,
        handshake_timeout: 2_000
      )

    assert_receive {:hello, {:hello, %{role: :worker, worker_id: "handshake"}}}, 5_000
    assert_receive {:ready, {:ready, %{worker_id: "handshake"}}}, 5_000
    assert_receive {:after, [{:pong, %{id: "leftover"}}]}, 5_000

    send(server.pid, :stop)
    Task.await(server, 5_000)

    try do
      GenServer.stop(worker)
    catch
      :exit, _reason -> :ok
    end

    :gen_tcp.close(listen)
  end

  defp frame(message) do
    {:ok, frame} = Protocol.encode(message)
    frame
  end
end
