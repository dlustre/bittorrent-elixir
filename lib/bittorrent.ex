defmodule Bittorrent.CLI do
  # @peer_id "165.232.35.114:51437"

  def main(argv) do
    case argv do
      ["decode" | [encoded_str | _]] ->
        decoded_str = Bencode.decode(encoded_str)
        IO.puts(Jason.encode!(decoded_str))

      ["info" | [file_name | _]] ->
        metainfo = file_to_metainfo(file_name)

        info_hash =
          metainfo["info"]
          |> Bencode.encode()
          |> hash_sha1()

        <<first::20-unit(8)-binary, _::binary>> = metainfo["info"]["pieces"]

        IO.inspect(first |> binary_to_hex())
        IO.inspect(byte_size(first))

        IO.puts("Tracker URL: #{metainfo["announce"]}")
        IO.puts("Length: #{metainfo["info"]["length"]}")
        IO.puts("Info Hash: #{info_hash |> binary_to_hex()}")
        IO.puts("Piece Length: #{metainfo["info"]["piece length"]}")
        IO.puts("Piece Hashes:\n#{pieces_to_hashes(metainfo["info"]["pieces"], [])}")

      ["peers" | [file_name | _]] ->
        metainfo = file_to_metainfo(file_name)

        info_hash =
          metainfo["info"]
          |> Bencode.encode()
          |> hash_sha1()

        body =
          Req.get!(metainfo["announce"],
            params: [
              info_hash: info_hash,
              peer_id: "definitely_a_peer_id",
              port: 6881,
              uploaded: 0,
              downloaded: 0,
              left: metainfo["info"]["length"],
              compact: 1
            ]
          ).body

        decoded_body = Bencode.decode(body)

        parse_peers(decoded_body["peers"], [])
        |> Enum.map(&IO.puts/1)

      ["handshake", file_name, ip_and_port] ->
        if !String.contains?(ip_and_port, ":"),
          do: raise("Expected ':' in string in #{ip_and_port}")

        metainfo = file_to_metainfo(file_name)

        info_hash =
          metainfo["info"]
          |> Bencode.encode()
          |> hash_sha1()

        [ip, port] = String.split(ip_and_port, ":")

        {:ok, socket} =
          :gen_tcp.connect(ip |> to_charlist(), port |> String.to_integer(), [
            :binary,
            active: true
          ])

        msg =
          <<19, "BitTorrent protocol", 0::8-unit(8), info_hash::binary, "definitely_a_peer_id">>

        :ok = :gen_tcp.send(socket, msg)

        receive do
          {:tcp, ^socket, data} ->
            <<19, "BitTorrent protocol", 0::8-unit(8), _peer_info_hash::20-unit(8),
              peer_id::20-unit(8)-binary>> = data

            IO.puts("Peer ID: #{peer_id |> binary_to_hex()}")

          {:tcp_closed, ^socket} ->
            IO.puts("CLOSED")
        end

      [command | _] ->
        IO.puts("Unknown command: #{command}")
        System.halt(1)

      [] ->
        IO.puts("Usage: your_bittorrent.sh <command> <args>")
        System.halt(1)
    end
  end

  defp parse_peers(<<>>, acc), do: acc

  defp parse_peers(<<a::8, b::8, c::8, d::8, port::16, rest::binary>>, acc),
    do:
      parse_peers(
        rest,
        [([a, b, c, d] |> Enum.join(".")) <> ":#{port}" | acc]
      )

  defp file_to_metainfo(path), do: File.read!(path) |> Bencode.decode()
  defp hash_sha1(data), do: :crypto.hash(:sha, data)
  defp binary_to_hex(binary), do: Base.encode16(binary, case: :lower)
  defp pieces_to_hashes(<<>>, acc), do: acc |> Enum.reverse() |> Enum.join("\n")

  defp pieces_to_hashes(<<piece::20-unit(8)-binary, rest::binary>>, acc),
    do: pieces_to_hashes(rest, [binary_to_hex(piece) | acc])
end

defmodule Bencode do
  def encode(dict) when is_map(dict) do
    encoded_dict =
      dict
      |> Map.to_list()
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> encode(key) <> encode(value) end)
      # |> IO.inspect(label: "after map")
      |> Enum.join()

    "d" <> encoded_dict <> "e"
  end

  def encode(list) when is_list(list) do
    encoded = Enum.map(list, &encode/1) |> Enum.join()
    "l#{encoded}e"
  end

  def encode(int) when is_integer(int), do: "i#{int}e"

  def encode(string) when is_binary(string),
    do: "#{byte_size(string)}:" <> string

  def decode(encoded_value) when is_binary(encoded_value) do
    {result, _} = parse(encoded_value)
    result
  end

  def decode(_), do: "Invalid encoded value: not binary"

  def parse(<<?d, dict::binary>>),
    do:
      dict
      # |> IO.inspect(label: "dict")
      |> parse_dict(%{})

  def parse(<<?l, list::binary>>),
    do:
      list
      # |> IO.inspect(label: "list")
      |> parse_list([])

  def parse(<<?i, int::binary>>),
    do:
      int
      # |> IO.inspect(label: "int")
      |> parse_int([])

  def parse(string) when is_binary(string) do
    if :binary.match(string, <<?:>>) == :nomatch,
      do: raise("Expected ':' in string in #{string}")

    [length_str, string] = :binary.split(string, ":")
    size = String.to_integer(length_str)
    <<string::size(size)-unit(8)-binary, rest::binary>> = string

    {string, rest}
    # |> IO.inspect(label: "Parsed string and rest")
  end

  def parse_int(<<?e, rest::binary>>, acc), do: {acc |> Enum.reverse() |> List.to_integer(), rest}
  def parse_int(<<character, rest::binary>>, acc), do: parse_int(rest, [character | acc])

  def parse_list(<<?e, rest::binary>>, acc), do: {acc |> Enum.reverse(), rest}

  def parse_list(list, acc) do
    {result, rest} = parse(list)
    parse_list(rest, [result | acc])
  end

  def parse_dict(<<?e, rest::binary>>, map), do: {map, rest}

  def parse_dict(dict, map) do
    {key, rest} =
      dict
      # |> IO.inspect(label: "Parsing as key")
      |> parse()

    {value, rest} =
      rest
      # |> IO.inspect(label: "Parsing as value")
      |> parse()

    # IO.puts("Finished kv pair.")
    if byte_size(rest) == 0, do: raise("Unexpected 0 bytes during dict parsing.")

    parse_dict(rest, map |> Map.put(key, value))
  end
end
