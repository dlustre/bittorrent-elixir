defmodule Bittorrent.CLI do
  @unchoke 1
  @interested 2
  @bitfield 5
  @request 6
  @piece 7
  @sixteen_kiB 16 * 1024
  @extension_support <<0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00>>
  @unknown_left 999

  defmodule Extension do
    @data 1
    @bitfield 5
    @extension 20
    @extension_support <<0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00>>

    def handle_msg(<<@data, data_payload::binary>>) do
      {%{
         "msg_type" => @data,
         "piece" => 0,
         "total_size" => _total_size
       }, bencoded_meta_info} = Bencode.decode(data_payload, :has_more)

      bencoded_meta_info
    end

    def handshake(socket, <<_::5*8, 0x10, _::2*8>>) do
      bencoded_dict = %{"m" => %{"ut_metadata" => 1}} |> Bencode.encode()

      payload = <<0, bencoded_dict::binary>>
      extension_msg = Util.prepend_length(<<@extension, payload::binary>>)

      :ok = :gen_tcp.send(socket, extension_msg)

      <<0, received_dict::binary>> = Bittorrent.CLI.receive_msg(socket, @extension)
      %{"m" => %{"ut_metadata" => peer_extension_id}} = Bencode.decode(received_dict)

      IO.puts("Peer Metadata Extension ID: #{peer_extension_id}")
      peer_extension_id
    end

    def handshake(_socket, _reserved_bytes), do: nil

    def parse_magnet_link("magnet:?" <> query) do
      %{
        "tr" => tracker_url,
        "xt" => "urn:btih:" <> info_hash_hex
      } = URI.decode_query(query)

      info_hash = Base.decode16!(info_hash_hex, case: :lower)

      {tracker_url, info_hash}
    end

    def request_meta(magnet_link) do
      {tracker_url, info_hash} = parse_magnet_link(magnet_link)

      {ip, port} =
        Bittorrent.CLI.peers(tracker_url, info_hash)
        |> List.first()
        |> Util.split_ip_str()

      socket = Util.connect(ip, port)

      reserved_bytes =
        Bittorrent.CLI.handshake(
          socket,
          Bittorrent.CLI.handshake_msg(info_hash, @extension_support)
        )

      Bittorrent.CLI.receive_msg(socket, @bitfield)
      peer_extension_id = handshake(socket, reserved_bytes)

      request_dict = %{"msg_type" => 0, "piece" => 0} |> Bencode.encode()
      request_payload = <<peer_extension_id, request_dict::binary>>
      request_msg = Util.prepend_length(<<@extension, request_payload::binary>>)

      :ok = :gen_tcp.send(socket, request_msg)

      bencoded_meta_info = Bittorrent.CLI.receive_msg(socket, @extension) |> handle_msg()
      meta_info = Bencode.decode(bencoded_meta_info)

      Bittorrent.CLI.info(
        %{"announce" => tracker_url, "info" => meta_info},
        Util.hash_sha1(bencoded_meta_info)
      )

      {socket, meta_info}
    end

    def peer_extension_id_to_request_msg(peer_extension_id) do
      request_dict = %{"msg_type" => 0, "piece" => 0} |> Bencode.encode()
      request_payload = <<peer_extension_id, request_dict::binary>>
      Util.prepend_length(<<@extension, request_payload::binary>>)
    end
  end

  defmodule BlockWorker do
    use GenServer

    def start_link(init_arg), do: GenServer.start_link(__MODULE__, init_arg)

    def init(socket), do: {:ok, socket}

    def handle_call({:fetch_block, block}, _from, socket) do
      IO.puts("process #{inspect(self())} downloading block")
      block_data = Bittorrent.CLI.fetch_block(socket, block)
      {:reply, block_data, socket}
    end
  end

  defp assign_tasks(:round_robin, tasks, workers), do: Enum.zip(tasks, Stream.cycle(workers))

  defp start_worker_pool(socket) do
    {:ok, pool} =
      :poolboy.start_link([worker_module: BlockWorker, size: 5, max_overflow: 0], socket)

    pool
  end

  def main(argv) do
    case argv do
      ["decode" | [encoded_str | _]] ->
        encoded_str |> Bencode.decode() |> Jason.encode!() |> IO.puts()

      ["info" | [file_name | _]] ->
        meta = file_to_meta(file_name)
        info_hash = meta_to_info_hash(meta)
        info(meta, info_hash)

      ["peers" | [file_name | _]] ->
        file_name |> file_to_meta() |> meta_to_peers() |> Enum.map(&IO.puts/1)

      ["handshake", file_name, ip_and_port] ->
        meta = file_to_meta(file_name)
        info_hash = meta_to_info_hash(meta)
        {ip, port} = Util.split_ip_str(ip_and_port)
        socket = Util.connect(ip, port)
        handshake(socket, handshake_msg(info_hash))

      ["download_piece", "-o", out_path, file_name, index_str] ->
        index = String.to_integer(index_str)
        meta = file_to_meta(file_name)
        info_hash = meta_to_info_hash(meta)
        peer_address = meta_to_peers(meta) |> List.first()
        info(meta, info_hash)

        piece_length =
          piece_lengths(meta["info"]["length"], meta["info"]["piece length"], [])
          |> Enum.at(index)

        {ip, port} = Util.split_ip_str(peer_address)
        socket = Util.connect(ip, port)
        handshake(socket, handshake_msg(info_hash))
        receive_msg(socket, @bitfield)
        init_data_transfer(socket)

        expected_hash = pieces_to_hashes(meta["info"]["pieces"], []) |> Enum.at(index)
        piece_data = piece_job(socket, index, piece_length, expected_hash)

        {:ok, file} = File.open(out_path, [:write])
        :ok = IO.binwrite(file, piece_data)
        File.close(file)

      ["download", "-o", out_path, file_name] ->
        meta = file_to_meta(file_name)
        info_hash = meta_to_info_hash(meta)
        peer_addresses = meta_to_peers(meta) |> Enum.map(&Util.split_ip_str/1)
        piece_lengths = piece_lengths(meta["info"]["length"], meta["info"]["piece length"], [])
        task_assignments = assign_tasks(:round_robin, piece_lengths, peer_addresses)

        info(meta, info_hash)

        start = :erlang.monotonic_time(:second)
        piece_hashes = pieces_to_hashes(meta["info"]["pieces"], [])

        file_data =
          task_assignments
          |> Enum.with_index()
          |> Task.async_stream(
            fn {{piece_length, {ip, port}}, index} ->
              socket = Util.connect(ip, port)
              handshake(socket, handshake_msg(info_hash))
              receive_msg(socket, @bitfield)
              init_data_transfer(socket)

              piece_job(socket, index, piece_length, Enum.at(piece_hashes, index))
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
        {tracker_url, info_hash} = Extension.parse_magnet_link(link)

        IO.puts("Tracker URL: #{tracker_url}")
        IO.puts("Info Hash: #{info_hash |> Util.binary_to_hex()}")

      ["magnet_handshake" | [magnet_link | _]] ->
        {tracker_url, info_hash} = Extension.parse_magnet_link(magnet_link)

        {ip, port} =
          peers(tracker_url, info_hash)
          |> List.first()
          |> Util.split_ip_str()

        socket = Util.connect(ip, port)
        reserved_bytes = handshake(socket, handshake_msg(info_hash, @extension_support))
        receive_msg(socket, @bitfield)
        Extension.handshake(socket, reserved_bytes)

      ["magnet_info" | [magnet_link | _]] ->
        Extension.request_meta(magnet_link)

      ["magnet_download_piece", "-o", out_path, magnet_link, index_str] ->
        index = String.to_integer(index_str)
        {socket, meta_info} = Extension.request_meta(magnet_link)

        piece_length =
          piece_lengths(meta_info["length"], meta_info["piece length"], [])
          |> Enum.at(index)

        init_data_transfer(socket)
        expected_hash = pieces_to_hashes(meta_info["pieces"], []) |> Enum.at(index)
        piece_data = piece_job(socket, index, piece_length, expected_hash)

        {:ok, file} = File.open(out_path, [:write])
        :ok = IO.binwrite(file, piece_data)
        File.close(file)

      ["magnet_download", "-o", out_path, magnet_link] ->
        {socket, meta_info} = Extension.request_meta(magnet_link)
        init_data_transfer(socket)
        piece_hashes = pieces_to_hashes(meta_info["pieces"], [])

        file_data =
          piece_lengths(meta_info["length"], meta_info["piece length"], [])
          |> Enum.with_index()
          |> Enum.map(fn {piece_length, index} ->
            piece_job(socket, index, piece_length, Enum.at(piece_hashes, index))
          end)
          |> IO.iodata_to_binary()

        {:ok, file} = File.open(out_path, [:write])
        :ok = IO.binwrite(file, file_data)
        File.close(file)

      [command | _] ->
        IO.puts("Unknown command: #{command}")
        System.halt(1)

      [] ->
        IO.puts("Usage: your_bittorrent.sh <command> <args>")
        System.halt(1)
    end
  end

  # Data transfer takes place whenever one side is interested and the other side is not choking.
  defp init_data_transfer(socket) do
    :ok = :gen_tcp.send(socket, Util.prepend_length(<<@interested>>))
    receive_msg(socket, @unchoke)
  end

  defp check_hash(actual, expected) when actual == expected, do: :ok

  defp check_hash(actual, expected) when actual != expected,
    do: raise("Hashes don't match. Actual: #{actual} Expected: #{expected}")

  def info(
        %{
          "announce" => announce,
          "info" => %{
            "length" => length,
            "piece length" => piece_length,
            "pieces" => pieces
          }
        },
        info_hash
      ) do
    IO.puts("Tracker URL: #{announce}")
    IO.puts("Length: #{length}")
    IO.puts("Info Hash: #{info_hash |> Util.binary_to_hex()}")
    IO.puts("Piece Length: #{piece_length}")
    IO.puts("Piece Hashes:")

    pieces_to_hashes(pieces, []) |> Enum.map(&IO.puts/1)
  end

  def receive_msg(socket, msg_id) do
    {:ok, <<msg_length::4*8, ^msg_id>>} =
      :gen_tcp.recv(socket, 5)

    payload_length = msg_length - 1

    case payload_length do
      0 ->
        nil

      length ->
        {:ok, <<payload::size(length)-unit(8)-binary>>} = :gen_tcp.recv(socket, length)
        payload
    end
  end

  defp fetch_piece(socket, index, piece_length) do
    pool = start_worker_pool(socket)

    piece_to_blocks(index, piece_length, 0, [])
    |> Enum.map(fn block ->
      :poolboy.transaction(pool, &GenServer.call(&1, {:fetch_block, block}))
    end)
    |> IO.iodata_to_binary()
  end

  def fetch_block(socket, {index, begin, length}) do
    :ok =
      :gen_tcp.send(
        socket,
        Util.prepend_length(<<@request, index::4*8, begin::4*8, length::4*8>>)
      )

    <<^index::4*8, ^begin::4*8, block_data::size(length)-unit(8)-binary>> =
      receive_msg(socket, @piece)

    block_data
  end

  defp piece_job(socket, index, piece_length, expected_hash) do
    piece_data = fetch_piece(socket, index, piece_length)
    :ok = check_hash(Util.hash_sha1(piece_data) |> Util.binary_to_hex(), expected_hash)
    piece_data
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

  defp pieces_to_hashes(<<>>, acc), do: acc |> Enum.reverse()

  defp pieces_to_hashes(<<piece::20*8-binary, rest::binary>>, acc),
    do: pieces_to_hashes(rest, [Util.binary_to_hex(piece) | acc])

  def handshake_msg(info_hash, reserved_bytes \\ <<0::8*8>>),
    do:
      <<19, "BitTorrent protocol", reserved_bytes::binary, info_hash::binary,
        "definitely_a_peer_id">>

  def handshake(socket, msg) do
    :ok = :gen_tcp.send(socket, msg)

    {:ok,
     <<19, "BitTorrent protocol", reserved_bytes::8*8-binary, _peer_info_hash::20*8,
       peer_id::20*8-binary>>} = :gen_tcp.recv(socket, 68)

    IO.puts("Peer ID: #{peer_id |> Util.binary_to_hex()}")

    reserved_bytes
  end

  defp file_to_meta(path), do: File.read!(path) |> Bencode.decode()

  defp meta_to_info_hash(%{"info" => info}), do: info |> Bencode.encode() |> Util.hash_sha1()

  defp meta_to_peers(meta),
    do: peers(meta["announce"], meta_to_info_hash(meta), meta["info"]["length"])

  def peers(tracker_url, info_hash, left \\ @unknown_left),
    do:
      (Req.get!(tracker_url,
         params: [
           info_hash: info_hash,
           peer_id: "definitely_a_peer_id",
           port: 6881,
           uploaded: 0,
           downloaded: 0,
           left: left,
           compact: 1
         ]
       ).body
       |> Bencode.decode())["peers"]
      |> parse_peers([])

  defp parse_peers(<<>>, acc), do: acc

  defp parse_peers(<<a::8, b::8, c::8, d::8, port::16, rest::binary>>, acc),
    do: parse_peers(rest, [([a, b, c, d] |> Enum.join(".")) <> ":#{port}" | acc])
end
