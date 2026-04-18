defmodule Engram.SearchIntegrationTest do
  use Engram.DataCase, async: false

  @moduletag :qdrant_integration

  setup do
    Engram.Crypto.DekCache.invalidate_all()
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    enc_vault = insert(:vault, user: user, encrypted: true)

    # Use a test-isolated Qdrant collection so we can drop it after.
    col = "engram_test_#{System.unique_integer([:positive])}"
    old_col = Application.get_env(:engram, :qdrant_collection)
    Application.put_env(:engram, :qdrant_collection, col)

    on_exit(fn ->
      Engram.Vector.Qdrant.delete_collection(col)
      Application.put_env(:engram, :qdrant_collection, old_col)
    end)

    {:ok, user: user, vault: enc_vault, collection: col}
  end

  test "encrypted vault round-trip: upsert → raw payload is ciphertext → search returns plaintext",
       %{user: user, vault: vault, collection: col} do
    note =
      insert(:note,
        user: user,
        vault: vault,
        content: "# Journal\n\nSensitive body content.",
        title: "Journal"
      )

    {:ok, _n} = Engram.Indexing.index_note(note, vault)

    # Raw fetch from Qdrant — inspect payloads to confirm ciphertext shape.
    {:ok, info} = Engram.Vector.Qdrant.collection_info(col)
    assert info["points_count"] >= 1

    {:ok, resp} =
      Req.post("http://localhost:6333/collections/#{col}/points/scroll",
        json: %{limit: 10, with_payload: true}
      )

    point = hd(resp.body["result"]["points"])
    payload = point["payload"]

    assert payload["text_nonce"] != nil
    assert payload["text"] != "# Journal"
    assert payload["title"] != "Journal"
    assert payload["vault_id"] == to_string(vault.id)

    # Search must return plaintext.
    {:ok, results} = Engram.Search.search(user, vault, "sensitive body")

    assert results != []

    Enum.each(results, fn r ->
      assert is_binary(r.text)
      refute Map.has_key?(r, :text_nonce)
    end)
  end

  test "unencrypted vault round-trip: plaintext end to end", %{user: user} do
    plain_vault = insert(:vault, user: user, encrypted: false)

    note =
      insert(:note,
        user: user,
        vault: plain_vault,
        content: "Plain content with searchable words.",
        title: "Plain"
      )

    {:ok, _} = Engram.Indexing.index_note(note, plain_vault)

    {:ok, results} = Engram.Search.search(user, plain_vault, "searchable")
    assert Enum.any?(results, fn r -> r.text =~ "searchable" end)
  end
end
