defmodule Aecore.Peers.SyncNew do
  @moduledoc """
  This module is responsible for the Sync logic between Peers to share blocks between eachother
  """

  use GenServer

  alias Aecore.Chain.Header
  alias Aecore.Chain.Worker, as: Chain
  alias Aecore.Chain.BlockValidation
  alias Aecore.Persistence.Worker, as: Persistence

  require Logger

  @typedoc "Structure of a peer to sync with"
  @type sync_peer :: %{
          difficulty: non_neg_integer(),
          from: non_neg_integer(),
          to: non_neg_integer(),
          hash: binary(),
          peer: String.t(),
          pid: binary()
        }

  @type peer_id_map :: %{peer: String.t()}

  @typedoc "List of all the syncing peers"
  @type sync_pool :: list(sync_peer())

  @type hash_pool :: {{non_neg_integer(), non_neg_integer()}, Block.t() | peer_id_map()}

  @max_headers_per_chunk 100
  @max_diff_for_sync 50
  @max_adds 20

  defstruct difficulty: nil,
            from: nil,
            to: nil,
            hash: nil,
            peer: nil,
            pid: nil

  use ExConstructor

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{:sync_pool => [], :hash_pool => []}, name: __MODULE__)
  end

  def init(state) do
    {:ok, state}
  end

  @doc """
  Starts a synchronizing process between our node and the node of the given peer_id
  """
  @spec start_sync(String.t(), binary(), non_neg_integer()) :: :ok | {:error, String.t()}
  def start_sync(peer_id, remote_hash, remote_difficulty) do
    GenServer.cast(__MODULE__, {:start_sync, peer_id, remote_hash, remote_difficulty})
  end

  @spec fetch_mempool(String.t()) :: :ok | {:error, String.t()}
  def fetch_mempool(peer_id) do
    GenServer.cast(__MODULE__, {:fetch_mempool, peer_id})
  end

  @spec schedule_ping(String.t()) :: :ok | {:error, String.t()}
  def schedule_ping(peer_id) do
    GenServer.cast(__MODULE__, {:schedule_ping, peer_id})
  end

  @doc """
  Checks weather the sync is in progress
  """
  @spec sync_in_progress?(String.t()) :: {true | false, non_neg_integer}
  def sync_in_progress?(peer_id) do
    GenServer.call(__MODULE__, {:sync_in_progress, peer_id})
  end

  @spec new_header?(String.t(), Header.t(), non_neg_integer(), binary()) :: true | false
  def new_header?(peer_id, header, agreed_height, hash) do
    GenServer.call(__MODULE__, {:new_header, self(), peer_id, header, agreed_height, hash})
  end

  @spec fetch_next(String.t(), non_neg_integer(), binary(), any()) :: tuple()
  def fetch_next(peer_id, height_in, hash_in, result) do
    GenServer.call(__MODULE__, {:fetch_next, peer_id, height_in, hash_in, result}, 30_000)
  end

  @spec forward_block(Block.t(), String.t()) :: :ok | {:error, String.t()}
  def forward_block(block, peer_id) do
    GenServer.call(__MODULE__, {:forward_block, block, peer_id})
  end

  @spec forward_tx(SignedTx.t(), String.t()) :: :ok | {:error, String.t()}
  def forward_tx(tx, peer_id) do
    GenServer.call(__MODULE__, {:forward_tx, tx, peer_id})
  end

  @spec fetch_next(String.t(), non_neg_integer(), binary(), any()) :: tuple()
  def fetch_next(peer_id, height_in, hash_in, result) do
    GenServer.call(__MODULE__, {:fetch_next, peer_id, height_in, hash_in, result}, 30_000)
  end

  @spec update_hash_pool(list()) :: list()
  def update_hash_pool(hashes) do
    GenServer.call(__MODULE__, {:update_hash_pool, hashes})
  end

  ## INNER FUNCTIONS ##

  def handle_cast({:start_sync, peer_id, remote_hash}, _from, state) do
    case sync_in_progress?(peer_id) do
      false ->
        do_start_sync(peer_id, remote_hash)

      true ->
        Logger.info("#{__MODULE__}: sync is already in progress with #{inspect(peer_id)}")
    end

    :jobs.enqueue(:sync_jobs, {:ping, peer_id})
    {:noreply, state}
  end

  def handle_cast({:fetch_mempool, peer_id}, _, state) do
    :jobs.enqueue(:sync_jobs, {:fetch_mempool, peer_id})
    {:noreply, state}
  end

  def handle_cast({:schedule_ping, peer_id}, _, state) do
    :jobs.enqueue(:sync_jobs, {:schedule_ping, peer_id})
    {:noreply, state}
  end

  def handle_call(
        {:new_header, pid, peer_id, header, agreed_height, hash},
        _from,
        %{sync_pool: pool} = state
      ) do
    height = header.height
    difficulty = header.difficulty

    {is_new, new_pool} =
      insert_header(
        SyncNew.new(
          %{
            difficulty: difficulty,
            from: agreed_height,
            to: height,
            hash: hash,
            peer: peer_id,
            pid: pid
          },
          pool
        )
      )

    case is_new do
      true ->
        # do something with process
        :ok

      false ->
        :ok
    end

    {:no_reply, is_new, %{state | sync_pool: new_pool}}
  end

  def handle_call({:sync_in_progress, peer_id}, _from, %{sync_pool: pool} = state) do
    result =
      case Enum.find(list, false, fn peer -> Map.get(peer, :id) == peer_id end) do
        false ->
          false

        peer ->
          {true, peer}
      end

    {:no_reply, result, state}
  end

  def handle_call({:forward_block, block, peer_id}, _from, state) do
    {:no_reply, do_forward_block(block, peer_id), state}
  end

  def handle_call({:forward_tx, tx, peer_id}, _from, state) do
    {:no_reply, do_forward_tx(tx, peer_id), state}
  end

  def handle_call({:update_hash_pool, hashes}, _, state) do
    hash_pool = merge(state.hash_pool, hashes)
    Logger.debug("Hash pool now contains ~p hashes", [length(HashPool)])
      {:reply, :ok, %{state | hash_pool: hash_pool}}
  end

  def handle_call({:fetch_next, peer_id, height_in, hash_in, result}, _, state) do
    hash_pool =
      case result do
        {:ok, block} ->
          block_height = block.header.height
          block_hash = block.header.hash
          List.keyreplace(
            {block_height, block_hash},
            1,
            state.hash_pool,
            {{block_height, block_hash}, %{block: block}}
          )
        _ ->
          state.hash_pool
      end

    Logger.info("#{__MODULE__}: fetch next from Hashpool")

    case update_chain_from_pool(height_in, hash_in, hash_pool) do
      {:error, reason} ->
        Logger.info("#{__MODULE__}: Chain update failed", reason)
        {:reply, {:error, :sync_stopped}, %{state | hash_pool: hash_pool}}
      {:ok, new_height, new_hash, []} ->
        Logger.debug("Got all the blocks from Hashpool")
        case Enum.find(state.sync_pool, false, fn peer -> Map.get(peer, :id) == peer_id end) do
          false ->
            ##abort sync
            {:reply, {:error, :sync_stopped}, %{state | hash_pool: []}}
          %{to: to} = peer when to <= new_height ->
            new_sync_pool =
              Enum.reject(state.sync_pool, fn peers -> Map.get(peer, :id) == peer_id end)
            {:reply, :done, %{state | hash_pool: [], sync_pool: new_sync_pool}}
          peer ->
            {:reply, {:fill_pool, new_height, new_hash}, %{state | hash_pool: []}}
        end
      {:ok, new_height, new_hash, new_hash_pool} ->
        Logger.debug("Updated Hashpool")
        sliced_hash_pool =
        for {{height, hash}, %{peer_id: id}} <- new_hash_pool do
          {height, hash}
        end
        case sliced_hash_pool do
          [] ->
            ## We have all blocks
            {:reply, {:insert, new_height, new_hash}, %{state | hash_pool: new_hash_pool}}
          pick_from_hashes ->
            random = :rand.uniform(length(pick_from_hashes))
            {pick_height, pick_hash} = Enum.fetch(pick_from_hashes, random)
            {:reply, {:fetch, new_height, new_hash, pick_hash}, %{state | hash_pool: new_hash_pool}}
        end
    end
  end

  @spec update_chain_from_pool(non_neg_integer(), binary(), list()) :: tuple()
  defp update_chain_from_pool(agreed_height, agreed_hash, hash_pool) do
    case split_hash_pool(agreed_height + 1, agreed_hash, hash_pool, [], 0) do
      {_, _, [], rest, n_added} when rest != [] and n_added < @max_adds ->
        {:error, {:stuck_at, agreed_height + 1}}

      {new_agreed_height, new_agreed_hash, same, rest, _} ->
        {:ok, new_agreed_height, new_agreed_hash, same ++ rest}
    end
  end

  @spec split_hash_pool(non_neg_integer(), list(), any(), non_neg_integer()) :: tuple()
  defp split_hash_pool(height, prev_hash, [{{h, _}, _} | hash_pool], same, n_added)
       when h < height do
    split_hash_pool(height, prev_hash, same, n_added)
  end

  defp split_hash_pool(height, prev_hash, [{{h, hash}, map} | hash_pool], same, n_added)
       when h == height and n_added < @max_ads do
    case Map.get(map, :block) do
      nil ->
        split_hash_pool(height, prev_hash, hash_pool, [item | same], n_added)

      block ->
        hash = BlockValidation.block_header_hash(block.header)

        case block.header.prev_hash do
          prev_hash ->
            case Chain.add_block(block) do
              :ok ->
                split_hash_pool(h + 1, hash, hash_pool, [], n_added + 1)

              {:error, _} ->
                split_hash_pool(height, prev_hash, hash_pool, same, n_added)
            end

          _ ->
            split_hash_pool(height, prev_hash, hash_pool, [item | same], n_added)
        end
    end
  end

  defp split_hash_pool(height, prev_hash, hash_pool, same, n_added) do
    {height - 1, prev_hash, same, hash_pool, n_added}
  end

  # Tries to add new peer to the peer_pool.
  # If we have it already, we get either the local or the remote info
  # from the peer with highest from_height.
  # After that we merge the new_sync_peer data with the old one, updating it.
  @spec insert_header(sync_peer(), sync_pool()) :: {true | false, sync_pool()}
  defp insert_header(
         %{
           difficulty: difficulty,
           from: agreed_height,
           to: height,
           hash: hash,
           peer: peer_id,
           pid: pid
         } = new_sync,
         sync_pool
       ) do
    {new_peer?, new_pool} =
      case Enum.find(sync_pool, false, fn peer -> Map.get(peer, :id) == peer_id end) do
        false ->
          {true, [new_sync | sync_pool]}

        old_sync ->
          new_sync1 =
            case old_sync.from > from do
              true ->
                old_sync

              false ->
                new_sync
            end

          max_diff = max(difficulty, old_sync.difficulty)
          max_to = max(to, old_sync.to)
          new_sync2 = %{new_sync1 | difficulty: max_diff, to: max_to}
          new_pool = List.delete(sync_pool, old_sync)

          {false, [new_sync2 | sync_pool]}
      end

    {new_peer?, Enum.sort_by(new_pool, fn peer -> peer.difficulty end)}
  end

  ## TODO: Fix the return value
  # Here we initiate the actual sync of the Peers. We get the remote Peer values,
  # then we agree on some height, and check weather we agree on it, if not we go lower,
  # until we agree on some height. This might be even the Gensis block!
  @spec do_start_sync(String.t(), binary()) :: String.t()
  defp do_start_sync(peer_id, remote_hash) do
    case get_header_by_hash(peer_id, remote_hash) do
      {:ok, remote_header} ->
        remote_height = remote_header.height
        local_height = Chain.top_height()
        {:ok, genesis_block} = Chain.get_block_by_height(0)
        min_agreed_hash = genesis_block.header.height
        max_agreed_height = min(local_height, remote_height)

        {agreed_height, agreed_hash} =
          agree_on_height(
            peer_id,
            remote_header,
            remote_height,
            max_agreed_height,
            min_agreed_hash
          )

        case new_header?(peer_id, remote_header, agreed_height, agreed_hash) do
          false ->
            # Already syncing with this peer
            :ok

          true ->
            pool_result = fill_pool(peer_id, agreed_hash)
            fetch_more(peer_id, agreed_height, agreed_hash, pool_result)
            :ok
        end

      {:error, reason} ->
        Logger.error("#{__MODULE__}: Fetching top block from
        #{inspect(peer_id)} failed with: #{inspect(reason)} ")
    end
  end

  # With this func we try to agree on block height on which we agree and could sync.
  # In other words a common block.
  @spec agree_on_height(String.t(), binary(), non_neg_integer(), non_neg_integer(), binary())
  defp agree_on_height(_peer_id, _r_header, _r_height, l_height, agreed_hash)
       when l_height == 0 do
    {0, agreed_hash}
  end

  defp agree_on_height(peer_id, r_header, r_height, l_height, agreed_hash)
       when r_height == l_height do
    r_hash = r_header.root_hash

    case Persistence.get_block_by_hash(r_hash) do
      {:ok, _} ->
        # We agree on this block height
        {r_height, r_hash}

      _ ->
        # We are on a fork
        agree_on_height(peer_id, r_header, r_height, l_height - 1, agreed_hash)
    end
  end

  defp agree_on_height(peer_id, r_header, r_height, l_height, agreed_hash)
       when r_height != l_height do
    case get_header_by_height(peer_id, l_height) do
      {:ok, header} ->
        agree_on_height(peer_id, header, l_height, l_height, agreed_hash)

      {:error, reason} ->
        {0, agreed_hash}
    end
  end

  defp fetch_more(peer_id, _, _, :done) do
    delete_from_pool(peer_id)
  end

  defp fetch_more(peer_id, last_height, _, {:error, error}) do
    Logger.info("Abort sync at height ~p Error ~p ", [last_height, error])
    delete_from_pool(peer_id)
  end

  defp fetch_more(peer_id, last_height, header_hash, result) do
    ## We need to supply the Hash, because locally we might have a shorter,
    ## but locally more difficult fork
    case fetch_next(peer_id, last_height, header_hash, result) do
      {:fetch, new_height, new_hash, hash} ->
        case do_fetch_block(hash, peer_id) do
          {ok, _, new_block} ->
            fetch_more(peer_id, new_height, new_hash, {:ok, new_block})

          {error, _} = error ->
            fetch_more(peer_id, new_height, new_hash, error)
        end

      {:insert, new_height, new_hash} ->
        fetch_more(peer_id, new_height, new_hash, :no_result)

      {:fill_pool, agreed_height, agreed_hash} ->
        pool_result = fill_pool(peer_id, agreed_hash)
        fetch_more(peer_id, agreed_height, agreed_hash, pool_result)

      other ->
        fetch_more(peer_id, last_height, header_hash, other)
    end
  end

  def sync_worker() do
    result = :jobs.dequeue(:sync_jobs, 1)
    process_job(result)
  end

  defp process_job([{_t, job}]) do
    case job do
      {:forward, %{block: block}, peer_id} ->
        do_forward_block(block, peer_id)

      {:forward, %{tx: tx}, peer_id} ->
        do_forward_tx(tx, peer_id)

      {:start_sync, peer_id, remote_hash} ->
        case sync_in_progress?(peer_id) do
          false -> do_start_sync(peer_id, remote_hash)
          _ -> Logger.info("Sync already in progress")
        end

      {:fetch_mempool, peer_id} ->
        do_fetch_mempool(peer_id)

      {:ping, peer_id} ->
        ping_peer(peer_id)

      _other ->
        Logger.debug("Unknown job")
    end
  end

  # Send our block to the Remote Peer
  defp do_forward_block(block, peer_id) do
    height = block.header.height

    case sync_in_progress?(peer_id) do
      {true, %{to: to_height}} when to_height > height + @max_diff_for_sync ->
        Logger.debug("#{__MODULE__}: Not forwarding to #{inspect(peer_id)}, too far ahead")

      false ->
        # send_block(peer_id, block) Send block through the peer module
        :ok
    end
  end

  # Send a transaction to the Remote Peer
  defp do_forward_tx(tx, peer_id) do
    send_tx(peer_id, tx)
    Logger.debug("#{__MODULE__}: sent tx: #{inspect(tx)} to peer #{inspect(peer_id)}")
  end

  # Merges the local Hashes with the Remote Peer hashes
  # So it takes the data from where the height is higher
  defp merge([], new_hashes), do: new_hashes
  defp merge(old_hashes, []), do: old_hashes

  defp merge([{{h_1, hash_1}, _} | old_hashes], [{{h_2, hash_2}, map_2} | new_hashes])
       when h1 < h2 do
    merge(old_hashes, [{{h_2, hash_2}, map_2} | new_hashes])
  end

  defp merge([{{h_1, hash_1}, map_1} | old_hashes], [{{h_2, hash_2}, _} | new_hashes])
       when h1 > h2 do
    merge([{{h_1, hash_1}, map_1} | old_hashes], new_hashes)
  end

  defp merge(old_hashes, [{{h_2, hash_2}, map_2} | new_hashes]) do
    pick_same({{h_2, hash_2}, map_2}, old_hashes, new_hashes)
  end

  defp pick_same({{h, hash_2}, map_2}, [{{h, hash_1}, map_1} | old_hashes], new_hashes) do
    case hash_1 == hash_2 do
      true ->
        [
          {{h, hash_1}, Map.merge(map_1, map_2)}
          | pick_same({{h, hash_2}, map2}, old_hashes, new_hashes)
        ]

      false ->
        [{{h, hash_1}, map_1} | pick_same({{h, hash_2}, map_2}, old_hashes, new_hashes)]
    end
  end

  defp pick_same(_, old_hashes, new_hashes), do: merge(old_hashes, new_hashes)

  defp fill_pool(peer_id, agreed_hash) do
    ## TODO: Create this func!
    case get_n_successors(peer_id, agreed_hash, @max_headers_per_chunk) do
      {:ok, []} ->
        ## TODO: Create this func!
        delete_from_pool(peer_id)
        :done

      {:ok, chunk_hashes} ->
        hash_pool =
          for chunk <- chunk_hashes do
            {chunk, %{peer: peer_id}}
          end

        ## TODO: Create this func!
        update_hash_pool(hash_pool)
        {:filled_pool, length(chunk_hashes) - 1}

      err ->
        Logger.debug("#{__MODULE__}: Abort sync with: #{inspect(err)}")
        ## TODO: Create this func!
        delete_from_pool(peer_id)
        {:error, :sync_abort}
    end
  end

  # Check if we already have this block locally, is so
  # take it from the chain
  defp do_fetch_block(hash, peer_id) do
    case Chain.get_block(hash) do
      {:ok, block} ->
        Logger.debug("#{__MODULE__}: We already have this block!")
        {:ok, false, block}

      {:error, _} ->
        do_fetch_block_ext(hash, peer_id)
    end
  end

  # If we don't have the block locally, take it from the Remote Peer
  defp do_fetch_block_ext(hash, peer_id) do
    case Peers.get_block(peer_id, hash) do
      {:ok, block} ->
        case block.header.hash === hash do
          true ->
            Logger.debug(
              "#{__MODULE__}: Block #{inspect(block)} fetched from #{inspect(peer_id)}"
            )

            {:ok, true, block}

          false ->
            {:error, :hash_mismatch}
        end

      err ->
        Logger.debug("#{__MODULE__}: Failed to fetch the block from #{inspect(peer_id)}")
        err
    end
  end

  # Try to fetch the pool of transactions
  # from the Remote Peer we are connected to
  defp do_fetch_mempool(peer_id) do
    case Peers.get_mempool(peer_id) do
      {:ok, txs} ->
        Logger.debug("#{__MODULE__}: Mempool received from #{inspect(peer_id)}")
        Pool.add_transactions(txs)

      err ->
        Logger.debug("#{__MODULE__}: Error fetching the mempool from #{inspect(peer_id)}")
        err
    end
  end
end