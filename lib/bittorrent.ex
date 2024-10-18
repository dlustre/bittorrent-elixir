defmodule Bittorrent.CLI do
  def main(argv) do
    case argv do
      ["decode" | [encoded_str | _]] ->
        decoded_str = Bencode.decode(encoded_str)
        IO.puts(Jason.encode!(decoded_str))

      [command | _] ->
        IO.puts("Unknown command: #{command}")
        System.halt(1)

      [] ->
        IO.puts("Usage: your_bittorrent.sh <command> <args>")
        System.halt(1)
    end
  end
end

defmodule Bencode do
  def decode(encoded_value) when is_binary(encoded_value) do
    binary_data = :binary.bin_to_list(encoded_value)

    {_, result} = parse(binary_data)
    result
  end

  def decode(_), do: "Invalid encoded value: not binary"

  def parse([?l | _] = list), do: parse_list(list)
  def parse([?i | _] = int), do: parse_int(int)
  def parse(string), do: parse_string(string, [])

  def parse_string([?: | rest], acc),
    do: parse_string_value(rest, acc |> Enum.reverse() |> List.to_integer(), [])

  def parse_string([character | rest], acc), do: parse_string(rest, [character | acc])

  def parse_string_value(content, 0, acc),
    do: {content, acc |> Enum.reverse() |> List.to_string()}

  def parse_string_value([character | rest], length, acc),
    do: parse_string_value(rest, length - 1, [character | acc])

  # def parse_string(string) do
  #   case Enum.find_index(string, fn char -> char == ?: end) do
  #     nil ->
  #       IO.puts("The ':' character is not found in the binary")

  #     index ->
  #       rest = Enum.slice(string, (index + 1)..-1)
  #       List.to_string(rest)
  #   end
  # end

  def parse_int([?i | rest]), do: parse_int(rest, [])
  def parse_int([?e | rest], acc), do: {rest, acc |> Enum.reverse() |> List.to_integer()}
  def parse_int([character | rest], acc), do: parse_int(rest, [character | acc])

  def parse_list([?l | rest]), do: parse_list(rest, [])
  def parse_list([?e | rest], acc), do: {rest, acc |> Enum.reverse()}

  def parse_list(list, acc) do
    {rest, result} = parse(list)
    parse_list(rest, [result | acc])
  end
end
