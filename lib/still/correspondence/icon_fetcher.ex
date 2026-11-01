defmodule Still.Correspondence.IconFetcher do
  @moduledoc "Small public-web raster downloads, with pinned DNS and bounded transfers."
  @limit 262_144

  def fetch(url, opts \\ []), do: fetch(url, opts, 3)

  defp fetch(url, opts, redirects) do
    resolver = Keyword.get(opts, :resolver, &resolve/1)
    request = Keyword.get(opts, :request, &request/2)

    with %URI{scheme: scheme, host: host, port: port, userinfo: nil} = uri <- URI.parse(url),
         true <- scheme in ["http", "https"] and is_binary(host) and port in [80, 443],
         false <- String.contains?(url, ["\r", "\n", <<0>>]),
         {:ok, address} <- resolver.(host),
         true <- public_address?(address),
         {:ok, response} <- request.(URI.to_string(%{uri | fragment: nil}), address) do
      cond do
        response.status == 200 ->
          raster(response.body)

        response.status in [301, 302, 303, 307, 308] and redirects > 0 ->
          case response.headers["location"] do
            location when is_binary(location) ->
              fetch(URI.merge(uri, location) |> URI.to_string(), opts, redirects - 1)

            _ ->
              {:error, :redirect}
          end

        true ->
          {:error, :unavailable}
      end
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  # Accept only globally routable addresses. Pin this exact address in curl,
  # including on each redirect; a second DNS lookup cannot reach local services.
  def public_address?({a, b, c, _}) do
    a not in [0, 10, 127] and a < 224 and
      not (a == 100 and b in 64..127) and
      not (a == 169 and b == 254) and
      not (a == 172 and b in 16..31) and
      not (a == 192 and (b in [0, 168] or (b == 88 and c == 99))) and
      not (a == 198 and (b in [18, 19] or (b == 51 and c == 100))) and
      not (a == 203 and b == 0 and c == 113)
  end

  def public_address?({a, b, _, _, _, _, _, _}),
    do: a in 0x2000..0x3FFF and not (a == 0x2001 and (b < 0x200 or b == 0xDB8))

  def public_address?(_), do: false

  defp resolve(host) do
    task =
      Task.async(fn ->
        case :inet.getaddrs(String.to_charlist(host), :inet) do
          {:ok, addresses} -> {:ok, Enum.find(addresses, &public_address?/1)}
          _ -> {:error, :dns}
        end
      end)

    case Task.yield(task, 1500) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, address}} when not is_nil(address) -> {:ok, address}
      _ -> {:error, :dns}
    end
  end

  defp request(url, address) do
    uri = URI.parse(url)
    ip = address |> :inet.ntoa() |> to_string()
    ip = if tuple_size(address) == 8, do: "[#{ip}]", else: ip

    args = [
      "--disable",
      "--silent",
      "--globoff",
      "--noproxy",
      "*",
      "--proto",
      "=http,https",
      "--connect-timeout",
      "2",
      "--max-time",
      "4",
      "--max-filesize",
      to_string(@limit),
      "--resolve",
      "#{uri.host}:#{uri.port}:#{ip}",
      "--include",
      "--url",
      url
    ]

    case System.find_executable("curl") do
      nil ->
        {:error, :unavailable}

      executable ->
        port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: args])
        collect(port, "")
    end
  end

  defp collect(port, bytes) do
    receive do
      {^port, {:data, chunk}} when byte_size(bytes) + byte_size(chunk) <= @limit + 16_384 ->
        collect(port, bytes <> chunk)

      {^port, {:data, _}} ->
        Port.close(port)
        {:error, :too_large}

      {^port, {:exit_status, 0}} ->
        parse_response(bytes)

      {^port, {:exit_status, _}} ->
        {:error, :unavailable}
    after
      5_000 ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp parse_response(bytes) do
    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [head, body] ->
        [status | headers] = String.split(head, "\r\n")

        case Regex.run(~r/^HTTP\/\S+ (\d{3})/, status) do
          [_, code] ->
            headers =
              Enum.reduce(headers, %{}, fn line, acc ->
                case String.split(line, ":", parts: 2) do
                  [key, value] -> Map.put(acc, String.downcase(key), String.trim(value))
                  _ -> acc
                end
              end)

            if code in ["100", "103"],
              do: parse_response(body),
              else: {:ok, %{status: String.to_integer(code), headers: headers, body: body}}

          _ ->
            {:error, :response}
        end

      _ ->
        {:error, :response}
    end
  end

  @doc "Allowlisted file signatures; HTML and SVG never become inline image content."
  def raster(bytes) when is_binary(bytes) and byte_size(bytes) <= @limit do
    mime =
      case bytes do
        <<137, "PNG\r\n", 26, "\n", _::binary>> ->
          "image/png"

        <<255, 216, 255, _::binary>> ->
          "image/jpeg"

        <<"GIF", version::binary-size(3), _::binary>> when version in ["87a", "89a"] ->
          "image/gif"

        <<"RIFF", _::binary-size(4), "WEBP", _::binary>> ->
          "image/webp"

        <<0, 0, 1, 0, count::little-16, _::binary>> when count in 1..256 ->
          "image/x-icon"

        _ ->
          nil
      end

    if mime, do: {:ok, %{mime: mime, bytes: bytes}}, else: {:error, :not_image}
  end

  def raster(_), do: {:error, :too_large}
end
