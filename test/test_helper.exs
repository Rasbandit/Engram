ExUnit.start(assert_receive_timeout: 2_000)
Ecto.Adapters.SQL.Sandbox.mode(Engram.Repo, :manual)

# Ensure SPA index.html has </head> for config injection.
# CI has no frontend build → write a minimal stub.
# Real build (detected by `id="root"`) missing </head> = error, not overwrite:
# the minifier shouldn't strip </head>, so this would be a genuine build bug.
spa_dir = Application.app_dir(:engram, "priv/static/app")
File.mkdir_p!(spa_dir)
index_path = Path.join(spa_dir, "index.html")

case File.read(index_path) do
  {:ok, html} ->
    cond do
      String.contains?(html, "</head>") ->
        :ok

      String.contains?(html, ~s(id="root")) ->
        raise """
        Real SPA build at #{index_path} is missing </head>.
        Refusing to overwrite. Rebuild the frontend or delete the file.
        """

      true ->
        File.write!(
          index_path,
          ~s(<!DOCTYPE html><html><head></head><body><div id="root"></div></body></html>)
        )
    end

  {:error, _} ->
    File.write!(
      index_path,
      ~s(<!DOCTYPE html><html><head></head><body><div id="root"></div></body></html>)
    )
end
