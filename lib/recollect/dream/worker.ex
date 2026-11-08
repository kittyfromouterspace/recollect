defmodule Recollect.Dream.Worker do
  @moduledoc """
  Behaviour for running dreams from a job system (MEM-023). Recollect ships
  the behaviour and the engine — the queue is the host's.

  ## Oban example (docs only; no dependency on Oban)

      defmodule MyApp.DreamWorker do
        use Oban.Worker, queue: :dreams, max_attempts: 1, unique: [period: 300]

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"scope_id" => scope_id} = args}) do
          Recollect.Dream.run(scope_id,
            owner_id: args["owner_id"],
            force: args["force"] == true,
            idempotency_key: args["idempotency_key"]
          )
          |> case do
            {:ok, _} -> :ok
            {:error, :locked} -> {:cancel, :dream_locked}
            {:error, reason} -> {:error, reason}
          end
        end
      end

  Any module implementing `perform/1` satisfies this behaviour.
  """

  @callback perform(args :: map()) :: :ok | {:ok, term()} | {:error, term()} | {:cancel, term()}
end
