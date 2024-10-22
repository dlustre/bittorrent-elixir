defmodule Bittorrent.CLI do
  @unchoke 1
  @interested 2
  @bitfield 5
  @request 6
  @piece 7
  @extension 20

  @sixteen_kiB 16 * 1024
  @extension_support <<0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00>>
  @unknown_left 999

  # @type block() :: {Integer.t(), Integer.t(), Integer.t()}

  def main(argv) do
    case argv do
      ["decode" | [encoded_str | _]] ->
        decoded_str = Bencode.decode(encoded_str)
        IO.puts(Jason.encode!(decoded_str))

      ["info" | [file_name | _]] ->
        meta = file_to_meta(file_name)
        info_hash = meta_to_info_hash(meta)

        info(meta, info_hash)

      ["peers" | [file_name | _]] ->
        file_name
        |> file_to_meta()
        |> meta_to_peers()
        |> Enum.map(&IO.puts/1)

      ["handshake", file_name, ip_and_port] ->
        meta = file_to_meta(file_name)
        info_hash = meta_to_info_hash(meta)

        {ip, port} = split_ip_str(ip_and_port)
        {:ok, socket} = connect(ip, port)

        msg =
          <<19, "BitTorrent protocol", 0::8*8, info_hash::binary, "definitely_a_peer_id">>

        handshake(socket, msg)

      ["download_piece", "-o", out_path, file_name, index_str] ->
        index = String.to_integer(index_str)

        meta = file_to_meta(file_name)
        info_hash = meta_to_info_hash(meta)
        peer_address = meta_to_peers(meta) |> List.first()

        info(meta, info_hash)

        IO.puts("using peer address: " <> peer_address)

        {ip, port} = split_ip_str(peer_address)
        {:ok, socket} = connect(ip, port)

        msg =
          <<19, "BitTorrent protocol", 0::8*8, info_hash::binary, "definitely_a_peer_id">>

        handshake(socket, msg)

        receive_msg(socket, @bitfield)
        IO.puts("Received bitfield message.")

        :gen_tcp.send(socket, <<1::4*8, @interested>>)
        IO.puts("Sent 'interested' message.")

        IO.puts("Awaiting unchoke message...")
        receive_msg(socket, @unchoke)
        IO.puts("Received unchoke message.")

        piece_length =
          piece_lengths(meta["info"]["length"], meta["info"]["piece length"], [])
          |> IO.inspect(label: "Piece lengths")
          |> Enum.at(index)
          |> IO.inspect(label: "piece #{index} length")

        piece_data = fetch_piece(socket, index, piece_length)

        IO.inspect(byte_size(piece_data), label: "combined piece size")

        IO.inspect(hash_sha1(piece_data) |> binary_to_hex(), label: "resulting hash")

        IO.inspect(pieces_to_hashes(meta["info"]["pieces"], []) |> Enum.at(index),
          label: "expected hash"
        )

        check_hash(
          hash_sha1(piece_data) |> binary_to_hex(),
          pieces_to_hashes(meta["info"]["pieces"], []) |> Enum.at(index)
        )

        :ok = File.write!(out_path, piece_data, [])

      ["download", "-o", out_path, file_name] ->
        meta = file_to_meta(file_name)
        info_hash = meta_to_info_hash(meta)
        peer_addresses = meta_to_peers(meta) |> Enum.map(&split_ip_str/1)

        piece_lengths = piece_lengths(meta["info"]["length"], meta["info"]["piece length"], [])
        task_assignments = load_balancer(:round_robin, piece_lengths, peer_addresses)

        info(meta, info_hash)

        msg =
          <<19, "BitTorrent protocol", 0::8*8, info_hash::binary, "definitely_a_peer_id">>

        start = :erlang.monotonic_time(:second)

        file_data =
          task_assignments
          |> Enum.with_index()
          |> IO.inspect(label: "Piece assignments")
          |> Task.async_stream(
            fn {{piece_length, {ip, port}}, index} ->
              {:ok, socket} = connect(ip, port)
              handshake(socket, msg)
              receive_msg(socket, @bitfield)
              :gen_tcp.send(socket, <<1::4*8, @interested>>)
              receive_msg(socket, @unchoke)

              piece_data = fetch_piece(socket, index, piece_length)

              check_hash(
                hash_sha1(piece_data) |> binary_to_hex(),
                pieces_to_hashes(meta["info"]["pieces"], []) |> Enum.at(index)
              )

              piece_data
            end,
            ordered: true,
            max_concurrency: length(peer_addresses)
          )
          |> Enum.to_list()
          |> Enum.map(fn {:ok, piece_data} -> piece_data end)
          |> IO.iodata_to_binary()

        IO.inspect(byte_size(file_data),
          label: "Resulting file size (Expected: #{meta["info"]["length"]})"
        )

        {:ok, file} = File.open(out_path, [:write])
        :ok = IO.binwrite(file, file_data)
        File.close(file)

        elapsed_seconds = :erlang.monotonic_time(:second) - start

        IO.puts("Elapsed time: #{elapsed_seconds} seconds")

      ["magnet_parse" | [link | _]] ->
        "magnet:?" <> query = link
        query_params = URI.decode_query(query)
        "urn:btih:" <> info_hash = Map.get(query_params, "xt")

        IO.puts("Tracker URL: #{Map.get(query_params, "tr")}")
        IO.puts("Info Hash: #{info_hash}")

      ["magnet_handshake" | [link | _]] ->
        "magnet:?" <> query = link
        query_params = URI.decode_query(query)
        tracker_url = Map.get(query_params, "tr")
        "urn:btih:" <> info_hash_hex = Map.get(query_params, "xt")
        info_hash = Base.decode16!(info_hash_hex, case: :lower)

        [peer | _] =
          peers(tracker_url, info_hash)
          |> IO.inspect(label: "peers discovered")

        {ip, port} = split_ip_str(peer)
        {:ok, socket} = connect(ip, port)

        msg =
          <<19, "BitTorrent protocol", @extension_support, info_hash::binary,
            "definitely_a_peer_id">>

        reserved = handshake(socket, msg)
        receive_msg(socket, @bitfield)

        case reserved do
          <<_::5*8, 0x10, _::2*8>> ->
            extension_handshake(socket)

          _ ->
            nil
        end

      ["magnet_info" | [link | _]] ->
        "magnet:?" <> query = link
        query_params = URI.decode_query(query)
        tracker_url = Map.get(query_params, "tr")
        "urn:btih:" <> info_hash_hex = Map.get(query_params, "xt")
        info_hash = Base.decode16!(info_hash_hex, case: :lower)

        [peer | _] =
          peers(tracker_url, info_hash)
          |> IO.inspect(label: "peers discovered")

        {ip, port} = split_ip_str(peer)
        {:ok, socket} = connect(ip, port)

        msg =
          <<19, "BitTorrent protocol", @extension_support, info_hash::binary,
            "definitely_a_peer_id">>

        reserved = handshake(socket, msg)
        receive_msg(socket, @bitfield)

        case reserved do
          <<_::5*8, 0x10, _::2*8>> ->
            peer_extension_id = extension_handshake(socket)

            bencoded_dict = %{"msg_type" => 0, "piece" => 0} |> Bencode.encode()

            request_payload = <<peer_extension_id, bencoded_dict::binary>>

            request_msg_length = 1 + byte_size(request_payload)
            request_msg = <<request_msg_length::4*8, @extension, request_payload::binary>>

            :ok = :gen_tcp.send(socket, request_msg)

          _ ->
            nil
        end

      [command | _] ->
        IO.puts("Unknown command: #{command}")
        System.halt(1)

      [] ->
        IO.puts("Usage: your_bittorrent.sh <command> <args>")
        System.halt(1)
    end
  end

  defp extension_handshake(socket) do
    bencoded_dict = %{"m" => %{"ut_metadata" => 1}} |> Bencode.encode()

    payload =
      <<0, bencoded_dict::binary>>

    msg_length = 1 + byte_size(payload)
    extension_msg = <<msg_length::4*8, @extension, payload::binary>>

    :ok = :gen_tcp.send(socket, extension_msg)

    <<0, received_dict::binary>> =
      receive_msg(socket, @extension) |> IO.inspect(label: "extension payload received")

    decoded_dict = Bencode.decode(received_dict)

    peer_extension_id = Map.get(decoded_dict, "m") |> Map.get("ut_metadata")
    IO.puts("Peer Metadata Extension ID: #{peer_extension_id}")
    peer_extension_id
  end

  defp load_balancer(:round_robin, tasks, workers), do: Enum.zip(tasks, Stream.cycle(workers))

  defp start_worker_pool(socket) do
    {:ok, pool} =
      :poolboy.start_link(
        [worker_module: Bittorrent.CLI.BlockWorker, size: 5, max_overflow: 0],
        socket
      )

    pool
  end

  defmodule BlockWorker do
    use GenServer

    def start_link(init_arg), do: GenServer.start_link(__MODULE__, init_arg)

    def init(socket), do: {:ok, socket}

    def handle_call({:download_block, block}, _from, socket) do
      IO.puts("process #{inspect(self())} downloading block")
      result = Bittorrent.CLI.fetch_block(socket, block)
      {:reply, result, socket}
    end
  end

  defp check_hash(actual, expected),
    do: if(actual != expected, do: raise("Hash doesn't match."), else: :ok)

  defp fetch_piece(socket, index, piece_length) do
    pool = start_worker_pool(socket)

    piece_to_blocks(index, piece_length, 0, [])
    # |> IO.inspect(label: "blocks")
    |> Enum.map(fn block ->
      :poolboy.transaction(
        pool,
        &GenServer.call(&1, {:download_block, block})
      )
    end)
    # |> IO.inspect(label: "block data received")
    |> Enum.map(fn {_index, _begin, _length, block} -> block end)
    |> IO.iodata_to_binary()
  end

  defp info(meta, info_hash) do
    IO.puts("Tracker URL: #{meta["announce"]}")
    IO.puts("Length: #{meta["info"]["length"]}")
    IO.puts("Info Hash: #{info_hash |> binary_to_hex()}")
    IO.puts("Piece Length: #{meta["info"]["piece length"]}")
    IO.puts("Piece Hashes:")

    pieces_to_hashes(meta["info"]["pieces"], [])
    |> Enum.map(&IO.puts/1)
  end

  # @spec fetch_block(:gen_tcp.socket(), block()) :: {}
  def fetch_block(socket, {index, begin, length}) do
    msg_length = 1 + 4 + 4 + 4

    :ok =
      :gen_tcp.send(socket, <<msg_length::4*8, @request, index::4*8, begin::4*8, length::4*8>>)

    <<^index::4*8, ^begin::4*8, block_data::size(length)-unit(8)-binary>> =
      receive_msg(socket, @piece)

    IO.inspect(byte_size(block_data), label: "Block size")
    {index, begin, length, block_data}
  end

  defp receive_msg(socket, msg_id) do
    {:ok, <<msg_length::4*8, ^msg_id>>} =
      :gen_tcp.recv(socket, 5)

    payload_length = msg_length - 1
    # IO.inspect(payload_length, label: "payload_length")

    case payload_length do
      0 ->
        nil

      length ->
        {:ok, <<payload::size(length)-unit(8)-binary>>} =
          :gen_tcp.recv(socket, length)

        payload
        # |> IO.inspect(label: "Payload received")
    end
  end

  defp piece_lengths(file_length, piece_length, acc) when file_length <= piece_length,
    do: [file_length | acc] |> Enum.reverse()

  defp piece_lengths(file_length, piece_length, acc),
    do: piece_lengths(file_length - piece_length, piece_length, [piece_length | acc])

  defp piece_to_blocks(index, piece_length, begin, acc) when piece_length <= @sixteen_kiB,
    do: [{index, begin * @sixteen_kiB, piece_length} | acc] |> Enum.reverse()

  defp piece_to_blocks(index, piece_length, begin, acc),
    do:
      piece_to_blocks(index, piece_length - @sixteen_kiB, begin + 1, [
        {index, begin * @sixteen_kiB, @sixteen_kiB} | acc
      ])

  defp peers(tracker_url, info_hash),
    do:
      (Req.get!(tracker_url,
         params: [
           info_hash: info_hash,
           peer_id: "definitely_a_peer_id",
           port: 6881,
           uploaded: 0,
           downloaded: 0,
           left: @unknown_left,
           compact: 1
         ]
       ).body
       |> Bencode.decode())["peers"]
      |> parse_peers([])

  defp meta_to_peers(meta),
    do:
      (Req.get!(meta["announce"],
         params: [
           info_hash: meta_to_info_hash(meta),
           peer_id: "definitely_a_peer_id",
           port: 6881,
           uploaded: 0,
           downloaded: 0,
           left: meta["info"]["length"],
           compact: 1
         ]
       ).body
       |> Bencode.decode())["peers"]
      |> parse_peers([])

  defp meta_to_info_hash(meta),
    do:
      meta["info"]
      |> Bencode.encode()
      |> hash_sha1()

  defp connect(ip, port),
    do:
      :gen_tcp.connect(to_charlist(ip), String.to_integer(port), [
        :binary,
        active: false
      ])

  defp handshake(socket, msg) do
    :ok = :gen_tcp.send(socket, msg)

    {:ok,
     <<19, "BitTorrent protocol", reserved::8*8-binary, _peer_info_hash::20*8,
       peer_id::20*8-binary>>} =
      :gen_tcp.recv(socket, 68)

    IO.puts("Peer ID: #{peer_id |> binary_to_hex()}")

    reserved
  end

  defp parse_peers(<<>>, acc), do: acc

  defp parse_peers(<<a::8, b::8, c::8, d::8, port::16, rest::binary>>, acc),
    do:
      parse_peers(
        rest,
        [([a, b, c, d] |> Enum.join(".")) <> ":#{port}" | acc]
      )

  defp split_ip_str(ip_str) do
    if !String.contains?(ip_str, ":"),
      do: raise("Expected ':' in string in #{ip_str}")

    [ip, port] = String.split(ip_str, ":")
    {ip, port}
  end

  defp file_to_meta(path), do: File.read!(path) |> Bencode.decode()
  defp hash_sha1(data), do: :crypto.hash(:sha, data)
  defp binary_to_hex(binary), do: Base.encode16(binary, case: :lower)

  defp pieces_to_hashes(<<>>, acc), do: acc |> Enum.reverse()

  defp pieces_to_hashes(<<piece::20*8-binary, rest::binary>>, acc),
    do: pieces_to_hashes(rest, [binary_to_hex(piece) | acc])
end
