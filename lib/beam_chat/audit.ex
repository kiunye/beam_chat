defmodule BeamChat.Audit do
  @moduledoc """
  Append-only audit trail for privileged actions.

  Every privileged mutation — role changes, bans, manual wallet credits,
  room creation, membership changes — records who did what to which target,
  with enough metadata to reconstruct the decision afterwards.

  ## Semantics

    * `log/4` is a plain insert. Inside a caller's transaction it joins
      that transaction's atomicity (a banned user with no audit row, or an
      audit row for a ban that never happened, are equally bad); outside
      one it writes immediately. Failures propagate — an unread audit trail
      is worse than a failed privileged action, and the caller surfaces the
      error.
    * Rows are never updated or deleted. There is no API for it on purpose.
    * `actor` may be `nil` for system-triggered events.

  ## Example

      Audit.log(admin, "user.banned", user, %{reason: "spam"})
  """

  import Ecto.Query

  alias BeamChat.Audit.AuditLog
  alias BeamChat.Repo

  @doc """
  Record `action` performed by `actor` on `target`.

  `target` may be:

    * a struct — its id becomes `target_id` and its module name (underscored)
      becomes `target_type`; a `:tenant_id` field on the struct, if any, is
      recorded as `tenant_id`
    * `{type, id}` — for targets that are not schema structs
    * `nil` — for actions without a concrete target

  `metadata` is a free-form map stored as jsonb.
  """
  @spec log(struct() | nil, String.t(), struct() | {String.t(), term()} | nil, map()) ::
          {:ok, AuditLog.t()} | {:error, Ecto.Changeset.t()}
  def log(actor, action, target, metadata \\ %{}) do
    attrs =
      %{
        actor_id: id_of(actor),
        action: action,
        metadata: Map.new(metadata || %{})
      }
      |> Map.merge(target_attrs(target))

    %AuditLog{}
    |> AuditLog.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  The most recent audit rows, newest first, optionally filtered by action.
  For the future admin/compliance UI and for tests.
  """
  @spec list_recent(keyword()) :: [AuditLog.t()]
  def list_recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    action = Keyword.get(opts, :action)

    from(l in AuditLog, order_by: [desc: l.inserted_at, desc: l.id], limit: ^limit)
    |> filter_by_action(action)
    |> Repo.all()
  end

  defp filter_by_action(query, nil), do: query
  defp filter_by_action(query, action), do: where(query, [l], l.action == ^action)

  defp target_attrs(nil), do: %{}
  defp target_attrs({type, id}), do: %{target_type: type, target_id: to_string(id)}

  defp target_attrs(%_{} = struct) do
    attrs = %{target_type: target_type(struct), target_id: to_string(struct.id)}

    case Map.get(struct, :tenant_id) do
      nil -> attrs
      tenant_id -> Map.put(attrs, :tenant_id, tenant_id)
    end
  end

  defp target_attrs(other), do: %{target_type: "unknown", target_id: to_string(other)}

  defp id_of(nil), do: nil
  defp id_of(%{id: id}), do: id
  defp id_of(id) when is_binary(id), do: id

  defp target_type(%module{}) do
    module |> Module.split() |> List.last() |> Macro.underscore()
  end
end
