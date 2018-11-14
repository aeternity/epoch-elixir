defmodule Aecore.Contract.ContractConstants do
  @moduledoc """
    Module for constants/macros for contract related operations
  """

  # Different ABI versions, that define the interaction with contracts,
  # contract-to-contract interaction, values' binary encoding, etc.

  defmacro aevm_sophia_01 do
    quote do: 1
  end

  defmacro aevm_solidity_01 do
    quote do: 2
  end

  defmacro call_gas_price_multiplier do
    quote do: 30
  end

  defmacro create_tx_gas_price_multiplier do
    quote do: 5
  end
end
