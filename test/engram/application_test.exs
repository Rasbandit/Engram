defmodule Engram.ApplicationTest do
  use ExUnit.Case, async: true

  describe "wiring source-lint (T3-audit C2)" do
    @app_path "lib/engram/application.ex"

    test "does NOT wrap BootCanary.verify!/0 in a supervised Task" do
      # Source-lint regression guard. The bug pattern was a Task.start_link
      # child for BootCanary.verify!/0 with restart: :temporary — start_link
      # returns synchronously, the verify!/0 raise lands later in the spawned
      # process, and `:temporary` makes the supervisor ignore the EXIT.
      # Result: app booted with wrong master key.
      src = File.read!(@app_path)

      refute src =~ "boot_canary_task",
             "Engram.Application.boot_canary_task/0 was the bug. BootCanary.verify!/0 " <>
               "must run synchronously inside a child whose init/1 raise propagates " <>
               "to start_link as {:error, _}, not under a Task.start_link child."

      # Match the supervisor child-spec form `start: {Task, :start_link, ...}`
      # so docstring prose explaining the bug doesn't trip the lint.
      refute src =~ ~r/start:\s*\{Task,\s*:start_link/,
             "No supervisor child may use Task.start_link to run BootCanary.verify!/0 — " <>
               "start_link returns before the function raises, and :temporary causes the " <>
               "supervisor to silently swallow the eventual EXIT."
    end

    test "wires BootCanaryGuard as a supervised child" do
      src = File.read!(@app_path)

      assert src =~ "boot_canary_guard",
             "Engram.Application must wire Engram.Crypto.BootCanaryGuard so that " <>
               "BootCanary.verify!/0 runs in a child's init/1, where a raise becomes " <>
               "a start_link error that propagates to Application.start/2 → VM exit."

      assert src =~ ~r/start:\s*\{Engram\.Crypto\.BootCanaryGuard,\s*:start_link/,
             "BootCanaryGuard must be wired as a supervisor child via {Module, :start_link, _}."
    end
  end
end
