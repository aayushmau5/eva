defmodule Eva.Agent.Session.Entries do
  @moduledoc """
  Session entry structs.


  TODO: Explore.
  ```
  If you just need the common fields (id, parent_id, timestamp, type) without caring about the subtype, a protocol is the cleanest:
  defprotocol Entry do
    @spec id(t) :: String.t()
    def id(entry)

    @spec parent_id(t) :: String.t() | nil
    def parent_id(entry)

    @spec timestamp(t) :: float()
    def timestamp(entry)

    @spec type(t) :: String.t()
    def type(entry)
  end

  # Then implement for each struct — they all have the same fields,
  # but you could use `@derive` + a shared module helper.
  ```
  """

  alias Eva.Agent.Messages
  alias Eva.Agent.Utils

  @type t() ::
          Message.t()
          | ModelChange.t()
          | ThinkingLevelChange.t()
          | Compaction.t()
          | BranchSummary.t()
          | Label.t()
          | Leaf.t()
          | SessionInfo.t()
          | Custom.t()

  defmodule Message do
    use TypedStruct
    alias Eva.Agent.Messages
    alias Eva.Agent.Utils

    typedstruct do
      field :id, String.t(), enforce: true
      field :parent_id, String.t()
      field :timestamp, float(), enforce: true
      field :type, String.t(), default: "message"
      field :message, Messages.t()
    end

    @spec new(map()) :: __MODULE__.t()
    def new(attrs) do
      %__MODULE__{
        id: Utils.new_entry_id(),
        parent_id: Map.get(attrs, :parent_id),
        timestamp: Utils.timestamp(),
        message: Map.fetch!(attrs, :message)
      }
    end
  end

  defmodule ModelChange do
    use TypedStruct
    alias Eva.Agent.Messages
    alias Eva.Agent.Utils

    typedstruct do
      field :id, String.t(), enforce: true
      field :parent_id, String.t()
      field :timestamp, float(), enforce: true
      field :type, String.t(), default: "model_change"
      field :model, String.t()
    end

    @spec new(map()) :: __MODULE__.t()
    def new(attrs) do
      %__MODULE__{
        id: Utils.new_entry_id(),
        parent_id: Map.get(attrs, :parent_id),
        timestamp: Utils.timestamp(),
        model: Map.fetch!(attrs, :model)
      }
    end
  end

  defmodule ThinkingLevelChange do
    use TypedStruct
    alias Eva.Agent.Messages
    alias Eva.Agent.Utils

    typedstruct do
      field :id, String.t(), enforce: true
      field :parent_id, String.t() | nil
      field :timestamp, float()
      field :type, String.t(), default: "thinking_level_change"
      field :thinking_level, String.t() | nil
    end

    @spec new(map()) :: __MODULE__.t()
    def new(attrs) do
      %__MODULE__{
        id: Utils.new_entry_id(),
        parent_id: Map.get(attrs, :parent_id),
        timestamp: Utils.timestamp(),
        thinking_level: Map.get(attrs, :thinking_level)
      }
    end
  end

  defmodule Compaction do
    use TypedStruct
    alias Eva.Agent.Messages
    alias Eva.Agent.Utils

    typedstruct do
      field :id, String.t(), enforce: true
      field :parent_id, String.t() | nil
      field :timestamp, float()
      field :type, String.t(), default: "compaction"
      field :summary, String.t()
      field :replaces_entry_ids, [String.t()]
    end

    @spec new(map()) :: __MODULE__.t()
    def new(attrs) do
      %__MODULE__{
        id: Utils.new_entry_id(),
        parent_id: Map.get(attrs, :parent_id),
        timestamp: Utils.timestamp(),
        summary: Map.fetch!(attrs, :summary),
        replaces_entry_ids: Map.get(attrs, :replaces_entry_ids, [])
      }
    end
  end

  defmodule BranchSummary do
    use TypedStruct
    alias Eva.Agent.Messages
    alias Eva.Agent.Utils

    typedstruct do
      field :id, String.t(), enforce: true
      field :parent_id, String.t() | nil
      field :timestamp, float()
      field :type, String.t(), default: "branch_summary"
      field :summary, String.t()
      field :branch_root_id, String.t() | nil
    end

    @spec new(map()) :: __MODULE__.t()
    def new(attrs) do
      %__MODULE__{
        id: Utils.new_entry_id(),
        parent_id: Map.get(attrs, :parent_id),
        timestamp: Utils.timestamp(),
        summary: Map.fetch!(attrs, :summary),
        branch_root_id: Map.get(attrs, :branch_root_id)
      }
    end
  end

  defmodule Label do
    use TypedStruct
    alias Eva.Agent.Messages
    alias Eva.Agent.Utils

    typedstruct do
      field :id, String.t(), enforce: true
      field :parent_id, String.t() | nil
      field :timestamp, float()
      field :type, String.t(), default: "label"
      field :label, String.t()
    end

    @spec new(map()) :: __MODULE__.t()
    def new(attrs) do
      %__MODULE__{
        id: Utils.new_entry_id(),
        parent_id: Map.get(attrs, :parent_id),
        timestamp: Utils.timestamp(),
        label: Map.fetch!(attrs, :label)
      }
    end
  end

  defmodule Leaf do
    use TypedStruct
    alias Eva.Agent.Messages
    alias Eva.Agent.Utils

    typedstruct do
      field :id, String.t(), enforce: true
      field :parent_id, String.t()
      field :timestamp, float()
      field :type, String.t(), default: "leaf"
      field :entry_id, String.t()
    end

    @spec new(map()) :: __MODULE__.t()
    def new(attrs) do
      %__MODULE__{
        id: Utils.new_entry_id(),
        parent_id: Map.get(attrs, :parent_id),
        timestamp: Utils.timestamp(),
        entry_id: Map.get(attrs, :entry_id)
      }
    end
  end

  defmodule SessionInfo do
    use TypedStruct
    alias Eva.Agent.Messages
    alias Eva.Agent.Utils

    typedstruct do
      field :id, String.t(), enforce: true
      field :parent_id, String.t()
      field :timestamp, float()
      field :type, String.t(), default: "session_info"
      field :cwd, String.t()
      field :title, String.t()
    end

    @spec new(map()) :: __MODULE__.t()
    def new(attrs) do
      %__MODULE__{
        id: Utils.new_entry_id(),
        parent_id: Map.get(attrs, :parent_id),
        timestamp: Utils.timestamp(),
        cwd: Map.get(attrs, :cwd),
        title: Map.get(attrs, :title)
      }
    end
  end

  defmodule Custom do
    use TypedStruct
    alias Eva.Agent.Messages
    alias Eva.Agent.Utils

    typedstruct do
      field :id, String.t(), enforce: true
      field :parent_id, String.t() | nil
      field :timestamp, float()
      field :type, String.t(), default: "custom"
      field :namespace, String.t()
      field :data, map()
    end

    @spec new(map()) :: __MODULE__.t()
    def new(attrs) do
      %__MODULE__{
        id: Utils.new_entry_id(),
        parent_id: Map.get(attrs, :parent_id),
        timestamp: Utils.timestamp(),
        namespace: Map.fetch!(attrs, :namespace),
        data: Map.get(attrs, :data, %{})
      }
    end
  end

  defimpl JSON.Encoder,
    for: [
      Message,
      ModelChange,
      ThinkingLevelChange,
      Compaction,
      BranchSummary,
      Label,
      Leaf,
      SessionInfo,
      Custom
    ] do
    def encode(struct, opts) do
      struct |> Map.from_struct() |> JSON.Encoder.encode(opts)
    end
  end

  @doc """
  Builds a typed entry struct from a JSON-decoded map (string keys).
  """
  def from_json_map(%{"type" => type} = json_map) do
    case type do
      "message" ->
        message = Messages.from_json_map(json_map["message"])
        fields = json_map |> Utils.to_atom_keys() |> Map.put(:message, message)
        struct!(Message, fields)

      "custom" ->
        fields = json_map |> Utils.to_atom_keys() |> Map.update(:data, %{}, & &1)
        struct!(Custom, fields)

      "compaction" ->
        fields = json_map |> Utils.to_atom_keys() |> Map.update(:replaces_entry_ids, [], & &1)
        struct!(Compaction, fields)

      _ ->
        struct!(module_for(type), Utils.to_atom_keys(json_map))
    end
  end

  def from_json_map(_), do: raise(ArgumentError, "missing 'type' field")

  defp module_for("model_change"), do: ModelChange
  defp module_for("thinking_level_change"), do: ThinkingLevelChange
  defp module_for("branch_summary"), do: BranchSummary
  defp module_for("label"), do: Label
  defp module_for("leaf"), do: Leaf
  defp module_for("session_info"), do: SessionInfo
  defp module_for(type), do: raise(ArgumentError, "unknown entry type: #{inspect(type)}")
end
