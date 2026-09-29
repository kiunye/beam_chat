defmodule BeamChatWeb.AdminLive.Settings do
  @moduledoc """
  The admin Settings surface (PRD §2.8): one LiveView, three areas —
  Users, Payments, Structure — routed as:

      live "/admin/settings", AdminLive.Settings, :index
      live "/admin/settings/:tab", AdminLive.Settings, :index

  The `:admin` live_session gates entry on `:settings_access`; every
  mutation is still re-checked by its context against the acting user,
  and `{:error, :forbidden}` (and friends) surface as flashes.

  Tab state lives in the URL: `handle_params/3` whitelists
  `params["tab"]` against `~w(users payments structure)` — kept as
  strings, no atoms are ever created from user input.

  List rows are LiveView streams whose items are self-contained wrapper
  maps: any per-row state (an open ban or wallet panel) travels on the
  item and is re-streamed via `stream_insert/3`, never read from
  mutable assigns. The category tree is a plain recursive assign.
  Payment credentials are write-only: stored secrets are never
  rendered, only the date they were last replaced.
  """

  use BeamChatWeb, :live_view

  alias BeamChat.Accounts
  alias BeamChat.Categories
  alias BeamChat.Moderation
  alias BeamChat.Payments
  alias BeamChat.Rooms
  alias BeamChat.Settings
  alias BeamChat.Wallet

  @tabs ~w(users payments structure)
  @roles ~w(member moderator admin)
  @rule_types ~w(word_filter link_filter pattern)
  # Providers with an implementation behind them today (PRD §4.3).
  # Stripe renders as "coming soon" with a disabled toggle.
  @credentialed_providers ~w(paystack mpesa)

  @users_page_size 25
  @rooms_page_size 25
  @txns_page_size 10
  @log_page_size 25

  # ---------------------------------------------------------------------------
  # Mount / params
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Platform settings")
     |> assign(:active_nav, :admin_settings)
     |> assign(
       :tab_bar,
       [
         {"users", "Users", "hero-users"},
         {"payments", "Payments", "hero-credit-card"},
         {"structure", "Structure", "hero-squares-2x2"}
       ]
     )
     |> assign(:roles, @roles)
     |> assign(:rule_types, @rule_types)
     |> assign(
       :banned_options,
       [
         {"All users", ""},
         {"Banned only", "banned"},
         {"Active only", "active"}
       ]
     )
     |> assign(
       :archived_options,
       [
         {"All rooms", ""},
         {"Archived only", "archived"},
         {"Active only", "active"}
       ]
     )
     |> assign(
       :base_currency_form,
       to_form(%{"currency" => Settings.base_currency()}, as: :currency)
     )
     |> assign(
       :category_form,
       to_form(%{"name" => "", "description" => "", "parent_id" => "", "is_hidden" => "false"},
         as: :category
       )
     )
     |> assign(
       :rule_form,
       to_form(
         %{
           "name" => "",
           "type" => "word_filter",
           "words" => "",
           "action" => "block",
           "domains" => "",
           "pattern" => ""
         },
         as: :rule
       )
     )
     |> assign(:rule_type, "word_filter")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = tab_from_params(params["tab"])

    socket =
      socket
      |> assign(:tab, tab)
      |> load_tab(tab, params)

    {:noreply, socket}
  end

  defp tab_from_params(tab) when tab in @tabs, do: tab
  defp tab_from_params(_), do: "users"

  defp load_tab(socket, "users", params) do
    page = parse_page(params["users_page"])
    query = params["q"] || ""
    role = parse_role(params["role"])
    banned = parse_banned(params["banned"])

    {users, has_more?} =
      Accounts.search_users(
        query: query,
        role: role,
        banned: banned,
        page: page,
        per_page: @users_page_size
      )

    rows = Enum.map(users, &user_row/1)

    socket
    |> assign(
      :user_filters,
      %{
        q: query,
        role: role || "",
        banned: params["banned"] || "",
        users_page: page,
        has_more?: has_more?
      }
    )
    |> assign(:total_users, Accounts.count_users())
    |> assign(
      :user_search_form,
      to_form(%{"q" => query, "role" => role || "", "banned" => params["banned"] || ""},
        as: :user_search
      )
    )
    |> stream(:user_rows, rows, reset: true)
  end

  defp load_tab(socket, "payments", _params) do
    assign(socket, :provider_statuses, Payments.list_provider_statuses())
  end

  defp load_tab(socket, "structure", params) do
    page = parse_page(params["rooms_page"])
    search = params["rooms_q"] || ""
    archived = parse_archived(params["archived"])

    rooms =
      Rooms.list_rooms_for_admin(search: search, archived: archived, page: page, category_id: nil)

    has_more? = length(rooms) > @rooms_page_size
    room_rows = rooms |> Enum.take(@rooms_page_size) |> Enum.map(&room_row/1)

    category_options = category_options()

    socket
    |> assign(:categories_tree, Categories.tree())
    |> assign(:categories_flat, Categories.list_categories())
    |> assign(:category_options, category_options)
    |> assign(:room_creation_open, Settings.room_creation_open?())
    |> assign(
      :rooms_filters,
      %{
        rooms_q: search,
        archived: params["archived"] || "",
        rooms_page: page,
        has_more?: has_more?
      }
    )
    |> assign(
      :rooms_search_form,
      to_form(%{"rooms_q" => search, "archived" => params["archived"] || ""}, as: :rooms_search)
    )
    |> stream(:room_rows, room_rows, reset: true)
    |> stream_rules()
    |> stream_logs()
  end

  defp stream_rules(socket) do
    rules = Moderation.list_rules()
    stream(socket, :rule_rows, rules, reset: true)
  end

  defp stream_logs(socket) do
    {logs, has_more?} = Moderation.list_logs(@log_page_size, 0)

    socket
    |> assign(:logs_has_more?, has_more?)
    |> assign(:logs_offset, 0)
    |> stream(:log_rows, logs, reset: true)
  end

  # ---------------------------------------------------------------------------
  # Users tab events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("user-search", params, socket) do
    %{q: q, role: role, banned: banned} = user_search_attrs(params)

    {:noreply,
     push_patch(socket,
       to: ~p"/admin/settings/users?#{%{"q" => q, "role" => role, "banned" => banned}}"
     )}
  end

  def handle_event("users-page", %{"direction" => direction}, socket) do
    filters = socket.assigns.user_filters
    page = shift_page(filters.users_page, direction, filters.has_more?)

    {:noreply,
     push_patch(socket,
       to:
         ~p"/admin/settings/users?#{%{"q" => filters.q, "role" => filters.role, "banned" => filters.banned, "users_page" => page}}"
     )}
  end

  def handle_event("show-ban-panel", %{"user_id" => user_id}, socket) do
    {:noreply, re_stream_user_panel(socket, user_id, :ban)}
  end

  def handle_event("show-wallet-panel", %{"user_id" => user_id}, socket) do
    {:noreply, re_stream_user_panel(socket, user_id, :wallet)}
  end

  def handle_event("hide-panel", %{"user_id" => user_id}, socket) do
    {:noreply, re_stream_user_panel(socket, user_id, nil)}
  end

  def handle_event("set-role", %{"user_id" => user_id, "role" => role}, socket)
      when role in @roles do
    actor = socket.assigns.current_user
    do_set_role(socket, actor, user_id, role)
  end

  def handle_event("set-role", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Invalid role.")}

  def handle_event("ban-user", %{"user_id" => user_id, "reason" => reason}, socket) do
    actor = socket.assigns.current_user
    reason = String.trim(reason || "")

    if reason == "" do
      {:noreply, put_flash(socket, :error, "A ban reason is required.")}
    else
      do_ban_user(socket, actor, user_id, reason)
    end
  end

  def handle_event("unban-user", %{"user_id" => user_id}, socket) do
    actor = socket.assigns.current_user

    case Accounts.get_user(user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That user no longer exists.")}

      target ->
        case Accounts.unban_user(actor, target) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "User unbanned.")
             |> refresh_user_row(target.id)}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "You do not have permission to unban users.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not unban the user.")}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Payments tab events
  # ---------------------------------------------------------------------------

  def handle_event("save-currency", %{"currency" => %{"currency" => currency}}, socket) do
    currency = currency |> String.trim() |> String.upcase()

    warning =
      if currency == "KES",
        do: "",
        else: " Note: M-Pesa top-ups are unavailable unless the platform currency is KES."

    if currency =~ ~r/\A[A-Z]{3}\z/ do
      case Settings.put(:base_currency, currency) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Base currency set to #{currency}.#{warning}")
           |> assign(
             :base_currency_form,
             to_form(%{"currency" => currency}, as: :currency)
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not save the base currency.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Currency must be a 3-letter ISO code, e.g. KES.")}
    end
  end

  def handle_event("toggle-provider", %{"provider" => provider}, socket)
      when provider in @credentialed_providers do
    config = Payments.get_config(provider)
    currently_enabled = match?(%{is_enabled: true}, config || %{is_enabled: false})

    new_state = if currently_enabled, do: "disabled", else: "enabled"

    case Payments.update_provider_config(provider, %{is_enabled: not currently_enabled}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{String.capitalize(provider)} #{new_state}.")
         |> assign(:provider_statuses, Payments.list_provider_statuses())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update the provider.")}
    end
  end

  def handle_event("toggle-provider", _params, socket) do
    {:noreply, put_flash(socket, :error, "That provider cannot be changed yet.")}
  end

  def handle_event("save-provider-credentials", %{"provider" => provider} = params, socket)
      when provider in @credentialed_providers do
    submitted = Map.take(params, provider_credential_fields(provider))

    credentials =
      for field <- provider_credential_fields(provider),
          value = String.trim(submitted[field] || ""),
          value != "" do
        {field, value}
      end
      |> Map.new()

    if credentials == %{} do
      {:noreply, put_flash(socket, :error, "Enter at least one credential field to replace.")}
    else
      is_enabled =
        case Payments.get_config(provider) do
          %{is_enabled: enabled} -> enabled
          nil -> false
        end

      case Payments.update_provider_config(provider, %{
             is_enabled: is_enabled,
             credentials: credentials
           }) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "#{String.capitalize(provider)} credentials replaced.")
           |> assign(:provider_statuses, Payments.list_provider_statuses())}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not save the credentials.")}
      end
    end
  end

  def handle_event("save-provider-credentials", _params, socket) do
    {:noreply, put_flash(socket, :error, "That provider cannot be configured yet.")}
  end

  # ---------------------------------------------------------------------------
  # Structure tab events — categories
  # ---------------------------------------------------------------------------

  def handle_event("save-category", params, socket) do
    attrs = category_attrs(params["category"] || %{})

    case Categories.create_category(attrs) do
      {:ok, _category} ->
        {:noreply,
         socket
         |> put_flash(:info, "Category created.")
         |> assign(
           :category_form,
           to_form(
             %{"name" => "", "description" => "", "parent_id" => "", "is_hidden" => "false"},
             as: :category
           )
         )
         |> reload_structure()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not create the category.")
         |> assign(:category_form, to_form(changeset, as: :category))}
    end
  end

  def handle_event("save-category-edit", %{"category_id" => category_id} = params, socket) do
    category = Categories.get_category(category_id)

    if category do
      attrs =
        params
        |> Map.take(["name", "description", "position", "is_hidden"])
        |> Enum.map(fn
          {"is_hidden", value} -> {"is_hidden", value in ["true", true]}
          {k, v} -> {k, v}
        end)
        |> Map.new()

      case Categories.update_category(category, attrs) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Category updated.")
           |> reload_structure()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not update the category.")}
      end
    else
      {:noreply, put_flash(socket, :error, "That category no longer exists.")}
    end
  end

  def handle_event(
        "reparent-category",
        %{"category_id" => category_id, "parent_id" => parent_id},
        socket
      ) do
    category = Categories.get_category(category_id)
    new_parent_id = if parent_id in ["", nil], do: nil, else: parent_id

    case Categories.reparent(category, new_parent_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Category moved.")
         |> reload_structure()}

      {:error, :cycle} ->
        {:noreply,
         put_flash(socket, :error, "That move would make the category its own ancestor.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not move the category.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Structure tab events — rooms
  # ---------------------------------------------------------------------------

  def handle_event("rooms-search", params, socket) do
    attrs = params["rooms_search"] || %{}

    {:noreply,
     push_patch(socket,
       to:
         ~p"/admin/settings/structure?#{%{"rooms_q" => String.trim(attrs["rooms_q"] || ""), "archived" => attrs["archived"] || ""}}"
     )}
  end

  def handle_event("rooms-page", %{"direction" => direction}, socket) do
    filters = socket.assigns.rooms_filters
    page = shift_page(filters.rooms_page, direction, filters.has_more?)

    {:noreply,
     push_patch(socket,
       to:
         ~p"/admin/settings/structure?#{%{"rooms_q" => filters.rooms_q, "archived" => filters.archived, "rooms_page" => page}}"
     )}
  end

  def handle_event("archive-room", %{"room_id" => room_id}, socket) do
    with room when is_map(room) <- Rooms.get_room(room_id),
         {:ok, _} <- Rooms.set_archived(socket.assigns.current_user, room, true) do
      {:noreply,
       socket
       |> put_flash(:info, "Room archived.")
       |> reload_rooms_stream()}
    else
      nil -> {:noreply, put_flash(socket, :error, "That room no longer exists.")}
      {:error, :forbidden} -> {:noreply, put_flash(socket, :error, "You do not have permission.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not archive the room.")}
    end
  end

  def handle_event("unarchive-room", %{"room_id" => room_id}, socket) do
    with room when is_map(room) <- Rooms.get_room(room_id),
         {:ok, _} <- Rooms.set_archived(socket.assigns.current_user, room, false) do
      {:noreply,
       socket
       |> put_flash(:info, "Room unarchived.")
       |> reload_rooms_stream()}
    else
      nil -> {:noreply, put_flash(socket, :error, "That room no longer exists.")}
      {:error, :forbidden} -> {:noreply, put_flash(socket, :error, "You do not have permission.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not unarchive the room.")}
    end
  end

  def handle_event(
        "reassign-room-category",
        %{"room_id" => room_id, "category_id" => category_id},
        socket
      ) do
    with room when is_map(room) <- Rooms.get_room(room_id),
         %BeamChat.Categories.Category{} <- Categories.get_category(category_id),
         {:ok, _} <-
           Rooms.update_room(socket.assigns.current_user, room, %{"category_id" => category_id}) do
      {:noreply,
       socket
       |> put_flash(:info, "Room category updated.")
       |> reload_rooms_stream()}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "That room or category no longer exists.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Could not reassign the room.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not reassign the room.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Structure tab events — room creation toggle + moderation
  # ---------------------------------------------------------------------------

  def handle_event("toggle-room-creation", %{"open" => open}, socket) do
    open = open in ["true", true]

    case Settings.put(:room_creation_open, open) do
      {:ok, _} ->
        message =
          if open,
            do: "Room creation is now open to all members.",
            else: "Room creation is now restricted to moderators and admins."

        {:noreply, socket |> put_flash(:info, message) |> assign(:room_creation_open, open)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update room creation.")}
    end
  end

  def handle_event("rule-type-changed", %{"rule" => %{"type" => type}}, socket)
      when type in @rule_types do
    {:noreply, assign(socket, :rule_type, type)}
  end

  def handle_event("rule-type-changed", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save-rule", params, socket) do
    attrs = params["rule"] || %{}
    type = attrs["type"] || "word_filter"

    config = rule_config(type, attrs)

    rule_attrs = %{"name" => String.trim(attrs["name"] || ""), "type" => type, "config" => config}

    case Moderation.create_rule(rule_attrs) do
      {:ok, _rule} ->
        refresh_moderation_cache()

        {:noreply,
         socket
         |> put_flash(:info, "Rule created and cache refreshed.")
         |> assign(
           :rule_form,
           to_form(
             %{
               "name" => "",
               "type" => "word_filter",
               "words" => "",
               "action" => "block",
               "domains" => "",
               "pattern" => ""
             },
             as: :rule
           )
         )
         |> assign(:rule_type, "word_filter")
         |> stream_rules()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not create the rule.")
         |> assign(:rule_form, to_form(changeset, as: :rule))}
    end
  end

  def handle_event("toggle-rule", %{"rule_id" => rule_id, "active" => active}, socket) do
    active = active in ["true", true]

    case Moderation.update_rule(rule_id, %{"is_active" => active}) do
      {:ok, _} ->
        refresh_moderation_cache()

        {:noreply,
         socket
         |> put_flash(:info, "Rule #{if(active, do: "activated", else: "deactivated")}.")
         |> stream_rules()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update the rule.")}
    end
  end

  def handle_event("delete-rule", %{"rule_id" => rule_id}, socket) do
    case Moderation.delete_rule(rule_id) do
      {:ok, _} ->
        refresh_moderation_cache()
        {:noreply, socket |> put_flash(:info, "Rule deleted.") |> stream_rules()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete the rule.")}
    end
  end

  def handle_event("load-more-logs", _params, socket) do
    offset = socket.assigns.logs_offset + @log_page_size
    {logs, has_more?} = Moderation.list_logs(@log_page_size, offset)

    {:noreply,
     socket
     |> assign(:logs_offset, offset)
     |> assign(:logs_has_more?, has_more?)
     |> stream(:log_rows, logs)}
  end

  defp do_set_role(socket, actor, user_id, role) do
    case Accounts.get_user(user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That user no longer exists.")}

      target ->
        case Accounts.set_global_role(actor, target, role) do
          {:ok, _user} ->
            {:noreply,
             socket
             |> put_flash(:info, "Platform role updated.")
             |> refresh_user_row(user_id)}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "You do not have permission to change roles.")}

          {:error, :self_role_change} ->
            {:noreply, put_flash(socket, :error, "You cannot change your own platform role.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not update the role.")}
        end
    end
  end

  defp do_ban_user(socket, actor, user_id, reason) do
    case Accounts.get_user(user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That user no longer exists.")}

      target ->
        case Accounts.ban_user(actor, target, reason) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "User banned and all sessions revoked.")
             |> refresh_user_row(target.id)}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "You do not have permission to ban users.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not ban the user.")}
        end
    end
  end

  defp provider_credential_fields("paystack"), do: ~w(secret_key base_url)

  defp provider_credential_fields("mpesa"),
    do: ~w(consumer_key consumer_secret shortcode passkey stk_callback_url callback_secret)

  defp provider_credential_fields(_), do: []

  defp refresh_moderation_cache do
    _ = Moderation.refresh_rule_cache()
    :ok
  end

  defp split_list(value) when is_binary(value) do
    value
    |> String.split(~r/[,\n]/, trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp split_list(_), do: []

  defp rule_config("word_filter", attrs), do: %{"words" => split_list(attrs["words"])}
  defp rule_config("pattern", attrs), do: %{"patterns" => split_list(attrs["pattern"])}

  defp rule_config("link_filter", attrs) do
    action = if attrs["action"] in ["block", "flag"], do: attrs["action"], else: "block"
    %{"action" => action, "domains" => split_list(attrs["domains"])}
  end

  defp rule_config(_type, _attrs), do: %{}

  defp category_attrs(attrs) do
    %{
      "name" => String.trim(attrs["name"] || ""),
      "description" => String.trim(attrs["description"] || ""),
      "parent_id" => parent_id(attrs["parent_id"]),
      "is_hidden" => attrs["is_hidden"] in ["true", true, "on"]
    }
  end

  defp parent_id(""), do: nil
  defp parent_id(nil), do: nil
  defp parent_id(parent_id), do: parent_id

  defp reload_structure(socket) do
    socket
    |> assign(:categories_tree, Categories.tree())
    |> assign(:categories_flat, Categories.list_categories())
    |> assign(:category_options, category_options())
    |> reload_rooms_stream()
  end

  defp reload_rooms_stream(socket) do
    filters = socket.assigns.rooms_filters

    rooms =
      Rooms.list_rooms_for_admin(
        search: filters.rooms_q,
        archived: parse_archived(filters.archived),
        page: filters.rooms_page
      )

    has_more? = length(rooms) > @rooms_page_size
    room_rows = rooms |> Enum.take(@rooms_page_size) |> Enum.map(&room_row/1)
    filters = Map.put(socket.assigns.rooms_filters, :has_more?, has_more?)

    socket
    |> assign(:rooms_filters, filters)
    |> assign(room_creation_open: Settings.room_creation_open?())
    |> stream(:room_rows, room_rows, reset: true)
  end

  # Row wrappers: state travels on the item so stream rows stay
  # self-contained (panel: nil | :ban | :wallet).
  defp user_row(user) do
    user_row(user, nil)
  end

  defp user_row(user, panel) do
    %{
      id: user.id,
      user: user,
      wallet: Wallet.get_wallet_for_user(user.id),
      txns: user_txns(panel, user.id),
      panel: panel
    }
  end

  defp user_txns(:wallet, user_id), do: Wallet.list_recent_transactions(user_id, @txns_page_size)
  defp user_txns(_, _user_id), do: []

  defp refresh_user_row(socket, user_id) do
    case Accounts.get_user(user_id) do
      nil ->
        socket

      user ->
        existing =
          socket.assigns.streams.user_rows
          |> Enum.find(fn {dom_id, _row} -> dom_id == "user_rows-#{user_id}" end)

        panel =
          case existing do
            {_dom_id, %{panel: panel}} -> panel
            nil -> nil
          end

        stream_insert(socket, :user_rows, user_row(user, panel))
    end
  end

  defp re_stream_user_panel(socket, user_id, panel) do
    case Accounts.get_user(user_id) do
      nil ->
        socket

      user ->
        stream_insert(socket, :user_rows, user_row(user, panel))
    end
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {page, _} when page > 0 -> page
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  defp parse_role(role) when role in @roles, do: role
  defp parse_role(_), do: nil

  defp parse_banned("banned"), do: true
  defp parse_banned("active"), do: false
  defp parse_banned(_), do: nil

  defp parse_archived("archived"), do: true
  defp parse_archived("active"), do: false
  defp parse_archived(_), do: nil

  defp shift_page(page, "next", has_more?) when has_more? and page < 999, do: page + 1
  defp shift_page(page, "prev", _has_more?) when page > 1, do: page - 1
  defp shift_page(page, _, _has_more?), do: page

  defp user_search_attrs(params) do
    %{
      q: String.trim(params["user_search"]["q"] || params["q"] || ""),
      role: params["user_search"]["role"] || "",
      banned: params["user_search"]["banned"] || ""
    }
  end

  defp room_row(room) do
    %{
      id: room.id,
      room: room,
      category_options: category_options()
    }
  end

  defp category_options do
    [{"— root —", ""}] ++
      Enum.map(Categories.list_categories(), &{"#{&1.name} (#{&1.slug})", &1.id})
  end

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="admin-settings" class="flex flex-col gap-6">
      <header class="flex flex-wrap items-end justify-between gap-3">
        <div>
          <div class="text-label-md uppercase tracking-wide text-base-content/50">Admin</div>

          <h1 class="text-headline-lg">Platform settings</h1>

          <p class="text-sm text-base-content/60">
            Users, payments, and the category / room structure — one surface, admin only.
          </p>
        </div>

        <div class="beam-chip">
          <.icon name="hero-shield-check" class="size-4 text-primary" /> admin access
        </div>
      </header>

      <nav class="flex gap-1 border-b border-base-300" aria-label="Settings sections">
        <.link
          :for={{tab, label, icon} <- @tab_bar}
          id={"tab-link-#{tab}"}
          patch={~p"/admin/settings/#{tab}"}
          class={[
            "flex items-center gap-2 -mb-px px-4 py-2.5 text-sm font-medium transition-colors",
            @tab == tab && "border-b-2 border-primary text-primary",
            @tab != tab &&
              "border-b-2 border-transparent text-base-content/60 hover:text-base-content"
          ]}
        >
          <.icon name={icon} class="size-4" /> {label}
        </.link>
      </nav>

      <%= if @tab == "users" do %>
        <.users_tab {assigns} />
      <% end %>

      <%= if @tab == "payments" do %>
        <.payments_tab {assigns} />
      <% end %>

      <%= if @tab == "structure" do %>
        <.structure_tab {assigns} />
      <% end %>
    </div>
    """
  end

  # -- Users tab --------------------------------------------------------------

  defp users_tab(assigns) do
    ~H"""
    <div id="users-tab" class="flex flex-col gap-4">
      <div class="flex flex-wrap items-center gap-3">
        <div class="card bg-white border border-base-300 shadow-panel rounded-box flex-1 p-4">
          <.form
            for={@user_search_form}
            id="user-search-form"
            phx-submit="user-search"
            class="flex flex-wrap items-end gap-3"
          >
            <div class="flex-1 min-w-[200px]">
              <.input
                field={@user_search_form[:q]}
                type="text"
                label="Search"
                placeholder="username or email"
              />
            </div>

            <div class="w-44">
              <.input
                field={@user_search_form[:role]}
                type="select"
                label="Role"
                options={@roles}
                prompt="Any role"
              />
            </div>

            <div class="w-44">
              <.input
                field={@user_search_form[:banned]}
                type="select"
                label="Status"
                options={@banned_options}
              />
            </div>

            <button type="submit" name="button" value="submit" class="btn btn-primary">
              <.icon name="hero-magnifying-glass" class="size-4" /> Search
            </button>
          </.form>
        </div>

        <div class="card bg-white border border-base-300 shadow-panel rounded-box px-5 py-4">
          <div class="text-label-sm text-base-content/50 uppercase">Members</div>

          <div class="text-headline-lg">{@total_users}</div>
        </div>
      </div>

      <div id="user-rows" phx-update="stream">
        <div :for={{dom_id, row} <- @streams.user_rows} id={dom_id}><.user_row_card {row} /></div>
      </div>

      <div class="hidden only:block card bg-white border border-base-300 rounded-box p-8 text-center text-base-content/50">
        No users match this search.
      </div>

      <div class="flex items-center justify-between">
        <div class="text-label-sm text-base-content/50">Page {@user_filters.users_page}</div>

        <div class="flex gap-2">
          <button
            class="btn btn-outline btn-sm"
            phx-click="users-page"
            phx-value-direction="prev"
            disabled={@user_filters.users_page <= 1}
          >
            <.icon name="hero-chevron-left" class="size-4" /> Prev
          </button>
          <button
            class="btn btn-outline btn-sm"
            phx-click="users-page"
            phx-value-direction="next"
            disabled={not @user_filters.has_more?}
          >
            Next <.icon name="hero-chevron-right" class="size-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp user_row_card(assigns) do
    ~H"""
    <div class="card bg-white border border-base-300 shadow-panel rounded-box p-4 mb-3">
      <div class="flex flex-wrap items-center gap-3">
        <div class="flex size-10 shrink-0 items-center justify-center rounded-full bg-base-200 text-sm font-semibold uppercase">
          {String.slice(@user.username, 0, 2)}
        </div>

        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <span class="font-semibold truncate">{@user.username}</span>
            <span class="badge badge-soft capitalize">{@user.role}</span>
            <%= if @user.is_banned do %>
              <span class="badge badge-error">banned</span>
            <% end %>
          </div>

          <div class="text-sm text-base-content/50 truncate">
            {@user.email || "no email"}{if @user.ban_reason, do: " — “#{@user.ban_reason}”"}
          </div>
        </div>

        <form phx-change="set-role" phx-value-user_id={@user.id} class="flex items-center gap-2">
          <select
            name="role"
            class="select select-bordered select-sm"
            aria-label="Platform role for #{@user.username}"
            disabled={@user.is_banned}
          >
            {Phoenix.HTML.Form.options_for_select(["member", "moderator", "admin"], @user.role)}
          </select>
        </form>

        <div class="flex items-center gap-2">
          <%= if @user.is_banned do %>
            <button
              class="btn btn-sm btn-outline btn-success"
              phx-click="unban-user"
              phx-value-user_id={@user.id}
              data-confirm="Unban #{@user.username}?"
            >
              Unban
            </button>
          <% else %>
            <button
              class="btn btn-sm btn-ghost"
              phx-click={JS.toggle(to: "#ban-panel-#{@user.id}")}
              aria-expanded={to_string(@panel == :ban)}
            >
              <.icon name="hero-no-symbol" class="size-4" /> Ban
            </button>
          <% end %>

          <button
            class="btn btn-sm btn-ghost"
            phx-click={JS.toggle(to: "#wallet-panel-#{@user.id}")}
            aria-expanded={to_string(@panel == :wallet)}
          >
            <.icon name="hero-banknotes" class="size-4" /> Wallet
          </button>
        </div>
      </div>

      <div id={"ban-panel-#{@user.id}"} class="hidden mt-3 border-t border-base-200 pt-3">
        <form
          phx-submit="ban-user"
          phx-value-user_id={@user.id}
          class="flex flex-wrap items-end gap-2"
        >
          <div class="flex-1 min-w-[240px]">
            <label class="label">
              <span class="label-text">Ban reason (required, recorded)</span>
            </label>
            <input
              type="text"
              name="reason"
              required
              placeholder="Why is this account being banned?"
              class="input input-bordered w-full"
            />
          </div>

          <button type="submit" class="btn btn-sm btn-error" data-confirm="Ban #{@user.username}?">
            Confirm ban
          </button>
        </form>
      </div>

      <div id={"wallet-panel-#{@user.id}"} class="hidden mt-3 border-t border-base-200 pt-3">
        <%= if @wallet do %>
          <div class="flex flex-wrap items-center gap-2 mb-2">
            <span class="badge badge-primary tnum">
              {Decimal.to_string(@wallet.balance)} {@wallet.currency}
            </span>
            <span class="text-label-sm text-base-content/50">current balance (read-only)</span>
          </div>

          <table class="table table-sm table-zebra">
            <thead>
              <tr>
                <th>Description</th>
                <th>Type</th>
                <th class="text-right">Amount</th>
                <th>Status</th>
                <th>When</th>
              </tr>
            </thead>

            <tbody>
              <tr :for={txn <- @txns}>
                <td class="max-w-[220px] truncate">{txn.description}</td>

                <td>{txn.type}</td>

                <td class="text-right tnum">{Decimal.to_string(txn.amount)}</td>

                <td><span class="badge badge-soft">{txn.status}</span></td>

                <td class="text-base-content/50">
                  {Calendar.strftime(txn.inserted_at, "%d %b %H:%M")}
                </td>
              </tr>
            </tbody>
          </table>

          <p :if={@txns == []} class="text-sm text-base-content/50">No transactions yet.</p>
        <% else %>
          <p class="text-sm text-base-content/50">
            No wallet yet — it is created on the user's first visit.
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  # -- Payments tab ------------------------------------------------------------

  defp payments_tab(assigns) do
    ~H"""
    <div id="payments-tab" class="flex flex-col gap-4">
      <div class="card bg-white border border-base-300 shadow-panel rounded-box p-5">
        <h2 class="text-headline-sm mb-1">Base currency</h2>

        <p class="text-sm text-base-content/60 mb-3">
          One currency for the whole platform: room prices, wallet balances, and top-ups are all
          denominated in it. M-Pesa (Daraja) only moves Kenyan shillings — when this is not KES,
          the M-Pesa top-up option is unavailable.
        </p>

        <.form
          for={@base_currency_form}
          id="base-currency-form"
          phx-submit="save-currency"
          class="flex items-end gap-3"
        >
          <div class="w-40">
            <.input
              field={@base_currency_form[:currency]}
              type="text"
              label="Currency code"
              placeholder="KES"
            />
          </div>
          <button type="submit" class="btn btn-primary">Save</button>
        </.form>
      </div>

      <div class="grid gap-4 lg:grid-cols-2">
        <.provider_card :for={status <- @provider_statuses} {status} />
      </div>
    </div>
    """
  end

  defp provider_card(assigns) do
    ~H"""
    <div
      id={"provider-#{@key}"}
      class="card bg-white border border-base-300 shadow-panel rounded-box p-5 flex flex-col gap-3"
    >
      <div class="flex items-center justify-between">
        <h3 class="text-headline-sm capitalize">{@key}</h3>

        <div class="flex items-center gap-2">
          <%= if @available? do %>
            <span class="badge badge-success">live</span>
          <% else %>
            <span class="badge badge-ghost">off</span>
          <% end %>

          <label class="flex cursor-pointer items-center gap-2 text-sm">
            <input
              type="checkbox"
              class="toggle toggle-primary"
              checked={@enabled}
              disabled={not @implemented?}
              phx-click="toggle-provider"
              phx-value-provider={@key}
            /> Enabled
          </label>
        </div>
      </div>

      <%= if @key == "paystack" and @implemented? do %>
        <p class="text-sm text-base-content/60">
          Card top-ups through Paystack's hosted checkout. Verified webhook with
          <code class="text-code-sm">x-paystack-signature</code>
          HMAC.
        </p>
        <.provider_credentials_form provider={@key} fields={~w(secret_key base_url)} />
      <% end %>

      <%= if @key == "mpesa" and @implemented? do %>
        <p class="text-sm text-base-content/60">
          M-Pesa STK push via Daraja. Requires the platform currency to be KES.
          The callback URL must embed the shared secret:
          <code class="text-code-sm">https://host/webhooks/mpesa/{"<secret>"}</code>
        </p>

        <.provider_credentials_form
          provider={@key}
          fields={~w(consumer_key consumer_secret shortcode passkey stk_callback_url callback_secret)}
        />
      <% end %>

      <%= if @key == "stripe" do %>
        <p class="text-sm text-base-content/60">
          Coming soon — Stripe is not implemented in this version. The provider
          interface it will implement already exists
          (<code class="text-code-sm">BeamChat.Payments.Provider</code>).
        </p>
      <% end %>

      <%= if not @available? and @implemented? and @key == "mpesa" do %>
        <p class="text-sm text-warning">
          <.icon name="hero-exclamation-triangle" class="size-4 inline" />
          M-Pesa is unavailable while the platform currency is not KES.
        </p>
      <% end %>
    </div>
    """
  end

  defp provider_credentials_form(assigns) do
    ~H"""
    <form
      id={"credentials-form-#{@provider}"}
      phx-submit="save-provider-credentials"
      phx-value-provider={@provider}
      class="border-t border-base-200 pt-3"
    >
      <div class="text-label-sm text-base-content/50 mb-2">
        Replace credentials (write-only — stored values are never shown)
      </div>

      <div class="grid gap-3 sm:grid-cols-2">
        <div :for={field <- @fields} class="form-control">
          <label>
            <span class="label-text text-sm capitalize">{field |> String.replace("_", " ")}</span>
            <input
              type={if(field =~ "secret" or field =~ "key", do: "password", else: "text")}
              name={field}
              class="input input-bordered mt-1"
              autocomplete="off"
            />
          </label>
        </div>
      </div>

      <button
        type="submit"
        class="btn btn-outline btn-sm mt-3"
        data-confirm="Replace stored credentials?"
      >
        Save credentials
      </button>
    </form>
    """
  end

  # -- Structure tab -----------------------------------------------------------

  defp structure_tab(assigns) do
    ~H"""
    <div id="structure-tab" class="flex flex-col gap-6">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h2 class="text-headline-sm">Categories & rooms</h2>

          <p class="text-sm text-base-content/60">
            The tree is a navigation structure; rooms hang off its nodes.
          </p>
        </div>

        <div class="card bg-white border border-base-300 shadow-panel rounded-box px-4 py-3 flex items-center gap-3">
          <div>
            <div class="text-label-sm text-base-content/50 uppercase">Room creation</div>

            <div class="text-sm">
              <%= if @room_creation_open do %>
                Open to all members
              <% else %>
                Moderators & admins only
              <% end %>
            </div>
          </div>

          <label class="flex cursor-pointer items-center gap-2 text-sm">
            <input
              type="checkbox"
              class="toggle toggle-primary"
              checked={@room_creation_open}
              phx-click="toggle-room-creation"
              phx-value-open={to_string(not @room_creation_open)}
            />
          </label>
        </div>
      </div>

      <div class="grid gap-6 xl:grid-cols-2">
        <div class="card bg-white border border-base-300 shadow-panel rounded-box p-5">
          <h3 class="text-headline-sm mb-3">Create a category</h3>

          <.form
            for={@category_form}
            id="new-category-form"
            phx-submit="save-category"
            class="flex flex-col gap-3"
          >
            <.input
              field={@category_form[:name]}
              type="text"
              label="Name"
              placeholder="e.g. Shooters"
            />
            <.input field={@category_form[:description]} type="text" label="Description (optional)" />
            <.input
              field={@category_form[:parent_id]}
              type="select"
              label="Parent category"
              options={@category_options}
            />
            <label class="label cursor-pointer justify-start gap-3">
              <input
                type="checkbox"
                name="category[is_hidden]"
                value="true"
                class="checkbox checkbox-sm"
              /> <span class="label-text">Hidden (visible to admins and moderators only)</span>
            </label>
            <button type="submit" class="btn btn-primary btn-sm self-start">
              <.icon name="hero-plus" class="size-4" /> Create
            </button>
          </.form>
        </div>

        <div class="card bg-white border border-base-300 shadow-panel rounded-box p-5">
          <h3 class="text-headline-sm mb-3">Category tree</h3>

          <div :if={@categories_tree == []} class="text-sm text-base-content/50">
            No categories yet — create the first one.
          </div>
          <.category_node :for={node <- @categories_tree} node={node} depth={0} assigns={assigns} />
        </div>
      </div>

      <div class="card bg-white border border-base-300 shadow-panel rounded-box p-5">
        <div class="flex flex-wrap items-center justify-between gap-3 mb-3">
          <h3 class="text-headline-sm">Rooms</h3>

          <.form
            for={@rooms_search_form}
            id="rooms-search-form"
            phx-submit="rooms-search"
            class="flex items-end gap-2"
          >
            <.input
              field={@rooms_search_form[:rooms_q]}
              type="text"
              label="Search"
              placeholder="room name"
            />
            <.input
              field={@rooms_search_form[:archived]}
              type="select"
              label="State"
              options={@archived_options}
            /> <button type="submit" class="btn btn-outline btn-sm">Search</button>
          </.form>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Room</th>
                <th>Type</th>
                <th>Category</th>
                <th>Owner</th>
                <th>State</th>
                <th class="text-right">Actions</th>
              </tr>
            </thead>

            <tbody id="room-rows" phx-update="stream">
              <tr :for={{dom_id, row} <- @streams.room_rows} id={dom_id}>
                <td>
                  <div class="font-semibold">{row.room.name}</div>

                  <div class="text-label-sm text-base-content/50">{row.room.slug}</div>
                </td>

                <td><span class="badge badge-soft capitalize">{row.room.type}</span></td>

                <td>
                  <select
                    name="category_id"
                    aria-label="Category for #{row.room.name}"
                    class="select select-bordered select-sm max-w-[160px]"
                    phx-change="reassign-room-category"
                    phx-value-room_id={row.room.id}
                  >
                    {Phoenix.HTML.Form.options_for_select(@category_options, row.room.category_id)}
                  </select>
                </td>

                <td class="text-base-content/60">{row.room.owner.username}</td>

                <td>
                  <%= if row.room.is_archived do %>
                    <span class="badge badge-neutral">archived</span>
                  <% else %>
                    <span class="badge badge-success">active</span>
                  <% end %>
                </td>

                <td class="text-right whitespace-nowrap">
                  <%= if row.room.is_archived do %>
                    <button
                      class="btn btn-xs btn-outline"
                      phx-click="unarchive-room"
                      phx-value-room_id={row.room.id}
                    >
                      Unarchive
                    </button>
                  <% else %>
                    <button
                      class="btn btn-xs btn-outline btn-error"
                      phx-click="archive-room"
                      phx-value-room_id={row.room.id}
                      data-confirm="Archive #{row.room.name}?"
                    >
                      Archive
                    </button>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="mt-3 flex items-center justify-between">
          <span class="text-label-sm text-base-content/50">Page {@rooms_filters.rooms_page}</span>
          <div class="flex gap-2">
            <button
              class="btn btn-outline btn-sm"
              phx-click="rooms-page"
              phx-value-direction="prev"
              disabled={@rooms_filters.rooms_page <= 1}
            >
              Prev
            </button>
            <button
              class="btn btn-outline btn-sm"
              phx-click="rooms-page"
              phx-value-direction="next"
              disabled={not @rooms_filters.has_more?}
            >
              Next
            </button>
          </div>
        </div>
      </div>

      <div class="grid gap-6 xl:grid-cols-2">
        <div class="card bg-white border border-base-300 shadow-panel rounded-box p-5">
          <h3 class="text-headline-sm mb-1">Moderation rules</h3>

          <p class="text-sm text-base-content/60 mb-3">
            Applied to every message before it is stored; blocks and flags are logged.
          </p>

          <.form
            for={@rule_form}
            id="new-rule-form"
            phx-submit="save-rule"
            phx-change="rule-type-changed"
            class="flex flex-col gap-3 border-b border-base-200 pb-4 mb-4"
          >
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                field={@rule_form[:name]}
                type="text"
                label="Rule name"
                placeholder="No spam links"
              /> <.input field={@rule_form[:type]} type="select" label="Type" options={@rule_types} />
            </div>

            <%= if @rule_type == "word_filter" do %>
              <.input
                field={@rule_form[:words]}
                type="text"
                label="Blocked words"
                placeholder="comma separated"
              />
            <% end %>

            <%= if @rule_type == "pattern" do %>
              <.input
                field={@rule_form[:pattern]}
                type="text"
                label="Blocked regex pattern"
                placeholder="(?i)buy.{0,10}crypto"
              />
            <% end %>

            <%= if @rule_type == "link_filter" do %>
              <div class="grid gap-3 sm:grid-cols-2">
                <.input
                  field={@rule_form[:action]}
                  type="select"
                  label="Action"
                  options={["block", "flag"]}
                />
                <.input
                  field={@rule_form[:domains]}
                  type="text"
                  label="Domains"
                  placeholder="spam.example, ads.example"
                />
              </div>
            <% end %>

            <button type="submit" class="btn btn-primary btn-sm self-start">
              <.icon name="hero-plus" class="size-4" /> Add rule
            </button>
          </.form>

          <table class="table table-sm">
            <tbody id="rule-rows" phx-update="stream">
              <tr :for={{dom_id, rule} <- @streams.rule_rows} id={dom_id}>
                <td class="font-semibold">{rule.name}</td>

                <td><span class="badge badge-soft">{rule.type}</span></td>

                <td>
                  <%= if rule.is_active do %>
                    <span class="badge badge-success">active</span>
                  <% else %>
                    <span class="badge badge-ghost">off</span>
                  <% end %>
                </td>

                <td class="text-right whitespace-nowrap">
                  <button
                    class="btn btn-xs btn-ghost"
                    phx-click="toggle-rule"
                    phx-value-rule_id={rule.id}
                    phx-value-active={to_string(not rule.is_active)}
                  >
                    {if rule.is_active, do: "Deactivate", else: "Activate"}
                  </button>
                  <button
                    class="btn btn-xs btn-ghost text-error"
                    phx-click="delete-rule"
                    phx-value-rule_id={rule.id}
                    data-confirm="Delete rule #{rule.name}?"
                  >
                    Delete
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="card bg-white border border-base-300 shadow-panel rounded-box p-5">
          <h3 class="text-headline-sm mb-1">Moderation log</h3>

          <p class="text-sm text-base-content/60 mb-3">
            Every block, flag, and manual action — with its origin.
          </p>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <tbody id="log-rows" phx-update="stream">
                <tr :for={{dom_id, log} <- @streams.log_rows} id={dom_id}>
                  <td><span class="badge badge-soft">{log.action}</span></td>

                  <td class="max-w-[200px] truncate text-base-content/60">{log.reason || "—"}</td>

                  <td>
                    <%= if log.rule_id do %>
                      <span class="badge badge-warning badge-sm">rule</span>
                    <% else %>
                      <span class="text-sm text-base-content/60">
                        {(log.actor && log.actor.username) || "system"}
                      </span>
                    <% end %>
                  </td>

                  <td class="text-label-sm text-base-content/50 whitespace-nowrap">
                    {relative_time(log.inserted_at)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <button :if={@logs_has_more?} class="btn btn-outline btn-sm mt-3" phx-click="load-more-logs">
            Load more
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp category_node(assigns) do
    ~H"""
    <div
      id={"category-#{assigns.node.category.id}"}
      class="mb-1"
      style={"margin-left: #{assigns.depth * 1.25}rem"}
    >
      <div class="flex flex-wrap items-center gap-2 rounded-md px-2 py-1.5 hover:bg-base-100">
        <%= if assigns.node.category.is_hidden do %>
          <.icon name="hero-eye-slash" class="size-4 text-warning" />
        <% else %>
          <.icon name="hero-folder" class="size-4 text-primary" />
        <% end %>
        <span class="text-sm font-semibold">{assigns.node.category.name}</span>
        <span class="text-label-sm text-base-content/40">{assigns.node.category.slug}</span>
        <span class="text-label-sm text-base-content/40">· pos {assigns.node.category.position}</span>
        <form
          phx-submit="save-category-edit"
          phx-value-category_id={assigns.node.category.id}
          class="ml-auto flex items-center gap-1"
        >
          <input
            type="text"
            name="name"
            value={assigns.node.category.name}
            aria-label="Rename"
            class="input input-bordered input-xs w-28"
          />
          <input
            type="number"
            name="position"
            min="0"
            value={assigns.node.category.position}
            aria-label="Position"
            class="input input-bordered input-xs w-16"
          />
          <label class="flex items-center gap-1 text-label-sm text-base-content/50" title="Hidden">
            <input type="hidden" name="is_hidden" value="false" />
            <input
              type="checkbox"
              name="is_hidden"
              value="true"
              checked={assigns.node.category.is_hidden}
              class="checkbox checkbox-xs"
            /> hidden
          </label>
          <button type="submit" class="btn btn-xs btn-ghost">Save</button>
        </form>

        <form
          phx-submit="reparent-category"
          phx-value-category_id={assigns.node.category.id}
          class="flex items-center gap-1"
        >
          <select
            name="parent_id"
            aria-label="Move under"
            class="select select-bordered select-xs max-w-[140px]"
          >
            {Phoenix.HTML.Form.options_for_select(
              assigns.assigns.category_options,
              assigns.node.category.parent_id
            )}
          </select>
          <button type="submit" class="btn btn-xs btn-ghost">Move</button>
        </form>
      </div>

      <.category_node
        :for={child <- assigns.node.children}
        node={child}
        depth={assigns.depth + 1}
        assigns={assigns.assigns}
      />
    </div>
    """
  end
end
