defmodule Aecore.Contract.Contract do
  @moduledoc """
  Module containing Contract interaction functionality
  """

  alias Aecore.Chain.Identifier
  alias Aecore.Chain.Worker, as: Chain
  alias Aecore.Contract.Contract
  alias Aecore.Contract.Tx.ContractCreateTx
  alias Aecore.Keys
  alias Aecore.Tx.{DataTx, SignedTx}
  alias Aecore.Tx.Pool.Worker, as: Pool
  alias Aeutil.Hash

  @version 1

  # The @store_prefix is used to name the storage tree and keep
  # all storage nodes in one subtree under the contract tree.
  @store_prefix 16

  @typedoc "Structure of the Contract Transaction type"
  @type t :: %Contract{
          id: Identifier.t(),
          owner: Identifier.t(),
          vm_version: byte(),
          code: binary(),
          store: %{binary() => binary()},
          log: binary(),
          active: boolean(),
          referers: [Identifier.t()],
          deposit: non_neg_integer()
        }

  defstruct [:id, :owner, :vm_version, :code, :store, :log, :active, :referers, :deposit]

  use Aecore.Util.Serializable

  @spec create(
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer,
          non_neg_integer(),
          non_neg_integer(),
          binary(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok | :error
  def create(code, vm_version, deposit, amount, gas, gas_price, call_data, fee, ttl \\ 0) do
    payload = %{
      code: code,
      vm_version: vm_version,
      deposit: deposit,
      amount: amount,
      gas: gas,
      gas_price: gas_price,
      call_data: call_data
    }

    {pubkey, privkey} = Keys.keypair(:sign)

    tx_data =
      DataTx.init(
        ContractCreateTx,
        payload,
        pubkey,
        fee,
        Chain.lowest_valid_nonce(),
        ttl
      )

    {:ok, tx} = SignedTx.sign_tx(tx_data, privkey)

    Pool.add_transaction(tx)
  end

  @spec new(Keys.pubkey(), non_neg_integer(), byte(), binary(), non_neg_integer()) :: Contract.t()
  def new(owner, nonce, vm_version, code, deposit) do
    contract_id = create_contract_id(owner, nonce)
    identified_contract = Identifier.create_identity(contract_id, :contract)
    identified_owner = Identifier.create_identity(owner, :account)

    %Contract{
      id: identified_contract,
      owner: identified_owner,
      vm_version: vm_version,
      code: code,
      store: %{},
      log: <<>>,
      active: true,
      referers: [],
      deposit: deposit
    }
  end

  @spec encode_to_list(Contract.t()) :: list()
  def encode_to_list(%Contract{
        owner: owner,
        vm_version: vm_version,
        code: code,
        log: log,
        active: active,
        referers: referers,
        deposit: deposit
      }) do
    encoded_active =
      case active do
        true -> 1
        false -> 0
      end

    encoded_referers =
      Enum.map(referers, fn referer ->
        Identifier.encode_to_binary(referer)
      end)

    [
      @version,
      Identifier.encode_to_binary(owner),
      :binary.encode_unsigned(vm_version),
      code,
      log,
      encoded_active,
      encoded_referers,
      :binary.encode_unsigned(deposit)
    ]
  end

  @spec decode_from_list(integer(), list()) :: {:ok, Contract.t()} | {:error, String.t()}
  def decode_from_list(@version, [
        owner,
        vm_version,
        code,
        log,
        active,
        referers,
        deposit
      ]) do
    decoded_referers =
      Enum.reduce_while(referers, [], fn referer, acc ->
        case Identifier.decode_from_binary(referer) do
          {:ok, decoded_referer} ->
            {:cont, [decoded_referer | acc]}

          _ ->
            {:halt,
             {:error,
              "#{__MODULE__}: decode_from_list: Invalid contract referer: #{inspect(referer)}"}}
        end
      end)

    with {:ok, decoded_active_value} <- decode_active(active),
         true <- is_list(decoded_referers),
         {:ok, decoded_owner_address} <- Identifier.decode_from_binary(owner) do
      {:ok,
       %Contract{
         id: %Identifier{type: :contract},
         owner: decoded_owner_address,
         vm_version: :binary.decode_unsigned(vm_version),
         code: code,
         store: %{},
         log: log,
         active: decoded_active_value,
         referers: decoded_referers,
         deposit: :binary.decode_unsigned(deposit)
       }}
    else
      {:error, _} = error -> error
    end
  end

  def decode_from_list(@version, data) do
    {:error, "#{__MODULE__}: decode_from_list: Invalid serialization: #{inspect(data)}"}
  end

  def decode_from_list(version, _) do
    {:error, "#{__MODULE__}: decode_from_list: Unknown version #{version}"}
  end

  @spec decode_active(binary() | any()) :: {:ok, boolean()} | {:error, String.t()}
  def decode_active(<<0>>) do
    {:ok, false}
  end

  def decode_active(<<1>>) do
    {:ok, true}
  end

  def decode_active(active) do
    {:error, "#{__MODULE__}: decode_from_list: Invalid contract active: #{inspect(active)}"}
  end

  @spec store_id(Contract.t()) :: binary()
  def store_id(%Contract{id: %Identifier{value: value}}), do: <<value::binary, @store_prefix>>

  @spec create_contract_id(Keys.pubkey(), non_neg_integer()) :: binary()
  def create_contract_id(owner, nonce) do
    nonce_binary = :binary.encode_unsigned(nonce)

    Hash.hash(<<owner::binary, nonce_binary::binary>>)
  end
end
