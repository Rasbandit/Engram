defmodule Engram.ObanTest do
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Workers.TestWorker

  test "Oban processes a test job" do
    # In test mode with testing: :inline, the job executes immediately
    assert :ok = perform_job(TestWorker, %{"message" => "hello"})
  end

  test "test worker job can be enqueued" do
    assert {:ok, %Oban.Job{}} =
             Oban.insert(TestWorker.new(%{message: "enqueue test"}))
  end
end
