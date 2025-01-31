defmodule Ecto.Repo.Preloader do
  # The module invoked by user defined repo_names
  # for preload related functionality.
  @moduledoc false

  require Ecto.Query

  @doc """
  Transforms a result set based on query preloads, loading
  the associations onto their parent schema.
  """
  @spec query([list], Ecto.Repo.t, list, Access.t, fun, Keyword.t) :: [list]
  def query([], _repo_name, _preloads, _take, _fun, _opts), do: []
  def query(rows, _repo_name, [], _take, fun, _opts), do: Enum.map(rows, fun)

  def query(rows, repo_name, preloads, take, fun, opts) do
    rows
    |> extract
    |> normalize_and_preload_each(repo_name, preloads, take, opts)
    |> unextract(rows, fun)
  end

  defp extract([[nil|_]|t2]), do: extract(t2)
  defp extract([[h|_]|t2]), do: [h|extract(t2)]
  defp extract([]), do: []

  defp unextract(structs, [[nil|_] = h2|t2], fun), do: [fun.(h2)|unextract(structs, t2, fun)]
  defp unextract([h1|structs], [[_|t1]|t2], fun), do: [fun.([h1|t1])|unextract(structs, t2, fun)]
  defp unextract([], [], _fun), do: []

  @doc """
  Implementation for `Ecto.Repo.preload/2`.
  """
  @spec preload(structs, atom, atom | list, Keyword.t) ::
                structs when structs: [Ecto.Schema.t] | Ecto.Schema.t | nil
  def preload(nil, _repo_name, _preloads, _opts) do
    nil
  end

  def preload(structs, repo_name, preloads, opts) when is_list(structs) do
    normalize_and_preload_each(structs, repo_name, preloads, opts[:take], opts)
  end

  def preload(struct, repo_name, preloads, opts) when is_map(struct) do
    normalize_and_preload_each([struct], repo_name, preloads, opts[:take], opts) |> hd()
  end

  defp normalize_and_preload_each(structs, repo_name, preloads, take, opts) do
    preloads = normalize(preloads, take, preloads)
    preload_each(structs, repo_name, preloads, opts)
  rescue
    e ->
      # Reraise errors so we ignore the preload inner stacktrace
      filter_and_reraise e, System.stacktrace
  end

  ## Preloading

  defp preload_each(structs, _repo_name, [], _opts),   do: structs
  defp preload_each([], _repo_name, _preloads, _opts), do: []
  defp preload_each(structs, repo_name, preloads, opts) do
    if sample = Enum.find(structs, & &1) do
      module = sample.__struct__
      prefix = preload_prefix(opts, sample)
      {assocs, throughs} = expand(module, preloads, {%{}, %{}})

      assocs =
        maybe_pmap Map.values(assocs), repo_name, opts, fn
          {{:assoc, assoc, related_key}, take, query, sub_preloads}, opts ->
            preload_assoc(structs, module, repo_name, prefix, assoc, related_key,
                          query, sub_preloads, take, opts)
        end

      throughs =
        Map.values(throughs)

      for struct <- structs do
        struct = Enum.reduce assocs, struct, &load_assoc/2
        struct = Enum.reduce throughs, struct, &load_through/2
        struct
      end
    else
      structs
    end
  end

  defp preload_prefix(opts, sample) do
    case Keyword.fetch(opts, :prefix) do
      {:ok, prefix} ->
        prefix
      :error ->
        %{__meta__: %{prefix: prefix}} = sample
        prefix
    end
  end

  ## Association preloading

  defp maybe_pmap(assocs, repo_name, opts, fun) do
    if match?([_,_|_], assocs) and not Ecto.Repo.Transaction.in_transaction?(repo_name) and
         Keyword.get(opts, :in_parallel, true) do
      # We pass caller: self() so pools like the ownership
      # pool knows where to fetch the connection from and
      # set the proper timeouts.
      # TODO: Remove this when we require Elixir v1.8+
      opts = Keyword.put_new(opts, :caller, self())
      assocs
      |> Task.async_stream(&fun.(&1, opts), timeout: :infinity)
      |> Enum.map(fn {:ok, assoc} -> assoc end)
    else
      Enum.map(assocs, &fun.(&1, opts))
    end
  end

  defp preload_assoc(structs, module, repo_name, prefix, %{cardinality: card} = assoc,
                     related_key, query, preloads, take, opts) do
    {fetch_ids, loaded_ids, loaded_structs} =
      fetch_ids(structs, module, assoc, opts)
    {fetch_ids, fetch_structs} =
      fetch_query(fetch_ids, assoc, repo_name, query, prefix, related_key, take, opts)

    all = preload_each(Enum.reverse(loaded_structs, fetch_structs), repo_name, preloads, opts)
    {:assoc, assoc, assoc_map(card, Enum.reverse(loaded_ids, fetch_ids), all)}
  end

  defp fetch_ids(structs, module, assoc, opts) do
    %{field: field, owner_key: owner_key, cardinality: card} = assoc
    force? = Keyword.get(opts, :force, false)

    Enum.reduce structs, {[], [], []}, fn
      nil, acc ->
        acc
      struct, {fetch_ids, loaded_ids, loaded_structs} ->
        assert_struct!(module, struct)
        %{^owner_key => id, ^field => value} = struct

        cond do
          card == :one and Ecto.assoc_loaded?(value) and not force? ->
            {fetch_ids, [id|loaded_ids], [value|loaded_structs]}
          card == :many and Ecto.assoc_loaded?(value) and not force? ->
            {fetch_ids,
             List.duplicate(id, length(value)) ++ loaded_ids,
             value ++ loaded_structs}
          is_nil(id) ->
            {fetch_ids, loaded_ids, loaded_structs}
          true ->
            {[id|fetch_ids], loaded_ids, loaded_structs}
        end
    end
  end

  defp fetch_query([], _assoc, _repo_name, _query, _prefix, _related_key, _take, _opts) do
    {[], []}
  end

  defp fetch_query(ids, assoc, _repo_name, query, _prefix, related_key, _take, _opts) when is_function(query, 1) do
    # Note we use an explicit sort because we don't want
    # to reorder based on the struct. Only the ID.
    ids
    |> Enum.uniq
    |> query.()
    |> fetched_records_to_tuple_ids(assoc, related_key)
    |> Enum.sort(fn {id1, _}, {id2, _} -> id1 <= id2 end)
    |> unzip_ids([], [])
  end

  defp fetch_query(ids, %{cardinality: card} = assoc, repo_name, query, prefix, related_key, take, opts) do
    query = assoc.__struct__.assoc_query(assoc, query, Enum.uniq(ids))
    field = related_key_to_field(query, related_key)

    # Normalize query
    query = %{Ecto.Query.Planner.ensure_select(query, take || true) | prefix: prefix}

    # Add the related key to the query results
    query = update_in query.select.expr, &{:{}, [], [field, &1]}

    # If we are returning many results, we must sort by the key too
    query =
      case card do
        :many ->
          if Enum.empty?(query.order_bys) do
            update_in query.order_bys, fn order_bys ->
              [%Ecto.Query.QueryExpr{expr: [asc: field], params: [],
                                    file: __ENV__.file, line: __ENV__.line}|order_bys]
            end
          else
            query
          end
        :one ->
          query
      end

    unzip_ids Ecto.Repo.Queryable.all(repo_name, query, opts), [], []
  end

  defp fetched_records_to_tuple_ids([], _assoc, _related_key),
    do: []

  defp fetched_records_to_tuple_ids([%{} | _] = entries, _assoc, {0, key}),
    do: Enum.map(entries, &{Map.fetch!(&1, key), &1})

  defp fetched_records_to_tuple_ids([{_, %{}} | _] = entries, _assoc, _related_key),
    do: entries

  defp fetched_records_to_tuple_ids([entry | _], assoc, _),
    do: raise """
    invalid custom preload for `#{assoc.field}` on `#{inspect assoc.owner}`.

    For many_to_many associations, the custom function given to preload should \
    return a tuple with the associated key as first element and the record as \
    second element.

    For example, imagine posts has many to many tags through a posts_tags table. \
    When preloading the tags, you may write:

        custom_tags = fn post_ids ->
          Repo.all(
            from t in Tag,
                 join: pt in "posts_tags",
                 where: t.custom and pt.post_id in ^post_ids and pt.tag_id == t.id
          )
        end

        from Post, preload: [tags: ^custom_tags]

    Unfortunately the query above is not enough because Ecto won't know how to \
    associate the posts with the tags. In those cases, you need to return a tuple \
    with the `post_id` as first element and the tag record as second. The new query \
    will have a select field as follows:

        from t in Tag,
             join: pt in "posts_tags",
             where: t.custom and pt.post_id in ^post_ids and pt.tag_id == t.id,
             select: {pt.post_id, t}

    We expected a tuple but we got: #{inspect(entry)}
    """

  defp related_key_to_field(query, {pos, key}) do
    {{:., [], [{:&, [], [related_key_pos(query, pos)]}, key]}, [], []}
  end

  defp related_key_pos(_query, pos) when pos >= 0, do: pos
  defp related_key_pos(query, pos), do: Ecto.Query.Builder.count_binds(query) + pos

  defp unzip_ids([{k, v}|t], acc1, acc2), do: unzip_ids(t, [k|acc1], [v|acc2])
  defp unzip_ids([], acc1, acc2), do: {acc1, acc2}

  defp assert_struct!(mod, %{__struct__: mod}), do: true
  defp assert_struct!(mod, %{__struct__: struct}) do
    raise ArgumentError, "expected a homogeneous list containing the same struct, " <>
                         "got: #{inspect mod} and #{inspect struct}"
  end

  defp assoc_map(:one, ids, structs) do
    one_assoc_map(ids, structs, %{})
  end
  defp assoc_map(:many, ids, structs) do
    many_assoc_map(ids, structs, %{})
  end

  defp one_assoc_map([id|ids], [struct|structs], map) do
    one_assoc_map(ids, structs, Map.put(map, id, struct))
  end
  defp one_assoc_map([], [], map) do
    map
  end

  defp many_assoc_map([id|ids], [struct|structs], map) do
    {ids, structs, acc} = split_while(ids, structs, id, [struct])
    many_assoc_map(ids, structs, Map.put(map, id, acc))
  end
  defp many_assoc_map([], [], map) do
    map
  end

  defp split_while([id|ids], [struct|structs], id, acc),
    do: split_while(ids, structs, id, [struct|acc])
  defp split_while(ids, structs, _id, acc),
    do: {ids, structs, acc}

  ## Load preloaded data

  defp load_assoc({:assoc, _assoc, _ids}, nil) do
    nil
  end

  defp load_assoc({:assoc, assoc, ids}, struct) do
    %{field: field, owner_key: owner_key, cardinality: cardinality} = assoc
    key = Map.fetch!(struct, owner_key)

    loaded =
      case ids do
        %{^key => value} -> value
        _ when cardinality == :many -> []
        _ -> nil
      end

    Map.put(struct, field, loaded)
  end

  defp load_through({:through, assoc, throughs}, struct) do
    %{cardinality: cardinality, field: field, owner: owner} = assoc
    {loaded, _} = Enum.reduce(throughs, {[struct], owner}, &recur_through/2)
    Map.put(struct, field, maybe_first(loaded, cardinality))
  end

  defp maybe_first(list, :one), do: List.first(list)
  defp maybe_first(list, _), do: list

  defp recur_through(field, {structs, owner}) do
    assoc = owner.__schema__(:association, field)
    case assoc.__struct__.preload_info(assoc) do
      {:assoc, %{related: related}, _} ->
        pk_fields =
          related.__schema__(:primary_key)
          |> validate_has_pk_field!(related, assoc)

        {children, _} =
          Enum.reduce(structs, {[], %{}}, fn struct, acc ->
            struct
            |> Map.fetch!(field)
            |> List.wrap()
            |> Enum.reduce(acc, fn child, {fresh, set} ->
              pk_values =
                child
                |> through_pks(pk_fields, assoc)
                |> validate_non_null_pk!(child, pk_fields, assoc)

              case set do
                %{^pk_values => true} ->
                  {fresh, set}
                _ ->
                  {[child|fresh], Map.put(set, pk_values, true)}
              end
            end)
          end)

        {Enum.reverse(children), related}

      {:through, _, through} ->
        Enum.reduce(through, {structs, owner}, &recur_through/2)
    end
  end

  defp validate_has_pk_field!([], related, assoc) do
    raise ArgumentError,
          "cannot preload through association `#{assoc.field}` on " <>
            "`#{inspect assoc.owner}`. Ecto expected the #{inspect related} schema " <>
            "to have at least one primary key field"
  end

  defp validate_has_pk_field!(pk_fields, _related, _assoc), do: pk_fields

  defp through_pks(map, pks, assoc) do
    Enum.map(pks, fn pk ->
      case map do
        %{^pk => value} ->
          value

        _ ->
          raise ArgumentError,
               "cannot preload through association `#{assoc.field}` on " <>
                 "`#{inspect assoc.owner}`. Ecto expected a map/struct with " <>
                 "the key `#{pk}` but got: #{inspect map}"
      end
    end)
  end

  defp validate_non_null_pk!(values, map, pks, assoc) do
    case values do
      [nil | _] ->
        raise ArgumentError,
              "cannot preload through association `#{assoc.field}` on " <>
                "`#{inspect assoc.owner}` because the primary key `#{hd(pks)}` " <>
                "is nil for map/struct: #{inspect map}"

      _ ->
        values
    end
  end

  ## Normalizer

  def normalize(preload, take, original) do
    normalize_each(wrap(preload, original), [], take, original)
  end

  defp normalize_each({atom, {query, list}}, acc, take, original)
       when is_atom(atom) and (is_map(query) or is_function(query, 1)) do
    fields = take(take, atom)
    [{atom, {fields, query!(query), normalize_each(wrap(list, original), [], fields, original)}}|acc]
  end

  defp normalize_each({atom, query}, acc, take, _original)
       when is_atom(atom) and (is_map(query) or is_function(query, 1)) do
    [{atom, {take(take, atom), query!(query), []}}|acc]
  end

  defp normalize_each({atom, list}, acc, take, original) when is_atom(atom) do
    fields = take(take, atom)
    [{atom, {fields, nil, normalize_each(wrap(list, original), [], fields, original)}}|acc]
  end

  defp normalize_each(atom, acc, take, _original) when is_atom(atom) do
    [{atom, {take(take, atom), nil, []}}|acc]
  end

  defp normalize_each(other, acc, take, original) do
    Enum.reduce(wrap(other, original), acc, &normalize_each(&1, &2, take, original))
  end

  defp query!(query) when is_function(query, 1), do: query
  defp query!(%Ecto.Query{} = query), do: query

  defp take(take, field) do
    case Access.fetch(take, field) do
      {:ok, fields} -> List.wrap(fields)
      :error -> nil
    end
  end

  defp wrap(list, _original) when is_list(list),
    do: list
  defp wrap(atom, _original) when is_atom(atom),
    do: atom
  defp wrap(other, original) do
    raise ArgumentError, "invalid preload `#{inspect other}` in `#{inspect original}`. " <>
                         "preload expects an atom, a (nested) keyword or a (nested) list of atoms"
  end

  ## Expand

  def expand(schema, preloads, acc) do
    Enum.reduce(preloads, acc, fn {preload, {fields, query, sub_preloads}}, {assocs, throughs} ->
      assoc = association_from_schema!(schema, preload)
      info  = assoc.__struct__.preload_info(assoc)

      case info do
        {:assoc, _, _} ->
          value  = {info, fields, query, sub_preloads}
          assocs = Map.update(assocs, preload, value, &merge_preloads(preload, value, &1))
          {assocs, throughs}
        {:through, _, through} ->
          through =
            through
            |> Enum.reverse()
            |> Enum.reduce({fields, query, sub_preloads}, &{nil, nil, [{&1, &2}]})
            |> elem(2)
          expand(schema, through, {assocs, Map.put(throughs, preload, info)})
      end
    end)
  end

  defp merge_preloads(_preload, {info, _, nil, left}, {info, take, query, right}),
    do: {info, take, query, left ++ right}
  defp merge_preloads(_preload, {info, take, query, left}, {info, _, nil, right}),
    do: {info, take, query, left ++ right}
  defp merge_preloads(preload, {info, _, left, _}, {info, _, right, _}) do
    raise ArgumentError, "cannot preload `#{preload}` as it has been supplied more than once " <>
                         "with different queries: #{inspect left} and #{inspect right}"
  end

  # Since there is some ambiguity between assoc and queries.
  # We reimplement this function here for nice error messages.
  defp association_from_schema!(schema, assoc) do
    schema.__schema__(:association, assoc) ||
      raise ArgumentError,
            "schema #{inspect schema} does not have association #{inspect assoc}#{maybe_module(assoc)}"
  end

  defp maybe_module(assoc) do
    case Atom.to_string(assoc) do
      "Elixir." <> _ ->
        " (if you were trying to pass a schema as a query to preload, " <>
          "you have to explicitly convert it to a query by doing `from x in #{inspect assoc}` " <>
          "or by calling Ecto.Queryable.to_query/1)"

      _ ->
        ""
    end
  end

  defp filter_and_reraise(exception, stacktrace) do
    reraise exception, Enum.reject(stacktrace, &match?({__MODULE__, _, _, _}, &1))
  end
end
