Code.require_file("../deps/ecto/integration_test/support/types.exs", __DIR__)

defmodule RedshiftEctoTest do
  use ExUnit.Case

  import Ecto.Query

  alias Ecto.Queryable
  alias RedshiftEcto.Connection, as: SQL

  defmodule Schema do
    use Ecto.Schema

    schema "schema" do
      field(:x, :integer)
      field(:y, :integer)
      field(:z, :integer)

      has_many(
        :comments,
        RedshiftEctoTest.Schema2,
        references: :x,
        foreign_key: :z
      )

      has_one(
        :permalink,
        RedshiftEctoTest.Schema3,
        references: :y,
        foreign_key: :id
      )
    end
  end

  defmodule Schema2 do
    use Ecto.Schema

    schema "schema2" do
      belongs_to(
        :post,
        RedshiftEctoTest.Schema,
        references: :x,
        foreign_key: :z
      )
    end
  end

  defmodule Schema3 do
    use Ecto.Schema

    schema "schema3" do
      field(:binary, :binary)
    end
  end

  defp normalize(query, operation \\ :all, counter \\ 0) do
    {query, _params, _key} = Ecto.Query.Planner.plan(query, operation, RedshiftEcto)
    {query, _} = Ecto.Query.Planner.normalize(query, operation, RedshiftEcto, counter)
    query
  end

  defp all(query), do: query |> SQL.all() |> IO.iodata_to_binary()
  defp update_all(query), do: query |> SQL.update_all() |> IO.iodata_to_binary()
  defp delete_all(query), do: query |> SQL.delete_all() |> IO.iodata_to_binary()
  defp execute_ddl(query), do: query |> SQL.execute_ddl() |> Enum.map(&IO.iodata_to_binary/1)

  defp insert(prefx, table, header, rows, on_conflict, returning) do
    IO.iodata_to_binary(SQL.insert(prefx, table, header, rows, on_conflict, returning))
  end

  defp update(prefx, table, fields, filter, returning) do
    IO.iodata_to_binary(SQL.update(prefx, table, fields, filter, returning))
  end

  defp delete(prefx, table, filter, returning) do
    IO.iodata_to_binary(SQL.delete(prefx, table, filter, returning))
  end

  test "from" do
    query = Schema |> select([r], r.x) |> normalize
    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0}
  end

  test "from without schema" do
    query = "posts" |> select([r], r.x) |> normalize
    assert all(query) == ~s{SELECT p0."x" FROM "posts" AS p0}

    query = "Posts" |> select([:x]) |> normalize
    assert all(query) == ~s{SELECT P0."x" FROM "Posts" AS P0}

    query = "0posts" |> select([:x]) |> normalize
    assert all(query) == ~s{SELECT t0."x" FROM "0posts" AS t0}

    assert_raise Ecto.QueryError,
                 ~r"Redshift does not support selecting all fields from \"posts\" without a schema",
                 fn ->
                   all(from(p in "posts", select: p) |> normalize())
                 end
  end

  test "from with subquery" do
    query = subquery("posts" |> select([r], %{x: r.x, y: r.y})) |> select([r], r.x) |> normalize

    assert all(query) ==
             ~s{SELECT s0."x" FROM (SELECT p0."x" AS "x", p0."y" AS "y" FROM "posts" AS p0) AS s0}

    query = subquery("posts" |> select([r], %{x: r.x, z: r.y})) |> select([r], r) |> normalize

    assert all(query) ==
             ~s{SELECT s0."x", s0."z" FROM (SELECT p0."x" AS "x", p0."y" AS "z" FROM "posts" AS p0) AS s0}
  end

  test "select" do
    query = Schema |> select([r], {r.x, r.y}) |> normalize
    assert all(query) == ~s{SELECT s0."x", s0."y" FROM "schema" AS s0}

    query = Schema |> select([r], [r.x, r.y]) |> normalize
    assert all(query) == ~s{SELECT s0."x", s0."y" FROM "schema" AS s0}

    query = Schema |> select([r], struct(r, [:x, :y])) |> normalize
    assert all(query) == ~s{SELECT s0."x", s0."y" FROM "schema" AS s0}
  end

  test "aggregates" do
    query = Schema |> select([r], count(r.x)) |> normalize
    assert all(query) == ~s{SELECT count(s0."x") FROM "schema" AS s0}

    query = Schema |> select([r], count(r.x, :distinct)) |> normalize
    assert all(query) == ~s{SELECT count(DISTINCT s0."x") FROM "schema" AS s0}
  end

  test "distinct" do
    query = Schema |> distinct([r], r.x) |> select([r], {r.x, r.y}) |> normalize
    assert all(query) == ~s{SELECT DISTINCT ON (s0."x") s0."x", s0."y" FROM "schema" AS s0}

    query = Schema |> distinct([r], desc: r.x) |> select([r], {r.x, r.y}) |> normalize
    assert all(query) == ~s{SELECT DISTINCT ON (s0."x") s0."x", s0."y" FROM "schema" AS s0}

    query = Schema |> distinct([r], 2) |> select([r], r.x) |> normalize
    assert all(query) == ~s{SELECT DISTINCT ON (2) s0."x" FROM "schema" AS s0}

    query = Schema |> distinct([r], [r.x, r.y]) |> select([r], {r.x, r.y}) |> normalize

    assert all(query) ==
             ~s{SELECT DISTINCT ON (s0."x", s0."y") s0."x", s0."y" FROM "schema" AS s0}

    query = Schema |> distinct([r], true) |> select([r], {r.x, r.y}) |> normalize
    assert all(query) == ~s{SELECT DISTINCT s0."x", s0."y" FROM "schema" AS s0}

    query = Schema |> distinct([r], false) |> select([r], {r.x, r.y}) |> normalize
    assert all(query) == ~s{SELECT s0."x", s0."y" FROM "schema" AS s0}

    query = Schema |> distinct(true) |> select([r], {r.x, r.y}) |> normalize
    assert all(query) == ~s{SELECT DISTINCT s0."x", s0."y" FROM "schema" AS s0}

    query = Schema |> distinct(false) |> select([r], {r.x, r.y}) |> normalize
    assert all(query) == ~s{SELECT s0."x", s0."y" FROM "schema" AS s0}
  end

  test "distinct with order by" do
    query =
      Schema |> order_by([r], [r.y]) |> distinct([r], desc: r.x) |> select([r], r.x) |> normalize

    assert all(query) ==
             ~s{SELECT DISTINCT ON (s0."x") s0."x" FROM "schema" AS s0 ORDER BY s0."x" DESC, s0."y"}
  end

  test "where" do
    query =
      Schema |> where([r], r.x == 42) |> where([r], r.y != 43) |> select([r], r.x) |> normalize

    assert all(query) ==
             ~s{SELECT s0."x" FROM "schema" AS s0 WHERE (s0."x" = 42) AND (s0."y" != 43)}
  end

  test "or_where" do
    query =
      Schema
      |> or_where([r], r.x == 42)
      |> or_where([r], r.y != 43)
      |> select([r], r.x)
      |> normalize

    assert all(query) ==
             ~s{SELECT s0."x" FROM "schema" AS s0 WHERE (s0."x" = 42) OR (s0."y" != 43)}

    query =
      Schema
      |> or_where([r], r.x == 42)
      |> or_where([r], r.y != 43)
      |> where([r], r.z == 44)
      |> select([r], r.x)
      |> normalize

    assert all(query) ==
             ~s{SELECT s0."x" FROM "schema" AS s0 WHERE ((s0."x" = 42) OR (s0."y" != 43)) AND (s0."z" = 44)}
  end

  test "order by" do
    query = Schema |> order_by([r], r.x) |> select([r], r.x) |> normalize
    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0 ORDER BY s0."x"}

    query = Schema |> order_by([r], [r.x, r.y]) |> select([r], r.x) |> normalize
    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0 ORDER BY s0."x", s0."y"}

    query = Schema |> order_by([r], asc: r.x, desc: r.y) |> select([r], r.x) |> normalize
    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0 ORDER BY s0."x", s0."y" DESC}

    query = Schema |> order_by([r], []) |> select([r], r.x) |> normalize
    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0}
  end

  test "limit and offset" do
    query = Schema |> limit([r], 3) |> select([], true) |> normalize
    assert all(query) == ~s{SELECT TRUE FROM "schema" AS s0 LIMIT 3}

    query = Schema |> offset([r], 5) |> select([], true) |> normalize
    assert all(query) == ~s{SELECT TRUE FROM "schema" AS s0 OFFSET 5}

    query = Schema |> offset([r], 5) |> limit([r], 3) |> select([], true) |> normalize
    assert all(query) == ~s{SELECT TRUE FROM "schema" AS s0 LIMIT 3 OFFSET 5}
  end

  test "lock" do
    query = Schema |> lock("FOR SHARE NOWAIT") |> select([], true) |> normalize
    assert all(query) == ~s{SELECT TRUE FROM "schema" AS s0 FOR SHARE NOWAIT}
  end

  test "string escape" do
    query = "schema" |> where(foo: "'\\  ") |> select([], true) |> normalize
    assert all(query) == ~s{SELECT TRUE FROM \"schema\" AS s0 WHERE (s0.\"foo\" = '''\\  ')}

    query = "schema" |> where(foo: "'") |> select([], true) |> normalize
    assert all(query) == ~s{SELECT TRUE FROM "schema" AS s0 WHERE (s0."foo" = '''')}
  end

  test "binary ops" do
    query = Schema |> select([r], r.x == 2) |> normalize
    assert all(query) == ~s{SELECT s0."x" = 2 FROM "schema" AS s0}

    query = Schema |> select([r], r.x != 2) |> normalize
    assert all(query) == ~s{SELECT s0."x" != 2 FROM "schema" AS s0}

    query = Schema |> select([r], r.x <= 2) |> normalize
    assert all(query) == ~s{SELECT s0."x" <= 2 FROM "schema" AS s0}

    query = Schema |> select([r], r.x >= 2) |> normalize
    assert all(query) == ~s{SELECT s0."x" >= 2 FROM "schema" AS s0}

    query = Schema |> select([r], r.x < 2) |> normalize
    assert all(query) == ~s{SELECT s0."x" < 2 FROM "schema" AS s0}

    query = Schema |> select([r], r.x > 2) |> normalize
    assert all(query) == ~s{SELECT s0."x" > 2 FROM "schema" AS s0}
  end

  test "is_nil" do
    query = Schema |> select([r], is_nil(r.x)) |> normalize
    assert all(query) == ~s{SELECT s0."x" IS NULL FROM "schema" AS s0}

    query = Schema |> select([r], not is_nil(r.x)) |> normalize
    assert all(query) == ~s{SELECT NOT (s0."x" IS NULL) FROM "schema" AS s0}
  end

  test "fragments" do
    query = Schema |> select([r], fragment("now")) |> normalize
    assert all(query) == ~s{SELECT now FROM "schema" AS s0}

    query = Schema |> select([r], fragment("downcase(?)", r.x)) |> normalize
    assert all(query) == ~s{SELECT downcase(s0."x") FROM "schema" AS s0}

    value = 13
    query = Schema |> select([r], fragment("downcase(?, ?)", r.x, ^value)) |> normalize
    assert all(query) == ~s{SELECT downcase(s0."x", $1) FROM "schema" AS s0}

    query = Schema |> select([], fragment(title: 2)) |> normalize

    assert_raise Ecto.QueryError, fn ->
      all(query)
    end
  end

  test "literals" do
    query = "schema" |> where(foo: true) |> select([], true) |> normalize
    assert all(query) == ~s{SELECT TRUE FROM "schema" AS s0 WHERE (s0."foo" = TRUE)}

    query = "schema" |> where(foo: false) |> select([], true) |> normalize
    assert all(query) == ~s{SELECT TRUE FROM "schema" AS s0 WHERE (s0."foo" = FALSE)}

    query = "schema" |> where(foo: "abc") |> select([], true) |> normalize
    assert all(query) == ~s{SELECT TRUE FROM "schema" AS s0 WHERE (s0."foo" = 'abc')}

    query = "schema" |> where(foo: <<0, ?a, ?b, ?c>>) |> select([], true) |> normalize

    assert_raise Ecto.QueryError, ~r"The Redshift Adapter doesn't support binaries", fn ->
      all(query)
    end

    query = "schema" |> where(foo: 123) |> select([], true) |> normalize
    assert all(query) == ~s{SELECT TRUE FROM "schema" AS s0 WHERE (s0."foo" = 123)}

    query = "schema" |> where(foo: 123.0) |> select([], true) |> normalize
    assert all(query) == ~s{SELECT TRUE FROM "schema" AS s0 WHERE (s0."foo" = 123.0::float)}
  end

  test "tagged type" do
    query =
      Schema |> select([], type(^"601d74e4-a8d3-4b6e-8365-eddb4c893327", Ecto.UUID)) |> normalize

    assert all(query) == ~s{SELECT $1::char(36) FROM "schema" AS s0}

    query = Schema |> select([], type(^1, CustomPermalink)) |> normalize
    assert all(query) == ~s{SELECT $1::bigint FROM "schema" AS s0}
  end

  test "nested expressions" do
    z = 123
    query = from(r in Schema, []) |> select([r], (r.x > 0 and r.y > ^(-z)) or true) |> normalize
    assert all(query) == ~s{SELECT ((s0."x" > 0) AND (s0."y" > $1)) OR TRUE FROM "schema" AS s0}
  end

  test "in expression" do
    query = Schema |> select([e], 1 in []) |> normalize
    assert all(query) == ~s{SELECT false FROM "schema" AS s0}

    query = Schema |> select([e], 1 in [1, e.x, 3]) |> normalize
    assert all(query) == ~s{SELECT 1 IN (1,s0."x",3) FROM "schema" AS s0}

    query = Schema |> select([e], 1 in ^[]) |> normalize
    assert all(query) == ~s{SELECT false FROM "schema" AS s0}

    query = Schema |> select([e], 1 in ^[1, 2, 3]) |> normalize
    assert all(query) == ~s{SELECT 1 IN ($1,$2,$3) FROM "schema" AS s0}

    query = Schema |> select([e], 1 in [1, ^2, 3]) |> normalize
    assert all(query) == ~s{SELECT 1 IN (1,$1,3) FROM "schema" AS s0}

    query = Schema |> select([e], ^1 in [1, ^2, 3]) |> normalize
    assert all(query) == ~s{SELECT $1 IN (1,$2,3) FROM "schema" AS s0}

    query = Schema |> select([e], ^1 in ^[1, 2, 3]) |> normalize
    assert all(query) == ~s{SELECT $1 IN ($2,$3,$4) FROM "schema" AS s0}

    query = Schema |> select([e], 1 in fragment("foo")) |> normalize
    assert all(query) == ~s{SELECT 1 IN (foo) FROM "schema" AS s0}

    query = Schema |> select([e], e.x == ^0 or e.x in ^[1, 2, 3] or e.x == ^4) |> normalize

    assert all(query) ==
             ~s{SELECT ((s0."x" = $1) OR s0."x" IN ($2,$3,$4)) OR (s0."x" = $5) FROM "schema" AS s0}
  end

  test "having" do
    query = Schema |> having([p], p.x == p.x) |> select([], true) |> normalize
    assert all(query) == ~s{SELECT TRUE FROM "schema" AS s0 HAVING (s0."x" = s0."x")}

    query =
      Schema
      |> having([p], p.x == p.x)
      |> having([p], p.y == p.y)
      |> select([], true)
      |> normalize

    assert all(query) ==
             ~s{SELECT TRUE FROM "schema" AS s0 HAVING (s0."x" = s0."x") AND (s0."y" = s0."y")}
  end

  test "or_having" do
    query = Schema |> or_having([p], p.x == p.x) |> select([], true) |> normalize
    assert all(query) == ~s{SELECT TRUE FROM "schema" AS s0 HAVING (s0."x" = s0."x")}

    query =
      Schema
      |> or_having([p], p.x == p.x)
      |> or_having([p], p.y == p.y)
      |> select([], true)
      |> normalize

    assert all(query) ==
             ~s{SELECT TRUE FROM "schema" AS s0 HAVING (s0."x" = s0."x") OR (s0."y" = s0."y")}
  end

  test "group by" do
    query = Schema |> group_by([r], r.x) |> select([r], r.x) |> normalize
    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0 GROUP BY s0."x"}

    query = Schema |> group_by([r], 2) |> select([r], r.x) |> normalize
    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0 GROUP BY 2}

    query = Schema |> group_by([r], [r.x, r.y]) |> select([r], r.x) |> normalize
    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0 GROUP BY s0."x", s0."y"}

    query = Schema |> group_by([r], []) |> select([r], r.x) |> normalize
    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0}
  end

  test "arrays not supported" do
    assert_raise Ecto.QueryError, ~r"Array type is not supported by Redshift", fn ->
      query = Schema |> select([], fragment("?", [1, 2, 3])) |> normalize
      all(query)
    end
  end

  test "interpolated values" do
    query =
      "schema"
      |> select([m], {m.id, ^true})
      |> join(:inner, [], Schema2, on: fragment("?", ^true))
      |> join(:inner, [], Schema2, on: fragment("?", ^false))
      |> where([], fragment("?", ^true))
      |> where([], fragment("?", ^false))
      |> having([], fragment("?", ^true))
      |> having([], fragment("?", ^false))
      |> group_by([], fragment("?", ^1))
      |> group_by([], fragment("?", ^2))
      |> order_by([], fragment("?", ^3))
      |> order_by([], ^:x)
      |> limit([], ^4)
      |> offset([], ^5)
      |> normalize

    result =
      "SELECT s0.\"id\", $1 FROM \"schema\" AS s0 INNER JOIN \"schema2\" AS s1 ON $2 " <>
        "INNER JOIN \"schema2\" AS s2 ON $3 WHERE ($4) AND ($5) " <>
        "GROUP BY $6, $7 HAVING ($8) AND ($9) " <> "ORDER BY $10, s0.\"x\" LIMIT $11 OFFSET $12"

    assert all(query) == String.trim(result)
  end

  test "fragments and types" do
    query =
      normalize(
        from(
          e in "schema",
          where: fragment("extract(? from ?) = ?", ^"month", e.start_time, type(^"4", :integer)),
          where:
            fragment("extract(? from ?) = ?", ^"year", e.start_time, type(^"2015", :integer)),
          select: true
        )
      )

    result =
      "SELECT TRUE FROM \"schema\" AS s0 " <>
        "WHERE (extract($1 from s0.\"start_time\") = $2::bigint) " <>
        "AND (extract($3 from s0.\"start_time\") = $4::bigint)"

    assert all(query) == String.trim(result)
  end

  test "fragments allow ? to be escaped with backslash" do
    query =
      normalize(
        from(
          e in "schema",
          where: fragment("? = \"query\\?\"", e.start_time),
          select: true
        )
      )

    result = "SELECT TRUE FROM \"schema\" AS s0 " <> "WHERE (s0.\"start_time\" = \"query?\")"

    assert all(query) == String.trim(result)
  end

  ## *_all

  test "update all" do
    query = from(m in Schema, update: [set: [x: 0]]) |> normalize(:update_all)
    assert update_all(query) == ~s{UPDATE "schema" SET "x" = 0}

    query = from(m in Schema, update: [set: [x: 0], inc: [y: 1, z: -3]]) |> normalize(:update_all)

    assert update_all(query) ==
             ~s{UPDATE "schema" SET "x" = 0, "y" = "schema"."y" + 1, "z" = "schema"."z" + -3}

    query = from(e in Schema, where: e.x == 123, update: [set: [x: 0]]) |> normalize(:update_all)
    assert update_all(query) == ~s{UPDATE "schema" SET "x" = 0 WHERE ("schema"."x" = 123)}

    query = from(m in Schema, update: [set: [x: ^0]]) |> normalize(:update_all)
    assert update_all(query) == ~s{UPDATE "schema" SET "x" = $1}

    query =
      Schema
      |> join(:inner, [p], q in Schema2, on: p.x == q.z)
      |> update([_], set: [x: 0])
      |> normalize(:update_all)

    assert update_all(query) ==
             ~s{UPDATE "schema" SET "x" = 0 FROM "schema2" WHERE ("schema"."x" = "schema2"."z")}

    query =
      from(
        e in Schema,
        where: e.x == 123,
        update: [set: [x: 0]],
        join: q in Schema2,
        on: e.x == q.z
      )
      |> normalize(:update_all)

    assert update_all(query) ==
             ~s{UPDATE "schema" SET "x" = 0 FROM "schema2" WHERE ("schema"."x" = "schema2"."z") AND ("schema"."x" = 123)}
  end

  test "update all with returning" do
    query = from(m in Schema, update: [set: [x: 0]]) |> select([m], m)

    assert_raise ArgumentError, ~r"RETURNING is not supported by Redshift", fn ->
      update_all(query)
    end
  end

  test "update all with prefix" do
    query = from(m in Schema, update: [set: [x: 0]]) |> normalize(:update_all)

    assert update_all(%{query | prefix: "prefix"}) == ~s{UPDATE "prefix"."schema" SET "x" = 0}
  end

  test "delete all" do
    query = Schema |> Queryable.to_query() |> normalize
    assert delete_all(query) == ~s{DELETE FROM "schema"}

    query = from(e in Schema, where: e.x == 123) |> normalize
    assert delete_all(query) == ~s{DELETE FROM "schema" WHERE ("schema"."x" = 123)}

    query =
      Schema
      |> join(:inner, [p], q in Schema2, on: p.x == q.z)
      |> normalize

    assert delete_all(query) ==
             ~s{DELETE FROM "schema" USING "schema2" WHERE ("schema"."x" = "schema2"."z")}

    query = from(e in Schema, where: e.x == 123, join: q in Schema2, on: e.x == q.z) |> normalize

    assert delete_all(query) ==
             ~s{DELETE FROM "schema" USING "schema2" WHERE ("schema"."x" = "schema2"."z") AND ("schema"."x" = 123)}

    query =
      from(e in Schema, where: e.x == 123, join: assoc(e, :comments), join: assoc(e, :permalink))
      |> normalize

    assert delete_all(query) ==
             ~s{DELETE FROM "schema" USING "schema2", "schema3" WHERE ("schema2"."z" = "schema"."x") AND ("schema3"."id" = "schema"."y") AND ("schema"."x" = 123)}
  end

  test "delete all with returning" do
    query = Schema |> Queryable.to_query() |> select([m], m)

    assert_raise ArgumentError, ~r"RETURNING is not supported by Redshift", fn ->
      delete_all(query)
    end
  end

  test "delete all with prefix" do
    query = Schema |> Queryable.to_query() |> normalize
    assert delete_all(%{query | prefix: "prefix"}) == ~s{DELETE FROM "prefix"."schema"}
  end

  ## Joins

  test "join" do
    query =
      Schema
      |> join(:inner, [p], q in Schema2, on: p.x == q.z)
      |> select([], true)
      |> normalize

    assert all(query) ==
             ~s{SELECT TRUE FROM "schema" AS s0 INNER JOIN "schema2" AS s1 ON s0."x" = s1."z"}

    query =
      Schema
      |> join(:inner, [p], q in Schema2, on: p.x == q.z)
      |> join(:inner, [], Schema, on: true)
      |> select([], true)
      |> normalize

    assert all(query) ==
             ~s{SELECT TRUE FROM "schema" AS s0 INNER JOIN "schema2" AS s1 ON s0."x" = s1."z" } <>
               ~s{INNER JOIN "schema" AS s2 ON TRUE}
  end

  test "join with nothing bound" do
    query =
      Schema
      |> join(:inner, [], q in Schema2, on: q.z == q.z)
      |> select([], true)
      |> normalize

    assert all(query) ==
             ~s{SELECT TRUE FROM "schema" AS s0 INNER JOIN "schema2" AS s1 ON s1."z" = s1."z"}
  end

  test "join without schema" do
    query =
      "posts"
      |> join(:inner, [p], q in "comments", on: p.x == q.z)
      |> select([], true)
      |> normalize

    assert all(query) ==
             ~s{SELECT TRUE FROM "posts" AS p0 INNER JOIN "comments" AS c1 ON p0."x" = c1."z"}
  end

  test "join with subquery" do
    posts = subquery("posts" |> where(title: ^"hello") |> select([r], %{x: r.x, y: r.y}))

    query =
      "comments"
      |> join(:inner, [c], p in subquery(posts), on: true)
      |> select([_, p], p.x)
      |> normalize

    assert all(query) ==
             ~s{SELECT s1."x" FROM "comments" AS c0 } <>
               ~s{INNER JOIN (SELECT p0."x" AS "x", p0."y" AS "y" FROM "posts" AS p0 WHERE (p0."title" = $1)) AS s1 ON TRUE}

    posts = subquery("posts" |> where(title: ^"hello") |> select([r], %{x: r.x, z: r.y}))

    query =
      "comments"
      |> join(:inner, [c], p in subquery(posts), on: true)
      |> select([_, p], p)
      |> normalize

    assert all(query) ==
             ~s{SELECT s1."x", s1."z" FROM "comments" AS c0 } <>
               ~s{INNER JOIN (SELECT p0."x" AS "x", p0."y" AS "z" FROM "posts" AS p0 WHERE (p0."title" = $1)) AS s1 ON TRUE}
  end

  test "join with prefix" do
    query =
      Schema
      |> join(:inner, [p], q in Schema2, on: p.x == q.z)
      |> select([], true)
      |> normalize

    assert all(%{query | prefix: "prefix"}) ==
             ~s{SELECT TRUE FROM "prefix"."schema" AS s0 INNER JOIN "prefix"."schema2" AS s1 ON s0."x" = s1."z"}
  end

  test "join with fragment" do
    query =
      Schema
      |> join(
        :inner,
        [p],
        q in fragment("SELECT * FROM schema2 AS s2 WHERE s2.id = ? AND s2.field = ?", p.x, ^10)
      )
      |> select([p], {p.id, ^0})
      |> where([p], p.id > 0 and p.id < ^100)
      |> normalize

    assert all(query) ==
             ~s{SELECT s0."id", $1 FROM "schema" AS s0 INNER JOIN } <>
               ~s{(SELECT * FROM schema2 AS s2 WHERE s2.id = s0."x" AND s2.field = $2) AS f1 ON TRUE } <>
               ~s{WHERE ((s0."id" > 0) AND (s0."id" < $3))}
  end

  test "join with fragment and on defined" do
    query =
      Schema
      |> join(:inner, [p], q in fragment("SELECT * FROM schema2"), on: q.id == p.id)
      |> select([p], {p.id, ^0})
      |> normalize

    assert all(query) ==
             ~s{SELECT s0."id", $1 FROM "schema" AS s0 INNER JOIN } <>
               ~s{(SELECT * FROM schema2) AS f1 ON f1."id" = s0."id"}
  end

  test "join with query interpolation" do
    inner = Ecto.Queryable.to_query(Schema2)
    query = from(p in Schema, left_join: c in ^inner, select: {p.id, c.id}) |> normalize()

    assert all(query) ==
             "SELECT s0.\"id\", s1.\"id\" FROM \"schema\" AS s0 LEFT OUTER JOIN \"schema2\" AS s1 ON TRUE"
  end

  test "lateral join with fragment" do
    query =
      Schema
      |> join(
        :inner_lateral,
        [p],
        q in fragment("SELECT * FROM schema2 AS s2 WHERE s2.id = ? AND s2.field = ?", p.x, ^10)
      )
      |> select([p, q], {p.id, q.z})
      |> where([p], p.id > 0 and p.id < ^100)
      |> normalize

    assert all(query) ==
             ~s{SELECT s0."id", f1."z" FROM "schema" AS s0 INNER JOIN LATERAL } <>
               ~s{(SELECT * FROM schema2 AS s2 WHERE s2.id = s0."x" AND s2.field = $1) AS f1 ON TRUE } <>
               ~s{WHERE ((s0."id" > 0) AND (s0."id" < $2))}
  end

  test "cross join" do
    query = from(p in Schema, cross_join: c in Schema2, select: {p.id, c.id}) |> normalize()

    assert all(query) ==
             "SELECT s0.\"id\", s1.\"id\" FROM \"schema\" AS s0 CROSS JOIN \"schema2\" AS s1 ON TRUE"
  end

  test "join produces correct bindings" do
    query = from(p in Schema, join: c in Schema2, on: true)
    query = from(p in query, join: c in Schema2, on: true, select: {p.id, c.id})
    query = normalize(query)

    assert all(query) ==
             "SELECT s0.\"id\", s2.\"id\" FROM \"schema\" AS s0 INNER JOIN \"schema2\" AS s1 ON TRUE INNER JOIN \"schema2\" AS s2 ON TRUE"
  end

  describe "query interpolation parameters" do
    test "self join on subquery" do
      subquery = select(Schema, [r], %{x: r.x, y: r.y})

      query =
        subquery
        |> join(:inner, [c], p in subquery(subquery), on: true)
        |> normalize

      assert all(query) ==
               ~s{SELECT s0."x", s0."y" FROM "schema" AS s0 INNER JOIN } <>
                 ~s{(SELECT s0."x" AS "x", s0."y" AS "y" FROM "schema" AS s0) } <>
                 ~s{AS s1 ON TRUE}
    end

    test "self join on subquery with fragment" do
      subquery = select(Schema, [r], %{string: fragment("downcase(?)", ^"string")})

      query =
        subquery
        |> join(:inner, [c], p in subquery(subquery), on: true)
        |> normalize

      assert all(query) ==
               ~s{SELECT downcase($1) FROM "schema" AS s0 INNER JOIN } <>
                 ~s{(SELECT downcase($2) AS "string" FROM "schema" AS s0) } <> ~s{AS s1 ON TRUE}
    end

    test "join on subquery with simple select" do
      subquery = select(Schema, [r], %{x: ^999, w: ^888})

      query =
        Schema
        |> select([r], %{y: ^666})
        |> join(:inner, [c], p in subquery(subquery), on: true)
        |> where([a, b], a.x == ^111)
        |> normalize

      assert all(query) ==
               ~s{SELECT $1 FROM "schema" AS s0 INNER JOIN } <>
                 ~s{(SELECT $2 AS "x", $3 AS "w" FROM "schema" AS s0) AS s1 ON TRUE } <>
                 ~s{WHERE (s0."x" = $4)}
    end
  end

  ## Associations

  test "association join belongs_to" do
    query =
      Schema2
      |> join(:inner, [c], p in assoc(c, :post))
      |> select([], true)
      |> normalize

    assert all(query) ==
             "SELECT TRUE FROM \"schema2\" AS s0 INNER JOIN \"schema\" AS s1 ON s1.\"x\" = s0.\"z\""
  end

  test "association join has_many" do
    query =
      Schema
      |> join(:inner, [p], c in assoc(p, :comments))
      |> select([], true)
      |> normalize

    assert all(query) ==
             "SELECT TRUE FROM \"schema\" AS s0 INNER JOIN \"schema2\" AS s1 ON s1.\"z\" = s0.\"x\""
  end

  test "association join has_one" do
    query =
      Schema
      |> join(:inner, [p], pp in assoc(p, :permalink))
      |> select([], true)
      |> normalize

    assert all(query) ==
             "SELECT TRUE FROM \"schema\" AS s0 INNER JOIN \"schema3\" AS s1 ON s1.\"id\" = s0.\"y\""
  end

  # Schema based

  test "insert" do
    query = insert(nil, "schema", [:x, :y], [[:x, :y]], {:raise, [], []}, [])
    assert query == ~s{INSERT INTO "schema" ("x","y") VALUES ($1,$2)}

    query = insert(nil, "schema", [:x, :y], [[:x, :y], [nil, :z]], {:raise, [], []}, [])
    assert query == ~s{INSERT INTO "schema" ("x","y") VALUES ($1,$2),(DEFAULT,$3)}

    query = insert(nil, "schema", [], [[]], {:raise, [], []}, [])
    assert query == ~s{INSERT INTO "schema" VALUES (DEFAULT)}

    query = insert(nil, "schema", [], [[]], {:raise, [], []}, [])
    assert query == ~s{INSERT INTO "schema" VALUES (DEFAULT)}

    query = insert("prefix", "schema", [], [[]], {:raise, [], []}, [])
    assert query == ~s{INSERT INTO "prefix"."schema" VALUES (DEFAULT)}
  end

  test "insert with on conflict" do
    # For :raise
    query = insert(nil, "schema", [:x, :y], [[:x, :y]], {:raise, [], []}, [])
    assert query == ~s{INSERT INTO "schema" ("x","y") VALUES ($1,$2)}

    # For :nothing
    assert_raise ArgumentError, "ON CONFLICT is not supported by Redshift", fn ->
      insert(nil, "schema", [:x, :y], [[:x, :y]], {:nothing, [], []}, [])
    end

    # For :update
    assert_raise ArgumentError, "ON CONFLICT is not supported by Redshift", fn ->
      update = from("schema", update: [set: [z: "foo"]]) |> normalize(:update_all)
      insert(nil, "schema", [:x, :y], [[:x, :y]], {update, [], [:x, :y]}, [])
    end

    # For :replace_all
    assert_raise ArgumentError, "ON CONFLICT is not supported by Redshift", fn ->
      insert(nil, "schema", [:x, :y], [[:x, :y]], {:replace_all, [], [:id]}, [])
    end
  end

  test "update" do
    query = update(nil, "schema", [:x, :y], [:id], [])
    assert query == ~s{UPDATE "schema" SET "x" = $1, "y" = $2 WHERE "id" = $3}

    query = update(nil, "schema", [:x, :y], [:id], [])
    assert query == ~s{UPDATE "schema" SET "x" = $1, "y" = $2 WHERE "id" = $3}

    query = update("prefix", "schema", [:x, :y], [:id], [])
    assert query == ~s{UPDATE "prefix"."schema" SET "x" = $1, "y" = $2 WHERE "id" = $3}
  end

  test "delete" do
    query = delete(nil, "schema", [:x, :y], [])
    assert query == ~s{DELETE FROM "schema" WHERE "x" = $1 AND "y" = $2}

    query = delete(nil, "schema", [:x, :y], [])
    assert query == ~s{DELETE FROM "schema" WHERE "x" = $1 AND "y" = $2}

    query = delete("prefix", "schema", [:x, :y], [])
    assert query == ~s{DELETE FROM "prefix"."schema" WHERE "x" = $1 AND "y" = $2}
  end

  # DDL

  alias Ecto.Migration.Reference

  import Ecto.Migration,
    only: [table: 1, table: 2, index: 2, index: 3, constraint: 2, constraint: 3]

  test "executing a string during migration" do
    assert execute_ddl("example") == ["example"]
  end

  test "create table" do
    create =
      {:create, table(:posts),
       [
         {:add, :name, :string, [default: "Untitled", size: 20, null: false]},
         {:add, :price, :numeric, [precision: 8, scale: 2, default: {:fragment, "expr"}]},
         {:add, :on_hand, :integer, [default: 0, null: true]},
         {:add, :published_at, :"time without time zone", [null: true]},
         {:add, :is_active, :boolean, [default: true]}
       ]}

    assert execute_ddl(create) == [
             """
             CREATE TABLE "posts" ("name" varchar(20) DEFAULT 'Untitled' NOT NULL,
             "price" numeric(8,2) DEFAULT expr,
             "on_hand" integer DEFAULT 0 NULL,
             "published_at" time without time zone NULL,
             "is_active" boolean DEFAULT true)
             """
             |> remove_newlines
           ]
  end

  test "create table with prefix" do
    create =
      {:create, table(:posts, prefix: :foo),
       [{:add, :category_0, %Reference{table: :categories}, []}]}

    assert execute_ddl(create) == [
             """
             CREATE TABLE "foo"."posts"
             ("category_0" bigint CONSTRAINT "posts_category_0_fkey" REFERENCES "foo"."categories"("id"))
             """
             |> remove_newlines
           ]
  end

  test "create table with comment on columns and table" do
    create =
      {:create, table(:posts, comment: "comment"),
       [
         {:add, :category_0, %Reference{table: :categories}, [comment: "column comment"]},
         {:add, :created_at, :timestamp, []},
         {:add, :updated_at, :timestamp, [comment: "column comment 2"]}
       ]}

    assert execute_ddl(create) == [
             remove_newlines("""
             CREATE TABLE "posts"
             ("category_0" bigint CONSTRAINT "posts_category_0_fkey" REFERENCES "categories"("id"), "created_at" timestamp, "updated_at" timestamp)
             """),
             ~s|COMMENT ON TABLE "posts" IS 'comment'|,
             ~s|COMMENT ON COLUMN "posts"."category_0" IS 'column comment'|,
             ~s|COMMENT ON COLUMN "posts"."updated_at" IS 'column comment 2'|
           ]
  end

  test "create table with comment on table" do
    create =
      {:create, table(:posts, comment: "table comment", prefix: "foo"),
       [{:add, :category_0, %Reference{table: :categories}, []}]}

    assert execute_ddl(create) == [
             remove_newlines("""
             CREATE TABLE "foo"."posts"
             ("category_0" bigint CONSTRAINT "posts_category_0_fkey" REFERENCES "foo"."categories"("id"))
             """),
             ~s|COMMENT ON TABLE "foo"."posts" IS 'table comment'|
           ]
  end

  test "create table with comment on columns" do
    create =
      {:create, table(:posts, prefix: "foo"),
       [
         {:add, :category_0, %Reference{table: :categories}, [comment: "column comment"]},
         {:add, :created_at, :timestamp, []},
         {:add, :updated_at, :timestamp, [comment: "column comment 2"]}
       ]}

    assert execute_ddl(create) == [
             remove_newlines("""
             CREATE TABLE "foo"."posts"
             ("category_0" bigint CONSTRAINT "posts_category_0_fkey" REFERENCES "foo"."categories"("id"), "created_at" timestamp, "updated_at" timestamp)
             """),
             ~s|COMMENT ON COLUMN "foo"."posts"."category_0" IS 'column comment'|,
             ~s|COMMENT ON COLUMN "foo"."posts"."updated_at" IS 'column comment 2'|
           ]
  end

  test "create table with references" do
    create =
      {:create, table(:posts),
       [
         {:add, :id, :serial, [primary_key: true]},
         {:add, :category_0, %Reference{table: :categories}, []},
         {:add, :category_1, %Reference{table: :categories, name: :foo_bar}, []},
         {:add, :category_2, %Reference{table: :categories}, [null: false]}
       ]}

    assert execute_ddl(create) == [
             """
             CREATE TABLE "posts" ("id" integer,
             "category_0" bigint CONSTRAINT "posts_category_0_fkey" REFERENCES "categories"("id"),
             "category_1" bigint CONSTRAINT "foo_bar" REFERENCES "categories"("id"),
             "category_2" bigint NOT NULL CONSTRAINT "posts_category_2_fkey" REFERENCES "categories"("id"),
             PRIMARY KEY ("id"))
             """
             |> remove_newlines
           ]
  end

  test "create table with options" do
    create =
      {:create, table(:posts, options: "WITH FOO=BAR"),
       [{:add, :id, :serial, [primary_key: true]}, {:add, :created_at, :naive_datetime, []}]}

    assert execute_ddl(create) ==
             [
               ~s|CREATE TABLE "posts" ("id" integer, "created_at" timestamp, PRIMARY KEY ("id")) WITH FOO=BAR|
             ]
  end

  test "create table with distribution style and key" do
    create =
      {:create, table(:posts, options: [diststyle: :even]),
       [{:add, :id, :serial, [primary_key: true]}, {:add, :created_at, :naive_datetime, []}]}

    assert execute_ddl(create) == [
             ~s|CREATE TABLE "posts" ("id" integer, "created_at" timestamp, PRIMARY KEY ("id")) DISTSTYLE EVEN|
           ]

    create =
      {:create, table(:posts, options: [diststyle: :all]),
       [{:add, :id, :serial, [primary_key: true]}, {:add, :created_at, :naive_datetime, []}]}

    assert execute_ddl(create) == [
             ~s|CREATE TABLE "posts" ("id" integer, "created_at" timestamp, PRIMARY KEY ("id")) DISTSTYLE ALL|
           ]

    create =
      {:create, table(:posts, options: [distkey: :id]),
       [{:add, :id, :serial, [primary_key: true]}, {:add, :created_at, :naive_datetime, []}]}

    assert execute_ddl(create) == [
             ~s|CREATE TABLE "posts" ("id" integer, "created_at" timestamp, PRIMARY KEY ("id")) DISTKEY ("id")|
           ]

    create =
      {:create, table(:posts),
       [
         {:add, :id, :serial, [primary_key: true, distkey: true]},
         {:add, :created_at, :naive_datetime, []}
       ]}

    assert execute_ddl(create) == [
             ~s|CREATE TABLE "posts" ("id" integer DISTKEY, "created_at" timestamp, PRIMARY KEY ("id"))|
           ]
  end

  test "create table with sortkeys" do
    create =
      {:create, table(:posts, options: [sortkey: :id]),
       [{:add, :id, :serial, [primary_key: true]}, {:add, :created_at, :naive_datetime, []}]}

    assert execute_ddl(create) == [
             ~s|CREATE TABLE "posts" ("id" integer, "created_at" timestamp, PRIMARY KEY ("id")) SORTKEY ("id")|
           ]

    create =
      {:create, table(:posts, options: [sortkey: [:created_at, :id]]),
       [{:add, :id, :serial, [primary_key: true]}, {:add, :created_at, :naive_datetime, []}]}

    assert execute_ddl(create) == [
             ~s|CREATE TABLE "posts" ("id" integer, "created_at" timestamp, PRIMARY KEY ("id")) SORTKEY ("created_at", "id")|
           ]

    create =
      {:create, table(:posts, options: [sortkey: {:interleaved, [:id, :created_at]}]),
       [{:add, :id, :serial, [primary_key: true]}, {:add, :created_at, :naive_datetime, []}]}

    assert execute_ddl(create) == [
             ~s|CREATE TABLE "posts" ("id" integer, "created_at" timestamp, PRIMARY KEY ("id")) INTERLEAVED SORTKEY ("id", "created_at")|
           ]

    create =
      {:create, table(:posts),
       [
         {:add, :id, :serial, [primary_key: true, sortkey: true]},
         {:add, :created_at, :naive_datetime, []}
       ]}

    assert execute_ddl(create) == [
             ~s|CREATE TABLE "posts" ("id" integer SORTKEY, "created_at" timestamp, PRIMARY KEY ("id"))|
           ]
  end

  test "create table with distribution style and sortkeys" do
    create =
      {:create, table(:posts, options: [diststyle: :even, sortkey: :id]),
       [{:add, :id, :serial, [primary_key: true]}, {:add, :created_at, :naive_datetime, []}]}

    assert execute_ddl(create) == [
             ~s|CREATE TABLE "posts" ("id" integer, "created_at" timestamp, PRIMARY KEY ("id")) DISTSTYLE EVEN SORTKEY ("id")|
           ]

    create =
      {:create, table(:posts, options: [distkey: :id, sortkey: [:created_at, :id]]),
       [{:add, :id, :serial, [primary_key: true]}, {:add, :created_at, :naive_datetime, []}]}

    assert execute_ddl(create) == [
             ~s|CREATE TABLE "posts" ("id" integer, "created_at" timestamp, PRIMARY KEY ("id")) DISTKEY ("id") SORTKEY ("created_at", "id")|
           ]

    create =
      {:create,
       table(:posts, options: [sortkey: {:interleaved, [:id, :created_at]}, diststyle: :all]),
       [{:add, :id, :serial, [primary_key: true]}, {:add, :created_at, :naive_datetime, []}]}

    assert execute_ddl(create) == [
             ~s|CREATE TABLE "posts" ("id" integer, "created_at" timestamp, PRIMARY KEY ("id")) INTERLEAVED SORTKEY ("id", "created_at") DISTSTYLE ALL|
           ]

    create =
      {:create, table(:posts),
       [
         {:add, :id, :serial, [primary_key: true, sortkey: true, distkey: true]},
         {:add, :created_at, :naive_datetime, []}
       ]}

    assert execute_ddl(create) == [
             ~s|CREATE TABLE "posts" ("id" integer SORTKEY DISTKEY, "created_at" timestamp, PRIMARY KEY ("id"))|
           ]
  end

  test "create columns with various options" do
    create =
      {:create, table(:posts),
       [
         {:add, :id, :serial, [primary_key: true, distkey: true, encode: :delta]},
         {:add, :title, :string,
          [size: 765, null: false, unique: true, sortkey: true, encode: :lzo]},
         {:add, :counter, :serial, [identity: {0, 1}, encode: :delta]},
         {:add, :views, :smallint, [default: 0, encode: :mostly8]},
         {:add, :author, :string, [default: "anonymous", encode: :text255]},
         {:add, :created_at, :naive_datetime, [encode: :zstd]}
       ]}

    assert execute_ddl(create) == [
             """
             CREATE TABLE "posts" ("id" integer DISTKEY ENCODE delta,
             "title" varchar(765) NOT NULL UNIQUE SORTKEY ENCODE lzo,
             "counter" integer IDENTITY(0,1) ENCODE delta,
             "views" smallint DEFAULT 0 ENCODE mostly8,
             "author" varchar(255) DEFAULT 'anonymous' ENCODE text255,
             "created_at" timestamp ENCODE zstd,
             PRIMARY KEY ("id"))
             """
             |> remove_newlines
           ]
  end

  test "create table with composite key" do
    create =
      {:create, table(:posts),
       [
         {:add, :a, :integer, [primary_key: true]},
         {:add, :b, :integer, [primary_key: true]},
         {:add, :name, :string, []}
       ]}

    assert execute_ddl(create) == [
             """
             CREATE TABLE "posts" ("a" integer, "b" integer, "name" varchar(255), PRIMARY KEY ("a", "b"))
             """
             |> remove_newlines
           ]
  end

  test "create table with a map column, and an empty map default" do
    create =
      {:create, table(:posts),
       [
         {:add, :a, :map, [default: %{}]}
       ]}

    assert execute_ddl(create) == [~s|CREATE TABLE "posts" ("a" varchar(max) DEFAULT '{}')|]
  end

  test "create table with a map column, and a map default with values" do
    create =
      {:create, table(:posts),
       [
         {:add, :a, :map, [default: %{foo: "bar", baz: "boom"}]}
       ]}

    assert execute_ddl(create) == [
             ~s|CREATE TABLE "posts" ("a" varchar(max) DEFAULT '{"baz":"boom","foo":"bar"}')|
           ]
  end

  test "create table with a map column, and a string default" do
    create =
      {:create, table(:posts),
       [
         {:add, :a, :map, [default: ~s|{"foo":"bar","baz":"boom"}|]}
       ]}

    assert execute_ddl(create) == [
             ~s|CREATE TABLE "posts" ("a" varchar(max) DEFAULT '{"foo":"bar","baz":"boom"}')|
           ]
  end

  test "drop table" do
    drop = {:drop, table(:posts)}
    assert execute_ddl(drop) == [~s|DROP TABLE "posts"|]
  end

  test "drop table with prefix" do
    drop = {:drop, table(:posts, prefix: :foo)}
    assert execute_ddl(drop) == [~s|DROP TABLE "foo"."posts"|]
  end

  test "alter table" do
    alter =
      {:alter, table(:posts),
       [{:add, :title, :string, [default: "Untitled", size: 100, null: false]}]}

    assert execute_ddl(alter) == [
             ~s|ALTER TABLE "posts" ADD COLUMN "title" varchar(100) DEFAULT 'Untitled' NOT NULL|
           ]

    alter = {:alter, table(:posts), [{:add, :author_id, %Reference{table: :author}, []}]}

    assert execute_ddl(alter) == [
             ~s|ALTER TABLE "posts" ADD COLUMN "author_id" bigint CONSTRAINT "posts_author_id_fkey" REFERENCES "author"("id")|
           ]

    alter =
      {:alter, table(:posts), [{:modify, :price, :numeric, [precision: 8, scale: 2, null: true]}]}

    assert_raise ArgumentError, "ALTER COLUMN is not supported by Redshift", fn ->
      execute_ddl(alter)
    end

    alter =
      {:alter, table(:posts), [{:modify, :permalink_id, %Reference{table: :permalinks}, []}]}

    assert execute_ddl(alter) == [
             ~s|ALTER TABLE "posts" ADD CONSTRAINT "posts_permalink_id_fkey" FOREIGN KEY ("permalink_id") REFERENCES "permalinks"("id")|
           ]

    alter = {:alter, table(:posts), [{:remove, :summary}]}

    assert execute_ddl(alter) == [
             ~s|ALTER TABLE "posts" DROP COLUMN "summary"|
           ]
  end

  test "alter table with comments on table and columns" do
    alter =
      {:alter, table(:posts, comment: "table comment"),
       [
         {:add, :title, :string,
          [default: "Untitled", size: 100, null: false, comment: "column comment"]}
       ]}

    assert execute_ddl(alter) == [
             ~s|ALTER TABLE "posts" ADD COLUMN "title" varchar(100) DEFAULT 'Untitled' NOT NULL|,
             ~s|COMMENT ON TABLE \"posts\" IS 'table comment'|,
             ~s|COMMENT ON COLUMN \"posts\".\"title\" IS 'column comment'|
           ]
  end

  test "alter table with prefix" do
    alter = {:alter, table(:posts, prefix: :foo), [{:add, :author, :string, []}]}

    assert execute_ddl(alter) == [
             ~s|ALTER TABLE "foo"."posts" ADD COLUMN "author" varchar(255)|
           ]
  end

  test "alter table with serial primary key" do
    alter = {:alter, table(:posts), [{:add, :my_pk, :serial, [primary_key: true]}]}

    assert execute_ddl(alter) == [
             """
             ALTER TABLE "posts"
             ADD COLUMN "my_pk" integer,
             ADD PRIMARY KEY ("my_pk")
             """
             |> remove_newlines
           ]
  end

  test "alter table with bigserial primary key" do
    alter = {:alter, table(:posts), [{:add, :my_pk, :bigserial, [primary_key: true]}]}

    assert execute_ddl(alter) == [
             """
             ALTER TABLE "posts"
             ADD COLUMN "my_pk" bigint,
             ADD PRIMARY KEY ("my_pk")
             """
             |> remove_newlines
           ]
  end

  test "create index" do
    create = {:create, index(:posts, [:category_id, :permalink])}

    assert_raise ArgumentError, "CREATE INDEX and DROP INDEX are not supported by Redshift", fn ->
      execute_ddl(create)
    end
  end

  test "create unique index" do
    create = {:create, index(:posts, [:permalink], unique: true)}

    assert_raise ArgumentError, "CREATE INDEX and DROP INDEX are not supported by Redshift", fn ->
      execute_ddl(create)
    end
  end

  test "drop index" do
    drop = {:drop, index(:posts, [:id], name: "posts$main")}

    assert_raise ArgumentError, "CREATE INDEX and DROP INDEX are not supported by Redshift", fn ->
      execute_ddl(drop)
    end
  end

  test "create check constraint" do
    create = {:create, constraint(:products, "price_must_be_positive", check: "price > 0")}

    assert_raise ArgumentError,
                 "CHECK and EXCLUDE constraints are not supported by Redshift",
                 fn -> execute_ddl(create) end
  end

  test "create exclusion constraint" do
    create = {:create, constraint(:products, "price_must_be_positive", exclude: "")}

    assert_raise ArgumentError,
                 "CHECK and EXCLUDE constraints are not supported by Redshift",
                 fn -> execute_ddl(create) end
  end

  test "drop constraint" do
    drop = {:drop, constraint(:posts, "posts_author_id_fkey")}

    assert execute_ddl(drop) == [~s|ALTER TABLE "posts" DROP CONSTRAINT "posts_author_id_fkey"|]

    drop = {:drop, constraint(:posts, "posts_author_id_fkey", prefix: "foo")}

    assert execute_ddl(drop) ==
             [~s|ALTER TABLE "foo"."posts" DROP CONSTRAINT "posts_author_id_fkey"|]
  end

  test "rename table" do
    rename = {:rename, table(:posts), table(:new_posts)}
    assert execute_ddl(rename) == [~s|ALTER TABLE "posts" RENAME TO "new_posts"|]
  end

  test "rename table with prefix" do
    rename = {:rename, table(:posts, prefix: :foo), table(:new_posts, prefix: :foo)}
    assert execute_ddl(rename) == [~s|ALTER TABLE "foo"."posts" RENAME TO "new_posts"|]
  end

  test "rename column" do
    rename = {:rename, table(:posts), :given_name, :first_name}
    assert execute_ddl(rename) == [~s|ALTER TABLE "posts" RENAME "given_name" TO "first_name"|]
  end

  test "rename column in prefixed table" do
    rename = {:rename, table(:posts, prefix: :foo), :given_name, :first_name}

    assert execute_ddl(rename) == [
             ~s|ALTER TABLE "foo"."posts" RENAME "given_name" TO "first_name"|
           ]
  end

  defp remove_newlines(string) do
    string |> String.trim() |> String.replace("\n", " ")
  end
end
