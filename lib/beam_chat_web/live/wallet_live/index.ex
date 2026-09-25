defmodule BeamChatWeb.WalletLive.Index do
  use BeamChatWeb, :live_view

  alias BeamChat.Accounts
  alias BeamChat.Authorization
  alias BeamChat.Payments.ObanWorkers.MpesaStkWorker
  alias BeamChat.Payments.PaystackClient
  alias BeamChat.Wallet

  # The staff credit form is shown when the current scope holds the
  # `:wallet_credit` permission. SECURITY_REVIEW.md P2 #20: the same gate as
  # `Wallet.allowed_manual_credit?/1` — `:dev_wallet_credit_build` is false
  # outside dev, so a stray prod config override can never surface the staff
  # credit form.

  # Page size for the recent-activity list (SECURITY_REVIEW.md P3 #23).
  @txn_page_size 20

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok, wallet} = Wallet.ensure_wallet(user.id)
    {txns, has_more} = Wallet.list_transactions(user.id, @txn_page_size, 0)

    {:ok,
     socket
     |> assign(:page_title, "County wallet")
     |> assign(:active_tab, :wallet)
     |> assign(:topup_provider, :mpesa)
     |> assign(:wallet, wallet)
     |> assign(:txn_page, 1)
     |> assign(:txn_has_more, has_more)
     |> assign(:subscriptions, Wallet.list_active_subscriptions(user.id))
     |> assign(:paystack_form, to_form(%{"amount" => ""}, as: :paystack))
     |> assign(:mpesa_form, to_form(%{"amount" => "", "phone" => ""}, as: :mpesa))
     |> assign(:staff_form, to_form(%{"email" => "", "amount" => "", "note" => ""}, as: :staff))
     |> assign(:show_staff_panel, show_staff_panel?(socket.assigns[:current_scope]))
     |> stream(:transactions, txns, reset: true, dom_id: &("txn-" <> &1.id))}
  end

  defp show_staff_panel?(scope) do
    Authorization.can?(scope, :wallet_credit) or dev_wallet_credit_allowed?()
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

  def handle_event("topup-provider", %{"provider" => provider}, socket)
      when provider in ["mpesa", "paystack"] do
    {:noreply, assign(socket, :topup_provider, String.to_existing_atom(provider))}
  end

  # The preset amount chips set the amount on BOTH provider forms so the
  # user's chosen amount survives switching between M-Pesa and Paystack.
  def handle_event("topup-amount", %{"amount" => amount}, socket) do
    {:noreply,
     socket
     |> assign(
       :paystack_form,
       to_form(%{"amount" => amount, "phone" => ""}, as: :paystack)
     )
     |> assign(
       :mpesa_form,
       to_form(
         %{"amount" => amount, "phone" => form_value(socket.assigns.mpesa_form, :phone)},
         as: :mpesa
       )
     )}
  end

  def handle_event("load_more", _, socket) do
    user = socket.assigns.current_user
    page = socket.assigns.txn_page

    {txns, has_more} =
      Wallet.list_transactions(user.id, @txn_page_size, page * @txn_page_size)

    {:noreply,
     socket
     |> assign(:txn_page, page + 1)
     |> assign(:txn_has_more, has_more)
     |> stream(:transactions, txns)}
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
        {txns, has_more} = Wallet.list_transactions(actor.id, @txn_page_size, 0)

        socket
        |> put_flash(:info, "Credit applied to #{target.username}.")
        |> assign(:wallet, my_wallet)
        |> assign(:txn_page, 1)
        |> assign(:txn_has_more, has_more)
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
    {txns, has_more} = Wallet.list_transactions(user.id, @txn_page_size, 0)

    socket
    |> assign(:wallet, wallet)
    |> assign(:txn_page, 1)
    |> assign(:txn_has_more, has_more)
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

  defp form_value(form, key), do: (form[key] && form[key].value) || ""

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6" id="wallet-page">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="space-y-1">
          <p class="text-label-sm uppercase tracking-[0.12em] text-slate-500">
            Treasury clearance unit
          </p>

          <h1 class="font-display text-headline-lg tracking-tight text-slate-900">
            County officer & citizen wallet
          </h1>

          <p class="text-sm text-slate-600">
            Top up with M-Pesa STK push or Paystack, then subscribe to paid rooms from your balance.
          </p>
        </div>

        <button
          type="button"
          phx-click="refresh_wallet"
          class="btn btn-outline btn-sm rounded-md border-slate-300 bg-white"
          id="wallet-refresh"
        >
          Refresh
        </button>
      </div>

      <div class="grid gap-4 lg:grid-cols-3">
        <div class="rounded-lg bg-emerald-800 p-6 text-white shadow-civic-2">
          <div class="flex items-start justify-between gap-3">
            <p class="text-label-sm uppercase tracking-[0.12em] text-emerald-200/70">
              Sovereign wallet vault
            </p>
            <.icon name="hero-shield-check" class="size-5 text-emerald-300/70" />
          </div>

          <p class="text-label-md text-emerald-200/80 mt-1">Available balance</p>

          <div class="mt-2 flex items-end gap-2">
            <p class="font-display text-4xl font-bold leading-none tracking-tight tabular-nums">
              {format_money(@wallet.balance)}
            </p>

            <p class="text-sm text-emerald-200/80 mb-1">{@wallet.currency}</p>
          </div>

          <div
            :if={@subscriptions != []}
            class="mt-4 inline-flex items-center gap-2 rounded-full bg-emerald-700/70 px-3 py-1.5 text-label-sm text-emerald-100"
          >
            <span class="size-1.5 rounded-full bg-emerald-300" /> Auto-renew · Active
          </div>
        </div>

        <div class="rounded-lg border border-slate-200 bg-white p-6 shadow-civic-2">
          <p class="text-label-sm uppercase tracking-[0.12em] text-slate-500">Municipal channels</p>

          <p class="mt-2 font-display text-headline-lg text-slate-900">
            {length(@subscriptions)} gated room{if length(@subscriptions) == 1, do: "", else: "s"}
          </p>

          <p class="mt-1 text-sm text-slate-600">
            Monthly outflow:
            <span class="tnum font-semibold text-slate-900">
              {format_money(monthly_outflow(@subscriptions))} {@wallet.currency}
            </span>
          </p>

          <p :if={@subscriptions != []} class="mt-3 text-xs text-slate-500">
            Next billing:
            <span class="tnum font-medium text-slate-700">{next_billing(@subscriptions)}</span>
          </p>
        </div>

        <div class="rounded-lg border border-slate-200 bg-white p-6 shadow-civic-2">
          <p class="text-label-sm uppercase tracking-[0.12em] text-slate-500">
            Safaricom Daraja engine
          </p>

          <p class="mt-2 text-sm font-medium text-slate-900">M-Pesa rail identity</p>

          <p class="mt-1 font-mono text-code-sm text-slate-800">
            {phone_mask(assigns[:current_user].phone)}
          </p>

          <div class="mt-3 inline-flex items-center gap-2 rounded-full bg-emerald-50 border border-emerald-200 text-emerald-700 px-2.5 py-1 text-label-sm">
            {if assigns[:current_user].phone in [nil, ""], do: "Not linked", else: "Verified"}
          </div>
        </div>
      </div>

      <div class="grid gap-4 lg:grid-cols-3 items-start">
        <section
          class="rounded-lg border border-slate-200 bg-white p-5 shadow-civic-2 lg:col-span-2"
          id="fund-wallet"
        >
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h2 class="font-display text-headline-sm text-slate-900">Fund the wallet</h2>

            <div class="flex rounded-md bg-slate-100 p-0.5" role="tablist" aria-label="Payment rail">
              <button
                type="button"
                role="tab"
                aria-selected={@topup_provider == :mpesa}
                phx-click="topup-provider"
                phx-value-provider="mpesa"
                class={[
                  "rounded-md px-3 py-1.5 text-sm font-medium",
                  @topup_provider == :mpesa && "bg-white text-slate-900 shadow-sm",
                  @topup_provider != :mpesa && "text-slate-500 hover:text-slate-800"
                ]}
                id="rail-mpesa"
              >
                M-Pesa STK
              </button>
              <button
                type="button"
                role="tab"
                aria-selected={@topup_provider == :paystack}
                phx-click="topup-provider"
                phx-value-provider="paystack"
                class={[
                  "rounded-md px-3 py-1.5 text-sm font-medium",
                  @topup_provider == :paystack && "bg-white text-slate-900 shadow-sm",
                  @topup_provider != :paystack && "text-slate-500 hover:text-slate-800"
                ]}
                id="rail-paystack"
              >
                Paystack
              </button>
            </div>
          </div>

          <div class="mt-4 space-y-3">
            <p class="text-label-sm text-slate-500">Amount (KES)</p>

            <div class="flex flex-wrap gap-2" id="amount-chips">
              <button
                :for={amount <- ["500", "1,000", "2,500", "5,000"]}
                type="button"
                phx-click="topup-amount"
                phx-value-amount={amount}
                class={[
                  "rounded-md border px-3 py-2 text-sm font-semibold",
                  active_amount?(assigns, amount) && "border-emerald-600 bg-emerald-600 text-white",
                  !active_amount?(assigns, amount) &&
                    "border-slate-300 bg-white text-slate-700 hover:bg-slate-50"
                ]}
              >
                {amount}
              </button>
            </div>
          </div>

          <%= if @topup_provider == :mpesa do %>
            <.form
              for={@mpesa_form}
              id="mpesa-topup-form"
              phx-submit="mpesa_topup"
              class="mt-4 space-y-3"
            >
              <.input
                field={@mpesa_form[:amount]}
                type="text"
                label="Amount (KES)"
                placeholder="0.00"
                required
                class="tnum"
                id="mpesa-amount-input"
              />
              <.input
                field={@mpesa_form[:phone]}
                type="text"
                label="Phone (Safaricom)"
                placeholder="07XX XXX XXX"
                required
                class="tnum"
              />
              <p class="text-xs text-slate-500">
                The push lands instantly on your Safaricom line; posting settles via the webhook callback.
              </p>

              <button type="submit" class="btn btn-primary w-full rounded-md">
                Send M-Pesa STK prompt{if socket_amount(@mpesa_form) != "",
                  do: " · KES " <> socket_amount(@mpesa_form),
                  else: ""}
              </button>
            </.form>
          <% else %>
            <.form
              for={@paystack_form}
              id="paystack-topup-form"
              phx-submit="paystack_topup"
              class="mt-4 space-y-3"
            >
              <.input
                field={@paystack_form[:amount]}
                type="text"
                label="Amount (KES)"
                placeholder="0.00"
                required
                class="tnum"
                id="paystack-amount-input"
              />
              <p class="text-xs text-slate-500">
                Paystack card or bank transfer; you are redirected to the hosted checkout to finish.
              </p>

              <button type="submit" class="btn btn-secondary w-full rounded-md">
                Pay with Paystack
              </button>
            </.form>
          <% end %>
        </section>

        <section
          class="rounded-lg border border-slate-200 bg-white p-5 shadow-civic-2"
          id="gated-rooms"
        >
          <h2 class="font-display text-headline-sm text-slate-900">Active gated rooms</h2>

          <p :if={@subscriptions == []} class="mt-3 text-sm text-slate-500">
            None active — subscribe from a paid room.
          </p>

          <ul
            :for={sub <- @subscriptions}
            :if={@subscriptions != []}
            class="mt-4 space-y-3 text-sm"
            id="gated-room-rows"
          >
            <li class="rounded-md border border-slate-200 p-3">
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="font-semibold text-slate-900 truncate">{sub.room.name}</p>

                  <p class="tnum mt-0.5 text-xs text-emerald-700">
                    {format_money(sub.room.price)} {sub.room.currency} / 30d
                  </p>

                  <p class="mt-1 flex items-center gap-1.5 text-label-sm text-slate-500">
                    <span class="size-1.5 rounded-full bg-emerald-500" />
                    Active · renews in {days_left(sub.expires_at)}d
                  </p>
                </div>

                <.link
                  navigate={~p"/rooms/#{sub.room.slug}"}
                  class="btn btn-outline btn-xs rounded-md text-xs shrink-0"
                >
                  Open
                </.link>
              </div>
            </li>
          </ul>
        </section>
      </div>

      <section
        :if={@show_staff_panel}
        class="rounded-lg border border-amber-200 bg-amber-50/60 p-5 space-y-3 shadow-civic-2"
        id="staff-wallet-credit"
      >
        <h2 class="font-display text-headline-sm text-slate-900">Staff / dev credit</h2>

        <p class="text-sm text-slate-700">Credit another user by email (admins or dev mode only).</p>

        <.form for={@staff_form} phx-submit="staff_credit" id="staff-credit-form" class="space-y-3">
          <.input field={@staff_form[:email]} type="email" label="User email" required />
          <.input field={@staff_form[:amount]} type="text" label="Amount (KES)" required />
          <.input field={@staff_form[:note]} type="text" label="Note" required />
          <button type="submit" class="btn btn-warning btn-sm rounded-md">Apply credit</button>
        </.form>
      </section>

      <section
        class="rounded-lg border border-slate-200 bg-white shadow-civic-2"
        id="wallet-transactions"
      >
        <div class="flex flex-wrap items-center justify-between gap-3 border-b border-slate-200 px-5 py-4">
          <div>
            <h2 class="font-display text-headline-md text-slate-900">Wallet transaction history</h2>

            <p class="text-sm text-slate-500">Signed receipts for municipal audits.</p>
          </div>
          <label for="txn-filter" class="sr-only">Filter transactions</label>
          <input
            id="txn-filter"
            type="search"
            placeholder="Filter references…"
            autocomplete="off"
            phx-hook=".TxnFilter"
            class="w-56 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm text-slate-800"
          />
        </div>

        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr class="text-xs uppercase tracking-wide text-slate-500">
                <th class="font-semibold">Date &amp; time</th>

                <th class="font-semibold">Description</th>

                <th class="font-semibold">Provider</th>

                <th class="font-semibold">Reference</th>

                <th class="font-semibold">Type</th>

                <th class="font-semibold">Status</th>

                <th class="font-semibold text-right">Amount</th>
              </tr>
            </thead>

            <tbody id="wallet-txns" phx-update="stream">
              <tr class="hidden only:table-row">
                <td colspan="7" class="text-center text-sm text-slate-500 py-8">
                  No transactions yet.
                </td>
              </tr>

              <tr
                :for={{tid, txn} <- @streams.transactions}
                id={tid}
                data-txn-row={txn.id}
                class="hover:bg-slate-50"
              >
                <td class="whitespace-nowrap text-xs text-slate-600 tnum">
                  {Calendar.strftime(txn.inserted_at, "%Y-%m-%d %H:%M")}
                </td>

                <td class="text-sm text-slate-900 font-medium">{txn.description}</td>

                <td class="text-xs text-slate-600">{txn.provider}</td>

                <td class="font-mono text-code-sm text-slate-600">{txn.reference || "—"}</td>

                <td class="text-xs">
                  <span class={[
                    "badge badge-xs rounded-full px-2 py-0.5 font-semibold",
                    txn.type == "credit" && "bg-emerald-50 text-emerald-700 border border-emerald-200",
                    txn.type != "credit" && "bg-slate-100 text-slate-700 border border-slate-200"
                  ]}>
                    {txn_type_label(txn.type)}
                  </span>
                </td>

                <td class="text-xs">
                  <span class={[
                    "badge badge-xs rounded-full px-2 py-0.5 font-semibold",
                    txn_badge_status(txn.status)
                  ]}>
                    {txn.status}
                  </span>
                </td>

                <td class="text-right font-semibold tabular-nums text-sm">
                  {if txn.type == "credit", do: "+", else: "-"}&nbsp;{format_money(txn.amount)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@txn_has_more} class="border-t border-slate-200 px-5 py-4">
          <button
            type="button"
            phx-click="load_more"
            id="load-more-txns"
            class="btn btn-outline btn-sm w-full rounded-md border-slate-300"
          >
            Load more
          </button>
        </div>
      </section>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".TxnFilter">
      export default {
        mounted() {
          this.el.addEventListener("input", () => this.apply())
        },
        apply() {
          const q = this.el.value.trim().toLowerCase()
          document.querySelectorAll("[data-txn-row]").forEach((el) => {
            el.style.display = el.textContent.toLowerCase().includes(q) ? "" : "none"
          })
        },
      }
    </script>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp phone_mask(nil), do: "Not linked"
  defp phone_mask(""), do: "Not linked"

  defp phone_mask(phone) when is_binary(phone) do
    case String.length(phone) do
      len when len <= 4 -> phone
      len -> String.slice(phone, 0, 4) <> String.duplicate(" *", len - 4)
    end
  end

  defp monthly_outflow(subscriptions) do
    subscriptions
    |> Enum.map(fn sub ->
      Map.get(sub, :price) || Map.get(sub, :room_price) || room_price(sub)
    end)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp room_price(%{room: %{price: price}}) when is_struct(price, Decimal), do: price
  defp room_price(_), do: Decimal.new(0)

  defp next_billing(subscriptions) when is_list(subscriptions) do
    subscriptions
    |> Enum.map(&Map.get(&1, :expires_at))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ""
      dates -> dates |> Enum.min(DateTime) |> Calendar.strftime("%d %b %Y")
    end
  end

  defp days_left(nil), do: 0

  defp days_left(%DateTime{} = expires_at) do
    max(DateTime.diff(expires_at, DateTime.utc_now()), 0) |> div(86_400)
  end

  defp txn_type_label("credit"), do: "Top-up"
  defp txn_type_label("debit"), do: "Charge"
  defp txn_type_label(other), do: other

  defp txn_badge_status("completed"),
    do: "bg-emerald-50 text-emerald-700 border border-emerald-200"

  defp txn_badge_status("pending"), do: "bg-amber-50 text-amber-800 border border-amber-200"
  defp txn_badge_status("failed"), do: "bg-red-50 text-red-700 border border-red-200"
  defp txn_badge_status(_other), do: "bg-slate-100 text-slate-700 border border-slate-200"

  defp active_amount?(assigns, amount) do
    current =
      case assigns[:topup_provider] do
        :paystack -> socket_amount(assigns[:paystack_form])
        _ -> socket_amount(assigns[:mpesa_form])
      end

    current == amount
  end

  defp format_money(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string(:normal)

  defp socket_amount(form), do: (form[:amount] && form[:amount].value) || ""
end
