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

    case binary_data do
      [?i | _] = int ->
        parse_int(int)

      _ ->
        case Enum.find_index(binary_data, fn char -> char == ?: end) do
          nil ->
            IO.puts("The ':' character is not found in the binary")

          index ->
            rest = Enum.slice(binary_data, (index + 1)..-1)
            List.to_string(rest)
        end
    end
  end

  def decode(_), do: "Invalid encoded value: not binary"

  def parse_int([?i | rest]), do: parse_int(rest, [])
  def parse_int([?e], acc), do: acc |> Enum.reverse() |> List.to_integer()
  def parse_int([character | rest], acc), do: parse_int(rest, [character | acc])
end
