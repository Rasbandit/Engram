defmodule Engram.Legal.VersionCacheTest do
  use Engram.DataCase, async: false
  import Engram.LegalFixtures
  alias Engram.Legal.VersionCache

  setup do
    on_exit(&VersionCache.invalidate_all/0)
    VersionCache.invalidate_all()
    :ok
  end

  test "memoizes required_floor and reflects invalidation" do
    insert_version(version: "2026-05-19", material: true, effective_date: nil)
    assert VersionCache.required_floor("terms_of_service") == "2026-05-19"

    insert_version(version: "2026-06-01", material: true, effective_date: ~D[2000-01-01])
    # still cached at the old value until invalidated
    assert VersionCache.required_floor("terms_of_service") == "2026-05-19"

    VersionCache.invalidate_all()
    assert VersionCache.required_floor("terms_of_service") == "2026-06-01"
  end

  test "caches current_version and hash_for" do
    insert_version(version: "2026-05-19", content_hash: "h")
    assert VersionCache.current_version("terms_of_service") == "2026-05-19"
    assert VersionCache.hash_for("terms_of_service", "2026-05-19") == "h"
  end
end
