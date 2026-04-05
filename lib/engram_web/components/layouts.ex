defmodule EngramWeb.Layouts do
  @moduledoc """
  Layout templates for server-rendered pages (marketing site).
  The React SPA has its own layout — this is only for EEx-rendered pages.
  """

  use EngramWeb, :html

  embed_templates "layouts/*"
end
