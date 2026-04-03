defmodule Engram.Embedders.VoyageTest do
  use ExUnit.Case, async: true

  alias Engram.Embedders.Voyage

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :voyage_url, "http://localhost:#{bypass.port}")
    System.put_env("VOYAGE_API_KEY", "test-key")

    on_exit(fn ->
      Application.delete_env(:engram, :voyage_url)
      System.delete_env("VOYAGE_API_KEY")
    end)

    %{bypass: bypass}
  end

  describe "embed_texts/1" do
    test "returns vectors on success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        body = %{
          "data" => [
            %{"embedding" => [0.1, 0.2, 0.3]},
            %{"embedding" => [0.4, 0.5, 0.6]}
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      assert {:ok, vectors} = Voyage.embed_texts(["hello", "world"])
      assert length(vectors) == 2
      assert hd(vectors) == [0.1, 0.2, 0.3]
    end

    test "returns error on non-200 response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        Plug.Conn.send_resp(conn, 429, ~s({"error": "rate limited"}))
      end)

      assert {:error, _} = Voyage.embed_texts(["hello"])
    end

    test "returns error on network failure", %{bypass: bypass} do
      Bypass.down(bypass)
      assert {:error, _} = Voyage.embed_texts(["hello"])
    end

    test "sends correct model in request body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == Application.get_env(:engram, :embed_model, "voyage-4-large")
        assert decoded["input"] == ["hello"]

        resp = %{"data" => [%{"embedding" => [0.1]}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      Voyage.embed_texts(["hello"])
    end
  end
end
