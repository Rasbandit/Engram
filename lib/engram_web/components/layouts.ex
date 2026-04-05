defmodule EngramWeb.Layouts do
  @moduledoc """
  Layout templates for server-rendered pages (marketing site).
  The React SPA has its own layout — this is only for EEx-rendered pages.
  """

  use EngramWeb, :html

  @css_path Path.expand("../../../../priv/static/css/marketing.css", __DIR__)
  @external_resource @css_path

  def inline_css do
    case File.read(@css_path) do
      {:ok, css} -> css
      {:error, _} -> ""
    end
  end

  embed_templates "layouts/*"
end
