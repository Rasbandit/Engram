defmodule Engram.LegalTest do
  use Engram.DataCase, async: true
  import Engram.LegalFixtures
  alias Engram.Legal

  describe "required_floor/1" do
    test "is the latest material version effective now" do
      insert_version(version: "2026-05-19", material: true, effective_date: nil)
      insert_version(version: "2026-06-01", material: true, effective_date: ~D[2099-01-01])
      # 2026-06-01 is material but not yet effective → floor stays 2026-05-19
      assert Legal.required_floor("terms_of_service") == "2026-05-19"
    end

    test "a minor (non-material) version never raises the floor" do
      insert_version(version: "2026-05-19", material: true, effective_date: nil)
      insert_version(version: "2026-06-01", material: false, effective_date: nil)
      assert Legal.required_floor("terms_of_service") == "2026-05-19"
    end

    test "a material version becomes the floor once effective_date passes" do
      insert_version(version: "2026-05-19", material: true, effective_date: nil)
      insert_version(version: "2026-06-01", material: true, effective_date: ~D[2000-01-01])
      assert Legal.required_floor("terms_of_service") == "2026-06-01"
    end
  end

  describe "current_version/1 and hash_for/2" do
    test "current_version is the latest published regardless of effective_date" do
      insert_version(version: "2026-05-19", effective_date: nil)
      insert_version(version: "2026-06-01", material: true, effective_date: ~D[2099-01-01])
      assert Legal.current_version("terms_of_service") == "2026-06-01"
    end

    test "hash_for returns the content_hash for a version, nil if unknown" do
      insert_version(version: "2026-05-19", content_hash: "deadbeef")
      assert Legal.hash_for("terms_of_service", "2026-05-19") == "deadbeef"
      assert Legal.hash_for("terms_of_service", "1999-01-01") == nil
    end
  end
end
