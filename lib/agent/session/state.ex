defmodule Eva.Agent.Session.State do
  @moduledoc """
  This is a replay engine. It takes raw append-only session entries from storage(jsonl)
  and reconstructs a clean in-memory snapshot of the session: messages, current model, thinking level, active leaf.
  """

  use TypedStruct
  alias Eva.Agent.Messages
  alias Eva.Agent.Session.{Entries, Tree}

  typedstruct do
    field :messages, [Messages.t()]
    field :model, String.t()
    field :thinking_level, String.t()
    field :label, String.t()
    field :active_leaf_id, String.t()
    field :session_info, Entries.SessionInfo.t()
    field :custom_entries, [Entries.Custom.t()]
    field :compaction_entries, [Entries.Compaction.t()]
    field :context_entry_ids, [String.t()]
    field :entries, [Entries.t()]
  end

  def from_entries(entries, leaf_id \\ nil) do
    replay_entries = if leaf_id, do: Tree.path_to_entry(entries, leaf_id), else: entries

    replay_entries =
      case get_latest_branch_summary_index(replay_entries) do
        nil -> replay_entries
        index -> Enum.drop(replay_entries, index)
      end

    state = %{
      message_rows: [],
      model: nil,
      thinking_level: nil,
      label: nil,
      active_leaf_id: nil,
      session_info: nil,
      custom_entries: [],
      compaction_entries: []
    }

    state =
      Enum.reduce(replay_entries, state, fn entry, state ->
        case entry.type do
          "message" ->
            %{state | message_rows: [{entry.id, entry.message} | state.message_rows]}

          "model_change" ->
            %{state | model: entry.model}

          "thinking_level_change" ->
            %{state | thinking_level: entry.thinking_level}

          "label" ->
            %{state | label: entry.label}

          "leaf" ->
            %{state | active_leaf_id: entry.entry_id}

          "session_info" ->
            %{state | session_info: entry}

          "custom" ->
            %{state | custom_entries: [entry | state.custom_entries]}

          "compaction" ->
            %{
              state
              | message_rows: apply_compaction(state.message_rows, entry),
                compaction_entries: [entry | state.compaction_entries]
            }

          "branch_summary" ->
            msg = %Messages.UserMessage{content: format_branch_summary(entry)}
            %{state | message_rows: [{entry.id, msg} | state.message_rows]}
        end
      end)

    message_rows = Enum.reverse(state.message_rows)

    %__MODULE__{
      messages: Enum.map(message_rows, fn {_id, msg} -> msg end),
      model: state.model,
      thinking_level: state.thinking_level,
      label: state.label,
      active_leaf_id: state.active_leaf_id,
      session_info: state.session_info,
      custom_entries: Enum.reverse(state.custom_entries),
      compaction_entries: Enum.reverse(state.compaction_entries),
      context_entry_ids: Enum.map(message_rows, fn {id, _msg} -> id end),
      entries: replay_entries
    }
  end

  # Replaces the first matching entry in message_rows whose id is in
  # compaction.replaces_entry_ids with a summary UserMessage. All subsequent
  # replaced entries are dropped. If no replaced entry is found, the summary
  # is appended at the end.
  defp apply_compaction(message_rows, compaction) do
    replaced_ids = MapSet.new(compaction.replaces_entry_ids)
    summary_msg = %Messages.UserMessage{content: format_compaction_summary(compaction.summary)}

    {retained, inserted?} =
      Enum.reduce(message_rows, {[], false}, fn {entry_id, _msg} = row, {acc, inserted} ->
        if MapSet.member?(replaced_ids, entry_id) do
          if inserted do
            {acc, inserted}
          else
            {[{compaction.id, summary_msg} | acc], true}
          end
        else
          {[row | acc], inserted}
        end
      end)

    retained =
      if inserted? do
        retained
      else
        [{compaction.id, summary_msg} | retained]
      end

    Enum.reverse(retained)
  end

  defp format_compaction_summary(summary) do
    ~s"""
    Previous conversation summary:
    #{summary}
    """
  end

  defp format_branch_summary(branch_summary) do
    ~s"""
    The following is a summary of a branch that this conversation came back from:
    <summary>#{branch_summary.summary}</summary>
    """
  end

  defp get_latest_branch_summary_index(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.reduce_while(nil, fn {entry, i}, _acc ->
      if entry.type == "branch_summary" do
        {:halt, i}
      else
        {:cont, nil}
      end
    end)
  end
end
