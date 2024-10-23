defmodule Util do
  def hash_sha1(data), do: :crypto.hash(:sha, data)

  def binary_to_hex(binary), do: Base.encode16(binary, case: :lower)

  # Assuming that the length prefix must be 4 bytes.
  def prepend_length(<<data::binary>>), do: <<byte_size(data)::4*8, data::binary>>

  def split_ip_str(ip_str) do
    if !String.contains?(ip_str, ":"), do: raise("Expected ':' in string in #{ip_str}")
    String.split(ip_str, ":") |> List.to_tuple()
  end

  def connect(ip, port) do
    {:ok, socket} =
      :gen_tcp.connect(to_charlist(ip), String.to_integer(port), [:binary, active: false])

    socket
  end
end
