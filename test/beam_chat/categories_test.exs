defmodule BeamChat.CategoriesTest do
  @moduledoc """
  The admin-managed category tree (PRD §2.3, §2.4, §2.8): nesting, the
  visibility filter, breadcrumbs, reparenting with cycle protection, and
  slug derivation.
  """

  use BeamChat.DataCase, async: true

  alias BeamChat.Categories
  alias BeamChat.Categories.Category

  describe "tree/0 and visible_tree/1" do
    test "tree/0 nests root, child, and grandchild" do
      root = category_fixture()
      child = category_fixture(parent_id: root.id)
      grandchild = category_fixture(parent_id: child.id)

      tree = Categories.tree()

      root_node = Enum.find(tree, &(&1.category.id == root.id))
      refute is_nil(root_node)

      child_node = Enum.find(root_node.children, &(&1.category.id == child.id))
      refute is_nil(child_node)

      grandchild_node = Enum.find(child_node.children, &(&1.category.id == grandchild.id))
      refute is_nil(grandchild_node)
    end

    test "visible_tree hides hidden categories and their whole subtrees from members" do
      root = category_fixture()
      visible_child = category_fixture(parent_id: root.id)
      hidden_child = category_fixture(parent_id: root.id, is_hidden: true)
      hidden_grandchild = category_fixture(parent_id: hidden_child.id)

      member_ids = visible_ids(user_fixture())

      assert root.id in member_ids
      assert visible_child.id in member_ids
      refute hidden_child.id in member_ids
      # a hidden ancestor never leaks visible descendants
      refute hidden_grandchild.id in member_ids
    end

    test "visible_tree keeps hidden categories for admins (moderators see the member view)" do
      root = category_fixture()
      hidden_child = category_fixture(parent_id: root.id, is_hidden: true)
      hidden_grandchild = category_fixture(parent_id: hidden_child.id)

      admin_ids = visible_ids(admin_fixture())
      assert root.id in admin_ids
      assert hidden_child.id in admin_ids
      assert hidden_grandchild.id in admin_ids

      # NOTE: the Categories moduledoc claims hidden nodes are visible to
      # "platform admins and moderators", but visible_tree/1 gates on the
      # :structure_manage permission, which Roles grants to admins only.
      # This asserts the implemented behavior.
      moderator_ids = visible_ids(moderator_fixture())
      refute hidden_child.id in moderator_ids
    end

    test "visible_tree(nil) is empty" do
      assert Categories.visible_tree(nil) == []
    end

    test "list_visible/1 returns a flat, parent-first list" do
      root = category_fixture()
      visible_child = category_fixture(parent_id: root.id)
      visible_grandchild = category_fixture(parent_id: visible_child.id)
      hidden_child = category_fixture(parent_id: root.id, is_hidden: true)

      member_ids = Categories.list_visible(user_fixture()) |> Enum.map(& &1.id)

      # parents come before children; hidden nodes are dropped for members
      assert Enum.at(member_ids, 0) == root.id

      assert Enum.sort(member_ids) ==
               Enum.sort([root.id, visible_child.id, visible_grandchild.id])

      admin_ids = Categories.list_visible(admin_fixture()) |> Enum.map(& &1.id)

      assert Enum.sort(admin_ids) ==
               Enum.sort([root.id, visible_child.id, visible_grandchild.id, hidden_child.id])

      assert Categories.list_visible(nil) == []
    end
  end

  describe "path/1" do
    test "returns the breadcrumb from the root down to the node" do
      root = category_fixture()
      child = category_fixture(parent_id: root.id)
      grandchild = category_fixture(parent_id: child.id)

      assert Enum.map(Categories.path(grandchild), & &1.id) == [root.id, child.id, grandchild.id]
      assert Enum.map(Categories.path(child), & &1.id) == [root.id, child.id]
      assert Enum.map(Categories.path(root), & &1.id) == [root.id]

      # by id as well as by struct
      assert Enum.map(Categories.path(grandchild.id), & &1.id) == [
               root.id,
               child.id,
               grandchild.id
             ]
    end
  end

  describe "reparent/2" do
    test "refuses to move a category under its own descendant, or itself" do
      root_a = category_fixture()
      _root_b = category_fixture()
      child = category_fixture(parent_id: root_a.id)
      grandchild = category_fixture(parent_id: child.id)

      # A is an ancestor of C: reparenting A under C would create a cycle.
      assert {:error, :cycle} = Categories.reparent(root_a, grandchild.id)
      assert {:error, :cycle} = Categories.reparent(child, child.id)

      # the tree is unchanged after the refusals
      assert Enum.map(Categories.path(grandchild), & &1.id) == [
               root_a.id,
               child.id,
               grandchild.id
             ]
    end

    test "moves a subtree under another root and keeps descendants attached" do
      root_a = category_fixture()
      root_b = category_fixture()
      child = category_fixture(parent_id: root_a.id)
      grandchild = category_fixture(parent_id: child.id)

      assert {:ok, moved} = Categories.reparent(child, root_b.id)
      assert moved.parent_id == root_b.id

      # the grandchild moved along with the subtree
      assert Enum.map(Categories.path(grandchild), & &1.id) == [
               root_b.id,
               child.id,
               grandchild.id
             ]
    end

    test "reparenting to nil promotes the category to a root" do
      root = category_fixture()
      child = category_fixture(parent_id: root.id)
      grandchild = category_fixture(parent_id: child.id)

      assert {:ok, promoted} = Categories.reparent(child, nil)
      assert is_nil(promoted.parent_id)

      assert Enum.map(Categories.path(grandchild), & &1.id) == [child.id, grandchild.id]
    end
  end

  describe "update_category/2" do
    test "renames, re-describes, reorders, and toggles hidden" do
      category = category_fixture()

      assert {:ok, updated} =
               Categories.update_category(category, %{
                 name: "Renamed",
                 description: "fresh description",
                 position: 7,
                 is_hidden: true
               })

      assert updated.name == "Renamed"
      assert updated.description == "fresh description"
      assert updated.position == 7
      assert updated.is_hidden

      reloaded = Categories.get_category!(category.id)
      assert reloaded.description == "fresh description"
      assert reloaded.is_hidden
    end

    test "rejects a blank name" do
      category = category_fixture()

      assert {:error, changeset} = Categories.update_category(category, %{name: ""})
      assert_error_message(changeset, :name, "can't be blank")
    end
  end

  describe "slugs" do
    # DEFECT (lib, reported in the test run summary): Category.changeset/2
    # runs validate_required([:name, :slug]) *before* put_slug/1 derives a
    # slug from the name, so slug-less creation is rejected even though
    # put_slug puts the derived slug into the changes. This documents the
    # behavior as implemented; the fix is to derive before validating.
    test "slug-less creation is currently rejected despite put_slug deriving one" do
      assert {:error, changeset} = Categories.create_category(%{name: "Events & Music"})
      assert_error_message(changeset, :slug, "can't be blank")
    end

    test "an explicit slug is normalized (downcased, hyphenated, trimmed)" do
      assert {:ok, %Category{slug: "events-music"}} =
               Categories.create_category(%{name: "Events", slug: " Events & Music "})
    end

    test "must be unique" do
      assert {:ok, _first} = Categories.create_category(%{name: "One", slug: "taken-slug"})

      assert {:error, changeset} = Categories.create_category(%{name: "Two", slug: "taken-slug"})
      assert_error_message(changeset, :slug, "has already been taken")
    end
  end

  # Flattens a visible tree into the ids of every visible category.
  defp visible_ids(user) do
    user
    |> Categories.visible_tree()
    |> tree_ids()
  end

  defp tree_ids(nodes) do
    Enum.flat_map(nodes, fn %{category: category, children: children} ->
      [category.id | tree_ids(children)]
    end)
  end

  defp assert_error_message(changeset, field, message) do
    assert Enum.any?(changeset.errors, fn {error_field, {error_message, _details}} ->
             error_field == field and error_message == message
           end),
           "expected an error on #{inspect(field)} with message #{inspect(message)}, got: #{inspect(changeset.errors)}"
  end
end
