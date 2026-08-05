defmodule BeamChat.PaginationTest do
  use ExUnit.Case, async: true

  alias BeamChat.Pagination

  describe "normalize_limit/2" do
    test "passes integers through unchanged" do
      assert Pagination.normalize_limit(25, 50) == 25
    end

    test "clamps integers to a minimum of 1" do
      assert Pagination.normalize_limit(0, 50) == 1
      assert Pagination.normalize_limit(-5, 50) == 1
    end

    test "clamps integers to the maximum of 100" do
      assert Pagination.normalize_limit(500, 50) == 100
    end

    test "parses binary strings" do
      assert Pagination.normalize_limit("42", 50) == 42
      assert Pagination.normalize_limit("0", 50) == 1
    end

    test "falls back to the default for unparseable binaries" do
      assert Pagination.normalize_limit("abc", 50) == 50
    end

    test "falls back to the default for non-integer, non-binary values" do
      assert Pagination.normalize_limit(nil, 50) == 50
      assert Pagination.normalize_limit(:weird, 30) == 30
    end
  end

  describe "normalize_page/1" do
    test "passes positive integers through unchanged" do
      assert Pagination.normalize_page(3) == 3
    end

    test "clamps to a minimum of 1" do
      assert Pagination.normalize_page(0) == 1
      assert Pagination.normalize_page(-2) == 1
    end

    test "parses binary strings" do
      assert Pagination.normalize_page("7") == 7
    end

    test "falls back to 1 for unparseable or non-integer values" do
      assert Pagination.normalize_page("x") == 1
      assert Pagination.normalize_page(nil) == 1
    end
  end

  describe "page_count/2" do
    test "returns 1 for empty results" do
      assert Pagination.page_count(0, 25) == 1
    end

    test "uses ceil division for partial pages" do
      assert Pagination.page_count(25, 25) == 1
      assert Pagination.page_count(26, 25) == 2
      assert Pagination.page_count(49, 25) == 2
      assert Pagination.page_count(50, 25) == 2
      assert Pagination.page_count(51, 25) == 3
    end

    test "returns 1 when the limit is less than 1 (guard clause)" do
      assert Pagination.page_count(10, 0) == 1
    end
  end
end
