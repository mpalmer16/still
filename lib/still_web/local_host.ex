defmodule StillWeb.LocalHost do
  @moduledoc "Reject requests addressed to anything other than the local machine."
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{host: host} = conn, _opts) when host in ["localhost", "127.0.0.1"], do: conn

  def call(conn, _opts) do
    conn
    |> send_resp(:forbidden, "Still is available only on localhost")
    |> halt()
  end
end
