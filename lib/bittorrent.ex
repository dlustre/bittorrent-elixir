defmodule Bittorrent.CLI do
  def main(argv) do
    case argv do
      ["decode" | [encoded_str | _]] ->
        decoded_str = Bencode.decode(encoded_str)
        IO.puts(Jason.encode!(decoded_str))

      ["info" | [file_name | _]] ->
        content = File.read!(file_name)
        file_meta = Bencode.decode(content)

        bencoded_info = Bencode.encode(file_meta["info"])
        # IO.inspect(hash_sha1(bencoded_info))
        # Bencode.decode(bencoded_info) |> IO.inspect(label: "decoded:")
        IO.puts("Tracker URL: #{file_meta["announce"]}")
        IO.puts("Length: #{file_meta["info"]["length"]}")
        IO.puts("Info Hash: #{hash_sha1(bencoded_info)}")

      [command | _] ->
        IO.puts("Unknown command: #{command}")
        System.halt(1)

      [] ->
        IO.puts("Usage: your_bittorrent.sh <command> <args>")
        System.halt(1)
    end
  end

  defp hash_sha1(data), do: :crypto.hash(:sha, data) |> Base.encode16(case: :lower)
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
