defmodule Aehttpserver.Web.PeersController do
  use Aehttpserver.Web, :controller

  alias Aecore.Peers.Worker, as: Peers
  alias Aecore.Keys.Worker, as: Keys

  def info(conn, _params) do
    sync_port = Application.get_env(:aecore, :peers)[:sync_port]
    peer_pubkey = Keys.peer_keypair() |> elem(0) |> Keys.peer_encode()
    json(conn, %{port: sync_port, pubkey: peer_pubkey})
  end

  def peers(conn, _params) do
    peers = Peers.all_peers()
    json(conn, peers)
  end
end
