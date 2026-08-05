defmodule BeamChat.Pagination do
  @moduledoc """
  Shared server-side pagination helpers used by the Rooms and Direct contexts.
  """

  @max_limit 100

  @doc """
  Normalizes a page-size value to an integer in `1..@max_limit`.

  Integers are clamped; binary strings are parsed; anything else (including
  `nil`) falls back to `default`.
  """
  @spec normalize_limit(term(), pos_integer()) :: pos_integer()
  def normalize_limit(value, default) do
    value
    |> parse_int(default)
    |> clamp_limit()
  end

  @doc """
  Normalizes a page number to a positive integer (min 1, fallback 1).
  """
  @spec normalize_page(term()) :: pos_integer()
  def normalize_page(value) do
    value
    |> parse_int(1)
    |> max(1)
  end

  @doc """
  Total number of pages for `total` rows at `limit` per page (minimum 1).
  """
  @spec page_count(non_neg_integer(), pos_integer()) :: pos_integer()
  def page_count(_total, limit) when limit < 1, do: 1

  def page_count(total, limit) do
    max(1, div(total + limit - 1, limit))
  end

  defp parse_int(n, _default) when is_integer(n), do: n

  defp parse_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(_other, default), do: default

  defp clamp_limit(n), do: n |> max(1) |> min(@max_limit)
end
