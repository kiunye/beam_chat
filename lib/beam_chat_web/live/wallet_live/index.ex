defmodule BeamChatWeb.WalletLive.Index do
  @moduledoc """
  The v2 wallet page: balance, provider-driven top-ups, active paid-room
  subscriptions, and the streamed transaction ledger.

  Payment providers are admin-configured DB rows surfaced through
  `BeamChat.Payments.list_provider_statuses/0` — the page renders one card
  per provider instead of hardcoded tabs. Available providers get a
  working top-up form (Paystack redirects to its hosted checkout; M-Pesa
  sends an STK push to the entered phone). Unavailable providers render
  as muted cards with the reason: Stripe is not implemented yet, and
  M-Pesa is additionally gated on the platform base currency being KES.
  """

  use BeamChatWeb, :live_view

  alias BeamChat.Payments
  alias BeamChat.Rooms
  alias BeamChat.Settings
  alias BeamChat.Wallet

  # Ledger page size for the streamed list + load_more pagination.
  @txn_page_size 20

  # Quick top-up chips. Values are clean integer strings so they parse
  # straight into every amount input.
  @presets ["100", "250", "500", "1000"]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    {:ok, wallet} = Wallet.ensure_wallet(user.id)
    {txns, has_more} = Wallet.list_transactions(user.id, @txn_page_size, 0)

    {:ok,
     socket
     |> assign(:page_title, "Wallet")
     |> assign(:active_nav, :wallet)
     |> assign(:base_currency, Settings.base_currency())
     |> assign(:wallet, wallet)
     |> assign(:providers, Payments.list_provider_statuses())
     |> assign(:subscriptions, Rooms.list_active_subscriptions(user.id))
     |> assign(:presets, @presets)
     |> assign(:paystack_form, to_form(%{"amount" => ""}, as: :paystack))
     |> assign(:mpesa_form, to_form(%{"amount" => "", "phone" => ""}, as: :mpesa))
     |> assign(:txn_page, 1)
     |> assign(:txn_has_more, has_more)
     |> stream(:transactions, txns, reset: true, dom_id: &("txn-" <> &1.id))}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  # phx-change keeps the assigned form in sync with what the user typed,
  # so submitted values survive re-renders (and chips highlight correctly).
  @impl true
  def handle_event("validate_paystack", %{"paystack" => fields}, socket) do
    {:noreply, assign(socket, :paystack_form, to_form(fields, as: :paystack))}
  end

  def handle_event("validate_mpesa", %{"mpesa" => fields}, socket) do
    {:noreply, assign(socket, :mpesa_form, to_form(fields, as: :mpesa))}
  end

  def handle_event("topup_paystack", %{"paystack" => fields}, socket) do
    {:noreply, topup_paystack(socket, fields["amount"] || "")}
  end

  def handle_event("topup_mpesa", %{"mpesa" => fields}, socket) do
    {:noreply, topup_mpesa(socket, fields["amount"] || "", fields["phone"] || "")}
  end

  # The preset chips fill the amount on BOTH provider forms so the chosen
  # amount survives whichever top-up card the user submits.
  def handle_event("topup-amount", %{"amount" => amount}, socket) do
    {:noreply,
     socket
     |> assign(:paystack_form, to_form(%{"amount" => amount}, as: :paystack))
     |> assign(
       :mpesa_form,
       to_form(
         %{"amount" => amount, "phone" => form_value(socket.assigns.mpesa_form, :phone)},
         as: :mpesa
       )
     )}
  end

  def handle_event("refresh_wallet", _params, socket) do
    {:noreply, refresh_wallet_view(socket)}
  end

  def handle_event("load_more", _params, socket) do
    user = socket.assigns.current_user
    page = socket.assigns.txn_page

    {txns, has_more} = Wallet.list_transactions(user.id, @txn_page_size, page * @txn_page_size)

    {:noreply,
     socket
     |> assign(:txn_page, page + 1)
     |> assign(:txn_has_more, has_more)
     |> stream(:transactions, txns)}
  end

  # ---------------------------------------------------------------------------
  # Top-up flows
  # ---------------------------------------------------------------------------

  defp topup_paystack(socket, raw) do
    user = socket.assigns.current_user

    amount =
      case parse_amount(raw) do
        {:ok, %Decimal{} = parsed} -> parsed
        :error -> nil
      end

    cond do
      is_nil(amount) ->
        put_flash(socket, :error, "Enter a valid amount.")

      user.email in [nil, ""] ->
        put_flash(socket, :error, "Add an email to your account before paying with Paystack.")

      true ->
        initiate_paystack(socket, user, amount)
    end
  end

  defp initiate_paystack(socket, user, amount) do
    callback_url = BeamChatWeb.Endpoint.url() <> ~p"/payments/paystack/return"

    case Payments.initiate_topup("paystack", user, amount, callback_url: callback_url) do
      {:ok, %{redirect_url: redirect_url}} when is_binary(redirect_url) and redirect_url != "" ->
        redirect(socket, external: redirect_url)

      {:ok, _} ->
        # Paystack always returns a hosted-checkout URL; reaching this
        # branch means the provider contract drifted. Say so rather
        # than strand the pending row silently.
        put_flash(socket, :error, "Paystack did not return a checkout URL — please try again.")

      {:error, reason} ->
        put_flash(socket, :error, topup_error_message(reason))
    end
  end

  defp topup_mpesa(socket, amount_raw, phone_raw) do
    user = socket.assigns.current_user
    phone = String.trim(phone_raw)

    amount =
      case parse_amount(amount_raw) do
        {:ok, %Decimal{} = parsed} -> parsed
        :error -> nil
      end

    cond do
      is_nil(amount) ->
        put_flash(socket, :error, "Enter a valid amount.")

      phone == "" ->
        put_flash(socket, :error, "Enter an M-Pesa phone number.")

      true ->
        initiate_mpesa(socket, user, amount, phone)
    end
  end

  defp initiate_mpesa(socket, user, amount, phone) do
    case Payments.initiate_topup("mpesa", user, amount, phone: phone) do
      {:ok, %{redirect_url: nil}} ->
        socket
        |> put_flash(
          :info,
          "Check your phone — an M-Pesa prompt is on its way. Your balance updates once the payment completes."
        )
        |> assign(:mpesa_form, to_form(%{"amount" => "", "phone" => ""}, as: :mpesa))
        |> refresh_wallet_view()

      {:ok, _} ->
        # M-Pesa pushes out-of-band and never returns a redirect URL.
        put_flash(socket, :error, "Unexpected response from M-Pesa — please try again.")

      {:error, reason} ->
        put_flash(socket, :error, topup_error_message(reason))
    end
  end

  # Re-fetches the whole page state: wallet, page-1 ledger (so a fresh
  # pending row is visible right after an STK push), provider statuses,
  # and subscriptions.
  defp refresh_wallet_view(socket) do
    user = socket.assigns.current_user
    {:ok, wallet} = Wallet.ensure_wallet(user.id)
    {txns, has_more} = Wallet.list_transactions(user.id, @txn_page_size, 0)

    socket
    |> assign(:wallet, wallet)
    |> assign(:txn_page, 1)
    |> assign(:txn_has_more, has_more)
    |> assign(:providers, Payments.list_provider_statuses())
    |> assign(:subscriptions, Rooms.list_active_subscriptions(user.id))
    |> stream(:transactions, txns, reset: true, dom_id: &("txn-" <> &1.id))
  end

  defp topup_error_message(:provider_disabled),
    do: "This payment method is currently disabled by the platform."

  defp topup_error_message(reason)
       when reason in [:provider_not_configured, :missing_config],
       do:
         "This payment method is missing its credentials — an admin needs to finish setting it up."

  defp topup_error_message(:phone_required),
    do: "Enter an M-Pesa phone number."

  defp topup_error_message(:mpesa_unavailable_currency),
    do: "M-Pesa requires the platform currency to be KES."

  defp topup_error_message(:unknown_provider),
    do: "That payment method isn't available."

  defp topup_error_message(_reason),
    do: "Could not start the top-up — please try again."

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6" id="wallet-page">
      <%!-- Page header --%>
      <header class="space-y-1">
        <h1 class="text-headline-lg tracking-tight text-base-content">Wallet</h1>

        <p class="text-sm text-base-content/60">
          Top up your balance, keep your paid-room subscriptions current, and audit every transaction.
        </p>
      </header>

      <%!-- Balance --%>
      <section
        class="card bg-white border border-base-300 shadow-panel rounded-box"
        id="wallet-balance-card"
      >
        <div class="card-body flex-row flex-wrap items-center justify-between gap-4 p-6">
          <div class="flex items-center gap-4">
            <div class="flex size-11 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary">
              <.icon name="hero-banknotes" class="size-6" />
            </div>

            <div>
              <p class="text-label-sm uppercase tracking-[0.12em] text-base-content/50">
                Available balance
              </p>

              <div class="mt-0.5 flex items-end gap-2">
                <p class="tnum text-display-lg leading-none tracking-tight text-base-content">
                  {format_money(@wallet.balance)}
                </p>

                <p class="mb-1 text-sm font-semibold text-base-content/50">{@base_currency}</p>
              </div>
            </div>
          </div>

          <button
            type="button"
            phx-click="refresh_wallet"
            id="wallet-refresh"
            class="btn btn-ghost btn-sm gap-2 text-base-content/70 hover:text-base-content"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Refresh
          </button>
        </div>
      </section>

      <div class="grid items-start gap-6 lg:grid-cols-3" id="wallet-grid">
        <%!-- Transactions (left two thirds) --%>
        <section
          class="card bg-white border border-base-300 shadow-panel rounded-box overflow-hidden lg:col-span-2"
          id="wallet-transactions"
        >
          <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 px-5 py-4">
            <div class="space-y-0.5">
              <h2 class="text-headline-md text-base-content">Transactions</h2>

              <p class="text-sm text-base-content/50">Every credit and debit on your wallet.</p>
            </div>

            <label for="txn-filter" class="sr-only">Filter transactions</label>

            <input
              id="txn-filter"
              type="search"
              placeholder="Filter…"
              autocomplete="off"
              phx-hook=".TxnFilter"
              class="input input-bordered input-sm w-full bg-white sm:w-56"
            />
          </div>

          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr class="text-xs uppercase tracking-wide text-base-content/50">
                  <th class="font-semibold">Description</th>
                  <th class="font-semibold">Provider</th>
                  <th class="font-semibold">Type</th>
                  <th class="font-semibold text-right">Amount</th>
                  <th class="font-semibold">Status</th>
                  <th class="font-semibold">Date</th>
                </tr>
              </thead>

              <tbody id="wallet-txns" phx-update="stream">
                <tr class="hidden only:table-row">
                  <td colspan="6" class="py-8 text-center text-sm text-base-content/50">
                    No transactions yet — top up to get started.
                  </td>
                </tr>

                <tr
                  :for={{tid, txn} <- @streams.transactions}
                  id={tid}
                  data-txn-row={txn.id}
                  class="hover:bg-base-200/60"
                >
                  <td class="max-w-[18rem] truncate text-sm font-medium text-base-content">
                    {txn.description}
                  </td>

                  <td>
                    <span class="badge badge-sm badge-soft badge-neutral">
                      {provider_title(txn.provider)}
                    </span>
                  </td>

                  <td>
                    <span class={["badge badge-sm badge-soft", txn_type_class(txn.type)]}>
                      {txn_type_label(txn.type)}
                    </span>
                  </td>

                  <td class="text-right">
                    <span class={[
                      "tnum whitespace-nowrap text-sm font-semibold",
                      txn.type == "credit" && "text-success",
                      txn.type != "credit" && "text-base-content"
                    ]}>
                      {if txn.type == "credit", do: "+", else: "-"}{format_money(txn.amount)}
                    </span>
                  </td>

                  <td>
                    <span class={["badge badge-sm badge-soft", txn_status_class(txn.status)]}>
                      {txn.status}
                    </span>
                  </td>

                  <td class="tnum whitespace-nowrap text-xs text-base-content/60">
                    {Calendar.strftime(txn.inserted_at, "%Y-%m-%d %H:%M")}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div :if={@txn_has_more} class="border-t border-base-300 px-5 py-4">
            <button
              type="button"
              phx-click="load_more"
              id="load-more-txns"
              class="btn btn-outline btn-sm w-full"
            >
              Load more
            </button>
          </div>
        </section>

        <%!-- Right column: subscriptions, then top-up --%>
        <div class="space-y-4">
          <section
            class="card bg-white border border-base-300 shadow-panel rounded-box"
            id="wallet-subscriptions"
          >
            <div class="card-body gap-3 p-5">
              <h2 class="flex items-center gap-2 text-headline-sm text-base-content">
                <.icon name="hero-clock" class="size-4 text-primary" /> Your subscriptions
              </h2>

              <p :if={@subscriptions == []} class="text-sm text-base-content/60">
                No active subscriptions — subscribe to a paid room to unlock it for 30 days.
              </p>

              <ul :if={@subscriptions != []} class="space-y-2" id="subscription-rows">
                <li
                  :for={sub <- @subscriptions}
                  class="rounded-md border border-base-300 p-3 transition-colors hover:border-primary/40"
                  id={"subscription-#{sub.id}"}
                >
                  <div class="flex items-start justify-between gap-2">
                    <div class="min-w-0">
                      <.link
                        navigate={~p"/rooms/#{sub.room.slug}"}
                        class="block truncate text-sm font-medium text-base-content hover:text-primary"
                      >
                        {sub.room.name}
                      </.link>

                      <p class="mt-0.5 text-xs text-base-content/50">
                        Expires {Calendar.strftime(sub.expires_at, "%d %b %Y")}
                      </p>
                    </div>

                    <span class="badge badge-sm badge-soft badge-success shrink-0">
                      {time_remaining(sub.expires_at)}
                    </span>
                  </div>
                </li>
              </ul>
            </div>
          </section>

          <%!-- Quick amounts fill every available provider's amount input. --%>
          <div :if={any_topup_available?(@providers)} class="space-y-3" id="topup-presets">
            <h2 class="flex items-center gap-2 text-headline-sm text-base-content">
              <.icon name="hero-credit-card" class="size-4 text-primary" /> Top up
            </h2>

            <p class="text-label-sm uppercase tracking-[0.12em] text-base-content/50">
              Quick amounts
            </p>

            <div class="flex flex-wrap gap-2" id="amount-chips">
              <button
                :for={preset <- @presets}
                type="button"
                phx-click="topup-amount"
                phx-value-amount={preset}
                id={"preset-#{preset}"}
                class={[
                  "btn btn-sm rounded-md",
                  preset_active?(assigns, preset) && "btn-primary",
                  !preset_active?(assigns, preset) &&
                    "btn-outline border-base-300 bg-white text-base-content hover:bg-base-200"
                ]}
              >
                <span class="tnum">{@base_currency} {preset}</span>
              </button>
            </div>
          </div>

          <%!-- One card per configured provider: a working form when
                available, a muted explanation when not. --%>
          <%= for provider <- @providers do %>
            <%= if provider.available? && provider.implemented? do %>
              <section
                class="card bg-white border border-base-300 shadow-panel rounded-box"
                id={"topup-#{provider.key}"}
              >
                <div class="card-body gap-3 p-5">
                  <h2 class="flex items-center gap-2 text-headline-sm text-base-content">
                    <.icon name={provider_icon(provider.key)} class="size-4 text-primary" />
                    {provider_title(provider.key)}
                  </h2>

                  <p class="text-sm text-base-content/60">
                    {provider_blurb(provider.key)}
                  </p>

                  <%= if provider.key == "paystack" do %>
                    <.form
                      for={@paystack_form}
                      id="paystack-topup-form"
                      phx-change="validate_paystack"
                      phx-submit="topup_paystack"
                      class="space-y-3"
                    >
                      <.input
                        field={@paystack_form[:amount]}
                        type="text"
                        label={"Amount (#{@base_currency})"}
                        placeholder="0.00"
                        required
                        class="input input-bordered w-full tnum"
                      />

                      <button type="submit" class="btn btn-primary w-full gap-2">
                        <.icon name="hero-banknotes" class="size-4" /> Top up
                      </button>
                    </.form>

                    <p class="text-xs text-base-content/40">
                      You'll be redirected to Paystack's secure checkout to complete the payment.
                    </p>
                  <% end %>

                  <%= if provider.key == "mpesa" do %>
                    <.form
                      for={@mpesa_form}
                      id="mpesa-topup-form"
                      phx-change="validate_mpesa"
                      phx-submit="topup_mpesa"
                      class="space-y-3"
                    >
                      <.input
                        field={@mpesa_form[:amount]}
                        type="text"
                        label={"Amount (#{@base_currency})"}
                        placeholder="0.00"
                        required
                        class="input input-bordered w-full tnum"
                      />

                      <.input
                        field={@mpesa_form[:phone]}
                        type="tel"
                        label="M-Pesa phone"
                        placeholder="07XX XXX XXX"
                        required
                        class="input input-bordered w-full tnum"
                      />

                      <button type="submit" class="btn btn-primary w-full gap-2">
                        <.icon name="hero-phone" class="size-4" /> Send STK push
                      </button>
                    </.form>

                    <p class="text-xs text-base-content/40">
                      Approve the prompt on your phone — your balance updates once the payment completes.
                    </p>
                  <% end %>
                </div>
              </section>
            <% else %>
              <section
                class="card bg-base-200/60 border border-base-300 rounded-box"
                id={"topup-#{provider.key}"}
              >
                <div class="card-body gap-1.5 p-5 opacity-70">
                  <h2 class="flex items-center gap-2 text-headline-sm text-base-content/70">
                    <.icon name={provider_icon(provider.key)} class="size-4 text-base-content/40" />
                    {provider_title(provider.key)}
                  </h2>

                  <p class="text-sm text-base-content/50">
                    {provider_unavailable_reason(provider)}
                  </p>
                </div>
              </section>
            <% end %>
          <% end %>
        </div>
      </div>
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

  defp format_money(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string(:normal)

  defp any_topup_available?(providers) when is_list(providers) do
    Enum.any?(providers, &(&1.available? && &1.implemented?))
  end

  # A chip reads as active when either top-up form holds its amount.
  defp preset_active?(assigns, preset) do
    paystack = form_value(assigns.paystack_form, :amount)
    mpesa = form_value(assigns.mpesa_form, :amount)

    preset in [paystack, mpesa]
  end

  # Why an unavailable provider is switched off. Clause order matters:
  # unimplemented beats everything, admin-disabled beats currency
  # gating (the KES line would be a lie for a provider the admins
  # simply switched off).
  defp provider_unavailable_reason(%{implemented?: false}), do: "Not yet available"

  defp provider_unavailable_reason(%{enabled: false}),
    do: "Disabled by the platform"

  defp provider_unavailable_reason(%{key: "mpesa"}),
    do: "M-Pesa requires the platform currency to be KES"

  defp provider_unavailable_reason(_), do: "Not available right now"

  defp provider_title("paystack"), do: "Paystack"
  defp provider_title("mpesa"), do: "M-Pesa"
  defp provider_title("stripe"), do: "Stripe"
  defp provider_title("internal"), do: "Internal"
  defp provider_title(nil), do: "—"
  defp provider_title(other) when is_binary(other), do: String.capitalize(other)

  defp provider_icon("paystack"), do: "hero-credit-card"
  defp provider_icon("mpesa"), do: "hero-phone"
  defp provider_icon("stripe"), do: "hero-credit-card"
  defp provider_icon(_), do: "hero-banknotes"

  defp provider_blurb("paystack"),
    do: "Pay by card or bank through Paystack's hosted checkout."

  defp provider_blurb("mpesa"), do: "Send an M-Pesa STK push to your Safaricom line."
  defp provider_blurb(_), do: "Add funds to your wallet balance."

  defp txn_type_label("credit"), do: "Credit"
  defp txn_type_label("debit"), do: "Debit"
  defp txn_type_label(other), do: other

  defp txn_type_class("credit"), do: "badge-success"
  defp txn_type_class(_), do: "badge-neutral"

  defp txn_status_class("completed"), do: "badge-success"
  defp txn_status_class("pending"), do: "badge-warning"
  defp txn_status_class("failed"), do: "badge-error"
  defp txn_status_class("reversed"), do: "badge-neutral"
  defp txn_status_class(_), do: "badge-neutral"

  defp time_remaining(%DateTime{} = expires_at) do
    seconds = max(DateTime.diff(expires_at, DateTime.utc_now()), 0)

    cond do
      seconds >= 86_400 -> "#{div(seconds, 86_400)}d left"
      seconds >= 3_600 -> "#{div(seconds, 3_600)}h left"
      seconds > 0 -> "Expiring soon"
      true -> "Expired"
    end
  end
end
