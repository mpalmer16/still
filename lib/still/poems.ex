defmodule Still.Poems do
  @moduledoc "Compatibility name for Still's ordinary-file writing context."
  alias Still.Writing.Files
  defdelegate new(location), to: Files
  defdelegate display_title(piece), to: Files
  defdelegate explicit_title(piece), to: Files
  defdelegate list(location), to: Files
  defdelegate list_read_only(location), to: Files
  defdelegate get(location, id), to: Files
  defdelegate revisions(location, id), to: Files
  defdelegate save(location, existing, attrs), to: Files
  defdelegate rename(location, existing, filename), to: Files
  defdelegate set_title_role(location, existing, line), to: Files
  defdelegate list_trash(location), to: Files
  defdelegate trash(location, existing), to: Files
  defdelegate restore(location, id), to: Files
  defdelegate purge(location, id, token, confirmed?), to: Files
  defdelegate permanently_delete(location, piece, confirmed?), to: Files
  defdelegate from_historical(location, entry), to: Files
  defdelegate saved_from_historical(location, entry), to: Files
  defdelegate reconciliation(location), to: Files
  defdelegate relink(location, id, relative), to: Files
  defdelegate adopt(location, relative), to: Files
  defdelegate pending_recovery(location), to: Files
  defdelegate resolve_pending(location, id, choice), to: Files
end
