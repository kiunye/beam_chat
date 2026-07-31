defmodule BeamChatWeb.WalletLive.Index do
  use BeamChatWeb, :live_view

  alias BeamChat.Accounts
  alias BeamChat.Accounts.User
  alias BeamChat.Payments.ObanWorkers.MpesaStkWorker
  alias BeamChat.Payments.PaystackClient
  alias BeamChat.Wallet

  # SECURITY_REVIEW.md P2 #20: same gate as Wallet.allowed_manual_credit?/1 —
  # `:dev_wallet_credit_build` is false outside dev, so a stray prod config
  # override can never surface the staff credit form.

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok, wallet} = Wallet.ensure_wallet(user.id)
    txns = Wallet.list_recent_transactions(user.id, 40)

    {:ok,
     socket
     |> assign(:page_title, "Wallet")
     |> assign(:wallet, wallet)
     |> assign(:paystack_form, to_form(%{"amount" => ""}, as: :paystack))
     |> assign(:mpesa_form, to_form(%{"amount" => "", "phone" => ""}, as: :mpesa))
     |> assign(:staff_form, to_form(%{"email" => "", "amount" => "", "note" => ""}, as: :staff))
     |> assign(:show_staff_panel, show_staff_panel?(user))
     |> stream(:transactions, txns, dom_id: &("txn-" <> &1.id))}
  end

  defp show_staff_panel?(%User{} = u) do
    User.staff?(u) or dev_wallet_credit_allowed?()
  end

  defp dev_wallet_credit_allowed? do
    Application.get_env(:beam_chat, :allow_dev_wallet_credit, false) and
      Application.get_env(:beam_chat, :dev_wallet_credit_build, false)
  end

  @impl true
  def handle_event("paystack_topup", %{"paystack" => %{"amount" => raw}}, socket) do
    {:noreply, paystack_topup(socket, raw)}
  end

  def handle_event("mpesa_topup", %{"mpesa" => %{"amount" => a, "phone" => phone}}, socket) do
    {:noreply, mpesa_topup(socket, a, phone)}
  end

  def handle_event("staff_credit", %{"staff" => fields}, socket) do
    {:noreply, staff_credit(socket, fields)}
  end

  def handle_event("refresh_wallet", _, socket) do
    {:noreply, refresh_wallet_view(socket)}
  end

  defp paystack_topup(socket, raw) do
    user = socket.assigns.current_user

    if user.email in [nil, ""] do
      socket
      |> put_flash(:error, "Add an email to your account before using Paystack.")
      |> assign(:paystack_form, to_form(%{"amount" => raw}, as: :paystack))
    else
      paystack_with_email(socket, user, raw)
    end
  end

  defp paystack_with_email(socket, user, raw) do
    case parse_amount(raw) do
      {:ok, amount} -> start_paystack_checkout(socket, user, amount, raw)
      :error -> invalid_amount_paystack(socket, raw)
    end
  end

  defp invalid_amount_paystack(socket, raw) do
    socket
    |> put_flash(:error, "Enter a valid amount.")
    |> assign(:paystack_form, to_form(%{"amount" => raw}, as: :paystack))
  end

  defp start_paystack_checkout(socket, user, amount, raw) do
    reference = Ecto.UUID.generate()
    return_url = url(~p"/payments/paystack/return")

    case Wallet.create_pending_paystack_topup(user.id, amount, reference) do
      {:ok, _} -> call_paystack_initialize(socket, user, amount, reference, return_url, raw)
      {:error, _} -> paystack_reserve_failed(socket, raw)
    end
  end

  defp paystack_reserve_failed(socket, raw) do
    socket
    |> put_flash(:error, "Could not reserve top-up.")
    |> assign(:paystack_form, to_form(%{"amount" => raw}, as: :paystack))
  end

  defp call_paystack_initialize(socket, user, amount, reference, return_url, raw) do
    case PaystackClient.initialize_transaction(
           user.email,
           amount,
           reference,
           return_url,
           %{user_id: user.id}
         ) do
      {:ok, %{"authorization_url" => auth_url}} when is_binary(auth_url) ->
        redirect(socket, external: auth_url)

      {:error, :missing_config} ->
        socket
        |> put_flash(:error, "Paystack is not configured (set PAYSTACK_SECRET_KEY).")
        |> assign(:paystack_form, to_form(%{"amount" => ""}, as: :paystack))

      {:error, _} ->
        socket
        |> put_flash(:error, "Paystack could not start checkout.")
        |> assign(:paystack_form, to_form(%{"amount" => raw}, as: :paystack))
    end
  end

  defp mpesa_topup(socket, amount_raw, phone_raw) do
    user = socket.assigns.current_user

    case parse_amount(amount_raw) do
      {:ok, amount} -> mpesa_with_amount(socket, user, amount, amount_raw, phone_raw)
      :error -> invalid_amount_mpesa(socket, amount_raw, phone_raw)
    end
  end

  defp invalid_amount_mpesa(socket, a, phone) do
    socket
    |> put_flash(:error, "Enter a valid amount.")
    |> assign(:mpesa_form, to_form(%{"amount" => a, "phone" => phone}, as: :mpesa))
  end

  defp mpesa_with_amount(socket, user, amount, amount_raw, phone_raw) do
    phone = String.trim(phone_raw)

    if phone == "" do
      socket
      |> put_flash(:error, "Enter an M-Pesa phone number.")
      |> assign(:mpesa_form, to_form(%{"amount" => amount_raw, "phone" => phone}, as: :mpesa))
    else
      enqueue_mpesa_stk(socket, user, amount, amount_raw, phone)
    end
  end

  defp enqueue_mpesa_stk(socket, user, amount, amount_raw, phone) do
    case Wallet.create_pending_mpesa_topup(user.id, amount) do
      {:ok, txn} ->
        %{user_id: user.id, txn_id: txn.id, phone: phone}
        |> MpesaStkWorker.new()
        |> Oban.insert()

        socket
        |> put_flash(:info, "STK push sent — approve on your phone.")
        |> assign(:mpesa_form, to_form(%{"amount" => "", "phone" => ""}, as: :mpesa))

      {:error, _} ->
        socket
        |> put_flash(:error, "Could not start M-Pesa top-up.")
        |> assign(:mpesa_form, to_form(%{"amount" => amount_raw, "phone" => phone}, as: :mpesa))
    end
  end

  defp staff_credit(socket, fields) do
    actor = socket.assigns.current_user
    email = String.trim(fields["email"] || "")
    note = String.trim(fields["note"] || "")

    case parse_amount(fields["amount"] || "") do
      {:ok, amount} -> staff_credit_parsed(socket, actor, email, note, amount, fields)
      :error -> staff_invalid_amount(socket, fields)
    end
  end

  defp staff_invalid_amount(socket, fields) do
    socket
    |> put_flash(:error, "Enter a valid amount.")
    |> assign(:staff_form, to_form(fields, as: :staff))
  end

  defp staff_credit_parsed(socket, actor, email, note, amount, fields) do
    if email == "" or note == "" do
      socket
      |> put_flash(:error, "Email and note are required.")
      |> assign(:staff_form, to_form(fields, as: :staff))
    else
      staff_lookup_user(socket, actor, email, note, amount, fields)
    end
  end

  defp staff_lookup_user(socket, actor, email, note, amount, fields) do
    case Accounts.get_user_by_email(email) do
      nil ->
        socket
        |> put_flash(:error, "No user with that email.")
        |> assign(:staff_form, to_form(fields, as: :staff))

      target ->
        staff_apply_manual(socket, actor, target, amount, note, fields)
    end
  end

  defp staff_apply_manual(socket, actor, target, amount, note, fields) do
    case Wallet.manual_credit(actor, target.id, amount, note) do
      {:ok, _, _} ->
        {:ok, my_wallet} = Wallet.ensure_wallet(actor.id)
        txns = Wallet.list_recent_transactions(actor.id, 40)

        socket
        |> put_flash(:info, "Credit applied to #{target.username}.")
        |> assign(:wallet, my_wallet)
        |> assign(
          :staff_form,
          to_form(%{"email" => "", "amount" => "", "note" => ""}, as: :staff)
        )
        |> stream(:transactions, txns, reset: true, dom_id: &("txn-" <> &1.id))

      {:error, :forbidden} ->
        socket
        |> put_flash(:error, "You cannot apply manual credits.")
        |> assign(:staff_form, to_form(fields, as: :staff))

      {:error, _} ->
        socket
        |> put_flash(:error, "Could not apply credit.")
        |> assign(:staff_form, to_form(fields, as: :staff))
    end
  end

  defp refresh_wallet_view(socket) do
    user = socket.assigns.current_user
    {:ok, wallet} = Wallet.ensure_wallet(user.id)
    txns = Wallet.list_recent_transactions(user.id, 40)

    socket
    |> assign(:wallet, wallet)
    |> stream(:transactions, txns, reset: true, dom_id: &("txn-" <> &1.id))
  end

  defp parse_amount(raw) when is_binary(raw) do
    raw = String.trim(raw)

    case Decimal.parse(raw) do
      {d, _} ->
        if Decimal.compare(d, Decimal.new(0)) == :gt, do: {:ok, d}, else: :error

      :error ->
        :error
    end
  end

  defp parse_amount(_), do: :error

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8" id="wallet-page">
      <div class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 class="font-display text-2xl font-semibold tracking-tight text-base-content">Wallet</h1>

          <p class="text-sm text-base-content/70 mt-1">
            Top up with Paystack or M-Pesa, then subscribe to paid rooms from your balance.
          </p>
        </div>

        <button
          type="button"
          phx-click="refresh_wallet"
          class="btn btn-outline btn-sm"
          id="wallet-refresh"
        >
          Refresh
        </button>
      </div>

      <section
        class="rounded-box border border-base-300 bg-base-200/30 p-6 shadow-sm"
        id="wallet-balance-card"
      >
        <p class="text-xs font-semibold uppercase tracking-wide text-base-content/55">Balance</p>

        <p class="font-display text-3xl font-semibold text-base-content mt-1 tabular-nums">
          {format_money(@wallet.balance)} {@wallet.currency}
        </p>
      </section>

      <div class="grid gap-6 lg:grid-cols-2">
        <section
          class="rounded-box border border-base-300 bg-base-100 p-5 space-y-4"
          id="paystack-topup"
        >
          <h2 class="font-display font-semibold text-lg">Paystack</h2>

          <.form
            for={@paystack_form}
            phx-submit="paystack_topup"
            id="paystack-topup-form"
            class="space-y-3"
          >
            <.input field={@paystack_form[:amount]} type="text" label="Amount (KES)" required />
            <button type="submit" class="btn btn-primary w-full sm:w-auto">Pay with Paystack</button>
          </.form>
        </section>

        <section class="rounded-box border border-base-300 bg-base-100 p-5 space-y-4" id="mpesa-topup">
          <h2 class="font-display font-semibold text-lg">M-Pesa</h2>

          <.form for={@mpesa_form} phx-submit="mpesa_topup" id="mpesa-topup-form" class="space-y-3">
            <.input field={@mpesa_form[:amount]} type="text" label="Amount (KES)" required />
            <.input field={@mpesa_form[:phone]} type="text" label="Phone (Safaricom)" required />
            <button type="submit" class="btn btn-primary w-full sm:w-auto">Send STK push</button>
          </.form>
        </section>
      </div>

      <section
        :if={@show_staff_panel}
        class="rounded-box border border-warning/40 bg-warning/5 p-5 space-y-3"
        id="staff-wallet-credit"
      >
        <h2 class="font-display font-semibold text-lg text-base-content">Staff / dev credit</h2>

        <p class="text-sm text-base-content/75">
          Credit another user by email (moderators, admins, or dev mode).
        </p>

        <.form for={@staff_form} phx-submit="staff_credit" id="staff-credit-form" class="space-y-3">
          <.input field={@staff_form[:email]} type="email" label="User email" required />
          <.input field={@staff_form[:amount]} type="text" label="Amount (KES)" required />
          <.input field={@staff_form[:note]} type="text" label="Note" required />
          <button type="submit" class="btn btn-warning btn-sm">Apply credit</button>
        </.form>
      </section>

      <section class="rounded-box border border-base-300 bg-base-100 p-5" id="wallet-transactions">
        <h2 class="font-display font-semibold text-lg mb-3">Recent activity</h2>

        <div id="wallet-txns" phx-update="stream" class="space-y-2">
          <p class="hidden only:block text-sm text-base-content/60 py-4">No transactions yet.</p>

          <div
            :for={{tid, txn} <- @streams.transactions}
            id={tid}
            class="flex flex-wrap justify-between gap-2 text-sm border-b border-base-300/60 pb-2"
          >
            <div>
              <span class="font-medium text-base-content">{txn.description}</span>
              <span class="block text-xs text-base-content/55">{txn.type} · {txn.status}</span>
            </div>

            <div class="text-right tabular-nums">
              <span class={if(txn.type == "credit", do: "text-success", else: "text-base-content")}>
                {if(txn.type == "credit", do: "+", else: "-")}{format_money(txn.amount)}
              </span>
              <span class="block text-xs text-base-content/50">
                {Calendar.strftime(txn.inserted_at, "%Y-%m-%d %H:%M")}
              </span>
            </div>
          </div>
        </div>
      </section>
    </div>
    """
  end

  defp format_money(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string(:normal)
end
