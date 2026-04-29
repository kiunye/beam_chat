defmodule BeamChat.Payments.PaystackUserLookup do
  @moduledoc false

  alias BeamChat.Repo
  alias BeamChat.Wallet.Wallet, as: WalletSchema
  alias BeamChat.Wallet.WalletTransaction

  def user_id_from_charge_data(data) when is_map(data) do
    meta = data["metadata"] || %{}

    if is_map(meta) and meta["user_id"] not in [nil, ""] do
      meta["user_id"]
    else
      lookup_wallet_user_id(data["reference"])
    end
  end

  defp lookup_wallet_user_id(ref) when is_binary(ref) do
    case Repo.get_by(WalletTransaction, reference: ref) do
      %{wallet_id: wid} -> wallet_user_id(wid)
      _ -> nil
    end
  end

  defp lookup_wallet_user_id(_), do: nil

  defp wallet_user_id(wid) do
    case Repo.get(WalletSchema, wid) do
      %{user_id: uid} -> uid
      _ -> nil
    end
  end
end
