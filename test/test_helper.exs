ExUnit.start(assert_receive_timeout: 2_000)
Ecto.Adapters.SQL.Sandbox.mode(Engram.Repo, :manual)

# Ensure SPA stub index.html has <head> for config injection (CI has no frontend build)
spa_dir = Application.app_dir(:engram, "priv/static/app")
File.mkdir_p!(spa_dir)
index_path = Path.join(spa_dir, "index.html")

needs_stub =
  case File.read(index_path) do
    {:ok, html} -> not String.contains?(html, "</head>")
    {:error, _} -> true
  end

if needs_stub do
  File.write!(index_path, ~s(<!DOCTYPE html><html><head></head><body><div id="root"></div></body></html>))
end
