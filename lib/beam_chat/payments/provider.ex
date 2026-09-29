defmodule BeamChat.Payments.Provider do
  @moduledoc """
  Behaviour every payment provider implements (PRD §4.3).

  Three responsibilities, no more:

  - `provider_key/0` — identify itself; the key used on
    `wallet_transactions.provider` and in Settings.
  - `initiate_topup/3` — given a user and an amount, return whatever the
    provider needs to redirect or prompt the user, plus a pending wallet
    transaction.
  - `confirm_topup/1` — given a provider callback payload, verify it
    against the pending transaction it claims to complete and credit the
    wallet exactly once (idempotency lives in
    `BeamChat.Wallet.complete_provider_credit/5`).

  Adding Stripe later means writing a third implementation of these three
  callbacks; nothing in the wallet, subscription, or room-access code
  changes, and nothing in Settings changes beyond adding Stripe to the
  list of providers an admin can enable.
  """

  alias BeamChat.Accounts.User
  alias BeamChat.Wallet.WalletTransaction

  @typedoc "Provider-specific options, e.g. `phone:` for M-Pesa STK pushes."
  @type opts :: keyword()

  @callback provider_key() :: String.t()

  @callback initiate_topup(User.t(), Decimal.t(), opts()) ::
              {:ok, %{transaction: WalletTransaction.t(), redirect_url: String.t() | nil}}
              | {:error, term()}

  @callback confirm_topup(map()) :: {:ok, WalletTransaction.t()} | {:error, term()}
end
