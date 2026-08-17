defmodule BeamChat.Repo do
  use Ecto.Repo,
    otp_app: :beam_chat,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Run `fun` inside a transaction with the tenant/user session GUCs set via
  `SET LOCAL`, so PostgreSQL Row Level Security sees the correct
  `app.current_tenant_id` / `app.current_user_id` for the duration of the
  transaction only (CATEGORY_REDESIGN.md §3.6 / §4.3).

  `tenant_id` and `user_id` may be binaries (uuid string) or any value
  coercible with `to_string`. The inner return value of `fun` is unwrapped
  and returned directly; on rollback/error the `{:error, _}` tuple is passed
  through unchanged.
  """
  def with_tenant(tenant_id, user_id, fun) when is_function(fun, 0) do
    case __MODULE__.transaction(fn ->
           # `set_config(..., true)` sets the GUC for the duration of the transaction
           # (equivalent to SET LOCAL) and — unlike SET LOCAL — accepts bind params.
           Ecto.Adapters.SQL.query!(
             __MODULE__,
             "SELECT set_config('app.current_tenant_id', $1, true)",
             [
               to_string(tenant_id)
             ]
           )

           Ecto.Adapters.SQL.query!(
             __MODULE__,
             "SELECT set_config('app.current_user_id', $1, true)",
             [
               to_string(user_id)
             ]
           )

           fun.()
         end) do
      {:ok, val} -> val
      {:error, _} = err -> err
    end
  end

  @doc """
  Store the active tenant/user pair for the current process (typically a
  LiveView or controller process) so that `scoped/1` can re-apply it as a
  PostgreSQL Row Level Security GUC for legacy context functions that were not
  written to call `with_tenant/3` directly (CATEGORY_REDESIGN.md §3.6 / §4.3).

  Values are coerced to strings so they bind cleanly when `scoped/1` forwards
  them to `with_tenant/3`.
  """
  def set_tenant_context(tenant_id, user_id) do
    Process.put(:beamchat_tenant_context, {to_string(tenant_id), to_string(user_id)})
  end

  @doc "Remove any tenant context stored for the current process."
  def clear_tenant_context do
    Process.delete(:beamchat_tenant_context)
  end

  @doc """
  Return the `{tenant_id, user_id}` pair previously stored via
  `set_tenant_context/2`, or `nil` if none is set.
  """
  def tenant_context do
    Process.get(:beamchat_tenant_context)
  end

  @doc """
  Run `fun` under the per-request tenant context.

  - When `tenant_context/0` is set (e.g. by `BeamChatWeb.TenantContext` for a
    LiveView/controller request), the function is executed inside
    `with_tenant/3` so PostgreSQL RLS sees the correct GUCs.
  - When no context is set, `fun` runs unchanged. This is the safe default for
    code that already opened its own `with_tenant/3` transaction (such as
    `RoomTreeLive`) or that intentionally runs unscoped (RLS default-deny).

  Nesting is harmless: a function wrapped in `scoped/1` that internally calls
  another `scoped/1`-wrapped function simply re-applies the same GUC inside a
  nested savepoint.
  """
  def scoped(fun) when is_function(fun, 0) do
    case tenant_context() do
      nil -> fun.()
      {tenant, user} -> with_tenant(tenant, user, fun)
    end
  end
end
