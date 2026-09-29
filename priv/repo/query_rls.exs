alias BeamChat.Repo

# Find all tables with RLS enabled using pg_tables
case Repo.query("SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND rowsecurity = true") do
  {:ok, result} ->
    IO.puts("Tables with RLS enabled:")
    for [name] <- result.rows do
      IO.puts("  #{name}")
    end
  {:error, e} -> IO.puts("Error: #{inspect(e)}")
end
