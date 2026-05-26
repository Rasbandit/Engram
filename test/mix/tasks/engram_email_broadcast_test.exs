defmodule Mix.Tasks.Engram.Email.BroadcastTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Engram.Email.Broadcast, as: Task

  describe "parse_csv/1" do
    test "parses email,name rows and skips the header" do
      csv = """
      email,name
      ada@example.com,Ada Lovelace
      grace@example.com,Grace Hopper
      """

      assert Task.parse_csv(csv) == [
               %{email: "ada@example.com", name: "Ada Lovelace"},
               %{email: "grace@example.com", name: "Grace Hopper"}
             ]
    end

    test "trims whitespace and ignores blank lines" do
      csv = "email,name\n  bob@example.com ,  Bob \n\n"

      assert Task.parse_csv(csv) == [%{email: "bob@example.com", name: "Bob"}]
    end
  end
end
