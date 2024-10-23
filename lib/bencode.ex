defmodule Bencode do
  def encode(dict) when is_map(dict) do
    encoded_dict =
      dict
      |> Map.to_list()
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> encode(key) <> encode(value) end)
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

  def decode(encoded_value, :has_more) when is_binary(encoded_value), do: parse(encoded_value)

  def decode(encoded_value) when is_binary(encoded_value) do
    {result, _} = parse(encoded_value)
    result
  end

  def decode(_), do: "Invalid encoded value: not binary"

  def parse(<<?d, dict::binary>>), do: dict |> parse_dict(%{})
  def parse(<<?l, list::binary>>), do: list |> parse_list([])
  def parse(<<?i, int::binary>>), do: int |> parse_int([])

  def parse(string) when is_binary(string) do
    if :binary.match(string, <<?:>>) == :nomatch,
      do: raise("Expected ':' in string in #{string}")

    [length_str, string] = :binary.split(string, ":")
    size = String.to_integer(length_str)
    <<string::size(size)-unit(8)-binary, rest::binary>> = string

    {string, rest}
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
    {key, rest} = parse(dict)
    {value, rest} = parse(rest)

    if byte_size(rest) == 0, do: raise("Unexpected 0 bytes during dict parsing.")

    parse_dict(rest, map |> Map.put(key, value))
  end
end
