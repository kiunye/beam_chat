defmodule BeamChat.Categories do
  @moduledoc """
  The admin-managed category/subcategory tree (PRD §2.3, §2.4, §2.8).

  Categories are a navigation structure, not an access boundary: every
  authenticated user sees them, except categories an admin has hidden,
  which only platform admins and moderators see. Rooms hang off tree
  nodes; the tree knows nothing about rooms.
  """

  import Ecto.Query

  alias BeamChat.Accounts.User
  alias BeamChat.Authorization
  alias BeamChat.Authorization.Scope
  alias BeamChat.Categories.Category
  alias BeamChat.Repo

  @type tree_node :: %{
          category: Category.t(),
          children: [tree_node()]
        }

  ## Reads

  @doc """
  The full tree, nested, for admin tooling (includes hidden categories).
  Ordered by `position`, then `name`.
  """
  @spec tree() :: [tree_node()]
  def tree do
    categories =
      from(c in Category,
        order_by: [asc: c.position, asc: c.name],
        preload: [:parent]
      )
      |> Repo.all()

    build_tree(categories, nil)
  end

  @doc """
  The browsing tree for `user`: hidden categories and their subtrees are
  visible only to platform admins and moderators (PRD §2.3).
  """
  @spec visible_tree(User.t() | nil) :: [tree_node()]
  def visible_tree(%User{} = user) do
    scope = Scope.for_user(user)

    if Authorization.can?(scope, :structure_manage) do
      tree()
    else
      tree() |> drop_hidden([])
    end
  end

  def visible_tree(nil), do: []

  # A hidden node removes itself and everything below it; hidden ancestors
  # never leak visible descendants.
  defp drop_hidden([], acc), do: Enum.reverse(acc)

  defp drop_hidden([%{category: %Category{is_hidden: true}} | rest], acc),
    do: drop_hidden(rest, acc)

  defp drop_hidden([%{children: children} = node | rest], acc),
    do: drop_hidden(rest, [%{node | children: drop_hidden(children, [])} | acc])

  @doc "Every category as a flat list (admin view, hidden included)."
  @spec list_categories() :: [Category.t()]
  def list_categories do
    from(c in Category, order_by: [asc: c.position, asc: c.name], preload: [:parent])
    |> Repo.all()
  end

  @doc "Categories visible to `user` as a flat list, parents-first (pre-order)."
  @spec list_visible(User.t() | nil) :: [Category.t()]
  def list_visible(%User{} = user) do
    visible_tree(user) |> Enum.flat_map(&flatten_node/1)
  end

  def list_visible(nil), do: []

  defp flatten_node(%{category: category, children: children}) do
    [category | Enum.flat_map(children, &flatten_node/1)]
  end

  @doc "Raises if the category does not exist."
  @spec get_category!(Ecto.UUID.t()) :: Category.t()
  def get_category!(id), do: Repo.get!(Category, id)

  @spec get_category(Ecto.UUID.t()) :: Category.t() | nil
  def get_category(id), do: Repo.get(Category, id)

  @doc "The breadcrumb path from the root down to `category`, inclusive."
  @spec path(Category.t() | Ecto.UUID.t()) :: [Category.t()]
  def path(%Category{} = category), do: walk_path(category, [])

  def path(id) when is_binary(id), do: path(get_category!(id))

  defp walk_path(%Category{parent_id: nil} = category, acc), do: [category | acc]

  defp walk_path(%Category{parent_id: parent_id} = category, acc) when is_binary(parent_id) do
    walk_path(Repo.get!(Category, parent_id), [category | acc])
  end

  ## Mutations (admin-only, PRD §2.8)

  @doc """
  Creates a root or sub category. `parent_id` may be `nil` (top-level).

  Permission `:structure_manage` is enforced by the caller surface
  (Settings); this function is the trusted context entry point.
  """
  @spec create_category(map()) :: {:ok, Category.t()} | {:error, Ecto.Changeset.t()}
  def create_category(attrs) do
    %Category{}
    |> Category.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Renames, re-describes, reorders, or toggles hidden."
  @spec update_category(Category.t(), map()) :: {:ok, Category.t()} | {:error, Ecto.Changeset.t()}
  def update_category(%Category{} = category, attrs) do
    category
    |> Category.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Reparents `category` under `new_parent_id` (`nil` promotes it to a root).

  A cycle guard blocks a category from becoming its own ancestor: the new
  parent's ancestor chain is walked to the root and the move is refused if
  `category` appears anywhere in it (PRD §2.4).
  """
  @spec reparent(Category.t(), Ecto.UUID.t() | nil) ::
          {:ok, Category.t()} | {:error, :cycle | Ecto.Changeset.t()}
  def reparent(%Category{id: id} = category, new_parent_id) do
    cond do
      new_parent_id == id ->
        {:error, :cycle}

      new_parent_id != nil and ancestor_of?(id, new_parent_id) ->
        {:error, :cycle}

      true ->
        category
        |> Category.reparent_changeset(%{parent_id: new_parent_id})
        |> Repo.update()
    end
  end

  # Is `maybe_descendant_id` an ancestor of (or equal to) `node_id`?
  # Walks up from `node_id` to the root.
  defp ancestor_of?(maybe_descendant_id, node_id) do
    node_id
    |> ancestor_ids()
    |> MapSet.new()
    |> MapSet.member?(maybe_descendant_id)
  end

  defp ancestor_ids(node_id) do
    node_id
    |> walk_ancestors([])
  end

  defp walk_ancestors(nil, acc), do: acc

  defp walk_ancestors(node_id, acc) do
    case Repo.get(Category, node_id) do
      nil -> acc
      %Category{parent_id: nil} -> acc
      %Category{parent_id: parent_id} -> walk_ancestors(parent_id, [parent_id | acc])
    end
  end

  ## Tree building

  defp build_tree(categories, parent_id) do
    categories
    |> Enum.filter(&(&1.parent_id == parent_id))
    |> Enum.map(fn category ->
      %{category: category, children: build_tree(categories, category.id)}
    end)
  end
end
