defmodule StillWeb.CalendarSchemaController do
  use StillWeb, :controller

  @schema_path Path.expand("../../../docs/calendar-import.schema.json", __DIR__)
  @external_resource @schema_path
  @schema File.read!(@schema_path)

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_download({:binary, @schema},
      filename: "still-calendar.schema.json",
      content_type: "application/schema+json"
    )
  end
end
