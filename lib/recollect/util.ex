defmodule Recollect.Util do
  @moduledoc false

  @doc false
  def uuid_to_bin(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, bin} -> bin
      :error -> id
    end
  end

  @doc false
  def uuid_to_bin(id) when byte_size(id) == 16, do: id
  def uuid_to_bin(nil), do: nil

  @doc false
  # Inverse of uuid_to_bin/1 for Ecto-bound params: schema-typed queries
  # (:binary_id) want string UUIDs, while raw SQL rows hand back 16-byte
  # binaries. Accepts either and returns the string form.
  def uuid_to_string(<<_::128>> = bin), do: Ecto.UUID.load!(bin)
  def uuid_to_string(id) when is_binary(id), do: id
  def uuid_to_string(nil), do: nil

  @doc false
  def row_to_map(columns, row) do
    columns |> Enum.zip(row) |> Map.new()
  end

  @doc false
  def text_overlap(a, b) do
    set_a = tokenize(a)
    set_b = tokenize(b)

    if MapSet.size(set_a) == 0 and MapSet.size(set_b) == 0 do
      1.0
    else
      jaccard(set_a, set_b)
    end
  end

  @doc false
  def tokenize(text, min_length \\ 1) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split()
    |> Enum.filter(fn t -> String.length(t) > min_length end)
    |> MapSet.new()
  end

  @doc false
  def jaccard(set_a, set_b) when is_list(set_a) and is_list(set_b) do
    jaccard(MapSet.new(set_a), MapSet.new(set_b))
  end

  def jaccard(set_a, set_b) do
    intersection = MapSet.size(MapSet.intersection(set_a, set_b))
    union = MapSet.size(MapSet.union(set_a, set_b))

    if union == 0, do: 1.0, else: intersection / union
  end
end
