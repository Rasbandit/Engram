defmodule Engram.Billing.LimitKeysTest do
  use ExUnit.Case, async: true

  alias Engram.Billing.LimitKeys

  describe "all/0" do
    test "returns the 19 catalog keys" do
      keys = LimitKeys.all()
      assert length(keys) == 19
      assert :notes_cap in keys
      assert :vaults_cap in keys
      assert :reranker_enabled in keys
      assert :cross_vault_search in keys
      assert :vault_scoped_keys in keys
    end
  end

  describe "defined?/1" do
    test "true for every catalog key" do
      for key <- LimitKeys.all() do
        assert LimitKeys.defined?(key), "expected #{inspect(key)} to be defined"
      end
    end

    test "false for unknown atom" do
      refute LimitKeys.defined?(:bogus)
    end

    test "false for non-atom (string)" do
      refute LimitKeys.defined?("notes_cap")
    end
  end
end
