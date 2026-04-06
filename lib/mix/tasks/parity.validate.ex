defmodule Mix.Tasks.Parity.Validate do
  @moduledoc """
  Validates dev-prod parity by exercising Elixir modules against real services.

  Requires real services running (Voyage AI API, Qdrant, MinIO) and valid
  config in .env.elixir. Uses a dedicated test collection and S3 prefix
  that are cleaned up after the run.

  Usage:
      mix parity.validate
  """

  use Mix.Task

  @test_collection "parity_test"
  @test_s3_prefix "parity-test"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    IO.puts("\n\e[1m═══ Dev-Prod Parity Validation ═══\e[0m\n")

    results = [
      run_section("Voyage AI", &validate_voyage/0),
      run_section("Qdrant", &validate_qdrant/0),
      run_section("MinIO/S3", &validate_s3/0),
      run_section("Full Pipeline", &validate_pipeline/0)
    ]

    IO.puts("\n\e[1m═══ Summary ═══\e[0m")

    total_pass = results |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    total_fail = results |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    IO.puts("  #{total_pass} passed, #{total_fail} failed\n")

    if total_fail > 0 do
      System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Sections
  # ---------------------------------------------------------------------------

  defp validate_voyage do
    check("embed with doc model (voyage-4-large)", fn ->
      {:ok, [vector]} = Engram.Embedders.Voyage.embed_texts(["parity test document"])
      dims = length(vector)

      if dims == 1024,
        do: {:pass, "returned #{dims}d vector"},
        else: {:fail, "expected 1024d, got #{dims}d"}
    end)

    check("embed with query model (voyage-4-lite)", fn ->
      {:ok, [vector]} =
        Engram.Embedders.Voyage.embed_texts(["parity test query"], model: "voyage-4-lite")

      dims = length(vector)

      if dims == 1024,
        do: {:pass, "returned #{dims}d vector"},
        else: {:fail, "expected 1024d, got #{dims}d"}
    end)

    check("asymmetric compatibility (cosine > 0.5)", fn ->
      {:ok, [doc_vec]} = Engram.Embedders.Voyage.embed_texts(["elixir phoenix framework"])

      {:ok, [query_vec]} =
        Engram.Embedders.Voyage.embed_texts(["elixir phoenix framework"],
          model: "voyage-4-lite"
        )

      cosine = cosine_similarity(doc_vec, query_vec)

      if cosine > 0.5,
        do: {:pass, "cosine similarity = #{Float.round(cosine, 4)}"},
        else: {:fail, "cosine similarity too low: #{Float.round(cosine, 4)}"}
    end)
  end

  defp validate_qdrant do
    alias Engram.Vector.Qdrant

    check("create collection (1024d, binary quant)", fn ->
      Qdrant.delete_collection(@test_collection)
      :ok = Qdrant.ensure_collection(@test_collection, 1024)
      {:pass, "created #{@test_collection}"}
    end)

    check("collection has correct config", fn ->
      {:ok, info} = Qdrant.collection_info(@test_collection)
      vectors = get_in(info, ["config", "params", "vectors"])

      if vectors["size"] == 1024,
        do: {:pass, "size=#{vectors["size"]}, distance=#{vectors["distance"]}"},
        else: {:fail, "expected size 1024, got #{inspect(vectors["size"])}"}
    end)

    check("upsert point with real embedding", fn ->
      {:ok, [vector]} = Engram.Embedders.Voyage.embed_texts(["parity test point"])

      point = %{
        id: Ecto.UUID.generate(),
        vector: vector,
        payload: %{
          user_id: "parity_test_user",
          source_path: "Parity/Test.md",
          title: "Parity Test",
          folder: "Parity",
          tags: ["parity"],
          heading_path: "Parity Test",
          text: "This is a parity test point for validating the pipeline.",
          chunk_index: 0
        }
      }

      :ok = Qdrant.upsert_points(@test_collection, [point])
      Process.sleep(1000)
      {:pass, "upserted 1 point"}
    end)

    check("search with rescore", fn ->
      {:ok, [query_vec]} =
        Engram.Embedders.Voyage.embed_texts(["parity test"], model: "voyage-4-lite")

      {:ok, results} =
        Qdrant.search(@test_collection, query_vec,
          user_id: "parity_test_user",
          limit: 5
        )

      if length(results) >= 1 do
        top = hd(results)
        {:pass, "found #{length(results)} result(s), top score=#{Float.round(top.score, 4)}"}
      else
        {:fail, "expected >= 1 result, got 0"}
      end
    end)

    check("delete test collection", fn ->
      :ok = Qdrant.delete_collection(@test_collection)
      {:pass, "deleted #{@test_collection}"}
    end)
  end

  defp validate_s3 do
    alias Engram.Storage.S3

    test_key = "#{@test_s3_prefix}/parity-test.txt"
    test_data = "parity validation #{DateTime.utc_now()}"

    check("S3 put object", fn ->
      :ok = S3.put(test_key, test_data, content_type: "text/plain")
      {:pass, "uploaded #{byte_size(test_data)} bytes"}
    end)

    check("S3 get object (round-trip)", fn ->
      {:ok, retrieved} = S3.get(test_key)

      if retrieved == test_data,
        do: {:pass, "content matches"},
        else: {:fail, "content mismatch"}
    end)

    check("S3 exists?", fn ->
      if S3.exists?(test_key),
        do: {:pass, "exists? returned true"},
        else: {:fail, "exists? returned false for existing object"}
    end)

    check("S3 delete + verify gone", fn ->
      :ok = S3.delete(test_key)

      if S3.exists?(test_key),
        do: {:fail, "object still exists after delete"},
        else: {:pass, "deleted and confirmed gone"}
    end)
  end

  defp validate_pipeline do
    check("full pipeline (note → index → search)", fn ->
      alias Engram.{Accounts, Notes, Indexing, Search}

      {:ok, user} =
        Accounts.register_user(%{
          email: "parity-#{System.system_time(:second)}@test.local",
          password: "paritytest123456",
          display_name: "Parity Test"
        })

      {:ok, note} =
        Notes.upsert_note(user, %{
          "path" => "Parity/Validation.md",
          "content" =>
            "---\ntags: [parity]\n---\n# Parity Validation\n\nThis note validates the full embedding pipeline works end-to-end with Voyage AI and Qdrant binary quantization.",
          "mtime" => :os.system_time(:second) / 1
        })

      {:ok, chunk_count} = Indexing.index_note(note)

      if chunk_count == 0 do
        {:fail, "indexing produced 0 chunks"}
      else
        Process.sleep(1500)

        {:ok, results} = Search.search(user, "parity validation embedding pipeline")

        if length(results) >= 1 do
          top = hd(results)

          {:pass,
           "#{chunk_count} chunks indexed, search returned #{length(results)} result(s), " <>
             "top score=#{Float.round(top.score, 4)}"}
        else
          {:fail, "search returned 0 results after indexing #{chunk_count} chunks"}
        end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp run_section(name, fun) do
    IO.puts("─── #{name} ───")
    prev = Process.get(:parity_counts, {0, 0})
    Process.put(:parity_counts, {0, 0})

    fun.()

    {section_pass, section_fail} = Process.get(:parity_counts, {0, 0})
    {prev_pass, prev_fail} = prev
    Process.put(:parity_counts, {prev_pass + section_pass, prev_fail + section_fail})
    IO.puts("")
    {section_pass, section_fail}
  end

  defp check(name, fun) do
    {pass_count, fail_count} = Process.get(:parity_counts, {0, 0})

    try do
      case fun.() do
        {:pass, detail} ->
          IO.puts("  \e[32m✓\e[0m #{name} — #{detail}")
          Process.put(:parity_counts, {pass_count + 1, fail_count})

        {:fail, detail} ->
          IO.puts("  \e[31m✗\e[0m #{name} — #{detail}")
          Process.put(:parity_counts, {pass_count, fail_count + 1})
      end
    rescue
      e ->
        IO.puts("  \e[31m✗\e[0m #{name} — EXCEPTION: #{Exception.message(e)}")
        Process.put(:parity_counts, {pass_count, fail_count + 1})
    end
  end

  defp cosine_similarity(a, b) do
    dot = Enum.zip(a, b) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    mag_a = :math.sqrt(Enum.map(a, &(&1 * &1)) |> Enum.sum())
    mag_b = :math.sqrt(Enum.map(b, &(&1 * &1)) |> Enum.sum())
    dot / (mag_a * mag_b)
  end
end
